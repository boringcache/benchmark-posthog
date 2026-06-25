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
  in_node_scripts && $0 == "RUN --mount=type=cache,id=pnpm,target=/tmp/pnpm-store-v24 \\" {
    print
    print "    --mount=type=secret,id=boringcache-tool-cache-env \\"
    next
  }
  in_node_scripts && $0 == "    NODE_OPTIONS=\"--max-old-space-size=4096\" CI=1 pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24 && \\" {
    print
    print "    if [ -f /run/secrets/boringcache-tool-cache-env ]; then \\"
    print "        . /run/secrets/boringcache-tool-cache-env; \\"
    print "    fi && \\"
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

if ! diff -u "$expected_dockerfile" "$fixture_dockerfile"; then
  echo "scenarios/posthog-toolcache/Dockerfile is out of sync with upstream/Dockerfile plus the static tool-cache hook." >&2
  echo "Regenerate the fixture from the pinned upstream Dockerfile and keep only the boringcache-tool-cache-env hook delta." >&2
  exit 1
fi
