#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dockerfile="${POSTHOG_SOURCE_DOCKERFILE:-${repo_root}/upstream/Dockerfile}"
output_dockerfile="${1:-}"
apt_mount_cache="${DOCKER_APT_MOUNT_CACHE:-false}"

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

awk -v apt_mount_cache="$apt_mount_cache" '
  BEGIN {
    frontend_hooks = 0
    plugin_hooks = 0
    apt_hooks = 0
    apt_stage = "runtime"
    in_apt_run = 0
    in_node_scripts = 0
  }
  /^FROM / {
    apt_stage = "runtime"
    for (field = 1; field <= NF; field += 1) {
      if ($field == "AS") {
        apt_stage = $(field + 1)
      }
    }
  }
  /^FROM .* AS node-scripts-build$/ { in_node_scripts = 1 }
  apt_mount_cache == "true" && $0 == "RUN --mount=type=secret,id=posthog_upload_sourcemaps_cli_api_key \\" {
    print
    print "    --mount=type=cache,id=apt-cache-" apt_stage ",target=/var/cache/apt,sharing=locked \\"
    print "    --mount=type=cache,id=apt-lib-" apt_stage ",target=/var/lib/apt,sharing=locked \\"
    apt_hooks += 1
    in_apt_run = 1
    next
  }
  apt_mount_cache == "true" && $0 == "RUN apt-get update && \\" {
    print "RUN --mount=type=cache,id=apt-cache-" apt_stage ",target=/var/cache/apt,sharing=locked \\"
    print "    --mount=type=cache,id=apt-lib-" apt_stage ",target=/var/lib/apt,sharing=locked \\"
    print "    rm -f /etc/apt/apt.conf.d/docker-clean && \\"
    print "    apt-get update && \\"
    apt_hooks += 1
    in_apt_run = 1
    next
  }
  apt_mount_cache == "true" && in_apt_run && $0 == "        apt-get update && \\" {
    print "        rm -f /etc/apt/apt.conf.d/docker-clean && \\"
    print
    next
  }
  apt_mount_cache == "true" && in_apt_run {
    line = $0
    gsub(/rm -rf \/var\/lib\/apt\/lists\/\*/, "true", line)
    print line
    if (line !~ /\\[[:space:]]*$/) {
      in_apt_run = 0
    }
    next
  }
  apt_mount_cache == "true" && /rm -rf \/var\/lib\/apt\/lists\/\*/ {
    line = $0
    gsub(/rm -rf \/var\/lib\/apt\/lists\/\*/, "true", line)
    print line
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
    if (frontend_hooks != 1 || plugin_hooks != 1) {
      printf "unsupported PostHog Dockerfile: expected one frontend hook and one plugin hook; found %d and %d\n", frontend_hooks, plugin_hooks > "/dev/stderr"
      exit 1
    }
    if (apt_mount_cache == "true" && apt_hooks != 5) {
      printf "unsupported PostHog Dockerfile: expected five apt cache hooks; found %d\n", apt_hooks > "/dev/stderr"
      exit 1
    }
  }
' "$source_dockerfile" > "$rendered_dockerfile"

mv "$rendered_dockerfile" "$output_dockerfile"
