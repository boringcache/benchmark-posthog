#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
upstream_dockerfile="${repo_root}/upstream/Dockerfile"
fixture_dockerfile="${repo_root}/scenarios/posthog-toolcache/Dockerfile"
expected_dockerfile="$(mktemp)"
trap 'rm -f "$expected_dockerfile"' EXIT

awk '
  BEGIN { replacements = 0; in_node_scripts = 0 }
  /^FROM .* AS node-scripts-build$/ { in_node_scripts = 1 }
  $0 == "RUN bin/turbo --filter=@posthog/frontend build" {
    print "RUN --mount=type=secret,id=boringcache-tool-cache-env \\"
    print "    if [ -f /run/secrets/boringcache-tool-cache-env ]; then \\"
    print "        . /run/secrets/boringcache-tool-cache-env; \\"
    print "    fi && \\"
    print "    bin/turbo --filter=@posthog/frontend build"
    replacements += 1
    next
  }
  in_node_scripts && $0 == "    NODE_OPTIONS=\"--max-old-space-size=4096\" CI=1 pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24 && \\" {
    print "    NODE_OPTIONS=\"--max-old-space-size=4096\" CI=1 pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24"
    print "RUN --mount=type=secret,id=boringcache-tool-cache-env \\"
    next
  }
  in_node_scripts && $0 == "    NODE_OPTIONS=\"--max-old-space-size=4096\" bin/turbo --filter=@posthog/plugin-transpiler build" {
    print "    if [ -f /run/secrets/boringcache-tool-cache-env ]; then \\"
    print "        . /run/secrets/boringcache-tool-cache-env; \\"
    print "    fi && \\"
    print
    replacements += 1
    next
  }
  { print }
  END {
    if (replacements != 2) {
      printf "expected 2 PostHog Turbo tool-cache Dockerfile hooks, applied %d\n", replacements > "/dev/stderr"
      exit 1
    }
  }
' "$upstream_dockerfile" > "$expected_dockerfile"

cat >> "$expected_dockerfile" <<'EOF'


# Canary-only target: force one bounded pnpm cache mount to execute after the
# product phases. The state harness invokes this target read-only and records
# its timing separately, so it proves lazy archive hydration without changing
# the measured BuildKit generation.
FROM node:24.13.0-bookworm-slim AS boringcache-state-mount-probe
ARG BORINGCACHE_STATE_MOUNT_PROBE
RUN --mount=type=cache,id=pnpm,target=/tmp/pnpm-store-v24 \
    test -n "$BORINGCACHE_STATE_MOUNT_PROBE" && \
    test -n "$(find /tmp/pnpm-store-v24 -mindepth 1 -print -quit)"
EOF

if ! diff -u "$expected_dockerfile" "$fixture_dockerfile"; then
  echo "scenarios/posthog-toolcache/Dockerfile is out of sync with upstream/Dockerfile plus its benchmark-only hooks." >&2
  echo "Regenerate the fixture from the pinned upstream Dockerfile and keep only the tool-cache environment and state mount-probe deltas." >&2
  exit 1
fi
