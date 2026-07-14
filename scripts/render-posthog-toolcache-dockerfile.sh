#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dockerfile="${POSTHOG_SOURCE_DOCKERFILE:-${repo_root}/upstream/Dockerfile}"
output_dockerfile="${1:-}"

if [[ -z "$output_dockerfile" ]]; then
  echo "Usage: $0 OUTPUT_DOCKERFILE" >&2
  exit 2
fi
if [[ ! -f "$source_dockerfile" ]]; then
  echo "PostHog source Dockerfile does not exist: ${source_dockerfile}" >&2
  exit 2
fi
output_dir="$(dirname "$output_dockerfile")"
mkdir -p "$output_dir"
source_dockerfile="$(cd "$(dirname "$source_dockerfile")" && pwd)/$(basename "$source_dockerfile")"
output_dockerfile="$(cd "$output_dir" && pwd)/$(basename "$output_dockerfile")"
if [[ "$output_dockerfile" == "$source_dockerfile" ]]; then
  echo "Generated Dockerfile must not replace the PostHog source Dockerfile" >&2
  exit 2
fi
rendered_dockerfile="$(mktemp "$(dirname "$output_dockerfile")/posthog-toolcache.Dockerfile.XXXXXX")"
trap 'rm -f "$rendered_dockerfile"' EXIT

awk '
  BEGIN {
    frontend_hooks = 0
    plugin_hooks = 0
    runtime_targets = 0
    in_node_scripts = 0
  }
  /^FROM .* AS node-scripts-build$/ { in_node_scripts = 1 }
  /^FROM[[:space:]]+unit:[^[:space:]]+$/ {
    print $0 " AS posthog-runtime"
    runtime_targets += 1
    next
  }
  $0 == "RUN bin/turbo --filter=@posthog/frontend build" {
    print "RUN --mount=type=secret,id=boringcache-tool-cache-env \\"
    print "    if [ -f /run/secrets/boringcache-tool-cache-env ]; then \\"
    print "        . /run/secrets/boringcache-tool-cache-env; \\"
    print "    fi && \\"
    print "    bin/turbo --filter=@posthog/frontend build"
    frontend_hooks += 1
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
    plugin_hooks += 1
    next
  }
  { print }
  END {
    if (frontend_hooks != 1 || plugin_hooks != 1 || runtime_targets != 1) {
      printf "unsupported PostHog Dockerfile: expected one frontend hook, one plugin hook, and one runtime target; found %d, %d, %d\n", frontend_hooks, plugin_hooks, runtime_targets > "/dev/stderr"
      exit 1
    }
  }
' "$source_dockerfile" > "$rendered_dockerfile"

cat >> "$rendered_dockerfile" <<'EOF'


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

mv "$rendered_dockerfile" "$output_dockerfile"
