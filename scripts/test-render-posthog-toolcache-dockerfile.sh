#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="$repo_root/scripts/render-posthog-toolcache-dockerfile.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/posthog-toolcache-render.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

source_dockerfile="$test_root/source.Dockerfile"
cat > "$source_dockerfile" <<'EOF'
FROM node:24-bookworm AS frontend-build
RUN bin/turbo --filter=@posthog/frontend build

FROM node:24-bookworm AS node-scripts-build
RUN NODE_OPTIONS="--max-old-space-size=4096" CI=1 pnpm --filter=@posthog/plugin-transpiler... deploy --prod /tmp/prod && \
    NODE_OPTIONS="--max-old-space-size=4096" CI=1 pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24 && \
    NODE_OPTIONS="--max-old-space-size=4096" bin/turbo --filter=@posthog/plugin-transpiler build

FROM unit:1.34.2-python3.13
RUN true
EOF

rendered="$test_root/rendered.Dockerfile"
POSTHOG_SOURCE_DOCKERFILE="$source_dockerfile" "$renderer" "$rendered"

[[ "$(grep -Fc 'id=boringcache-tool-cache-env' "$rendered")" -eq 2 ]]
grep -Fq 'bin/turbo --filter=@posthog/frontend build' "$rendered"
grep -Fq 'bin/turbo --filter=@posthog/plugin-transpiler build' "$rendered"

variant_source="$test_root/variant.Dockerfile"
sed '1s/$/ # exact-source-variant/' "$source_dockerfile" > "$variant_source"
POSTHOG_SOURCE_DOCKERFILE="$variant_source" "$renderer" "$test_root/variant-rendered.Dockerfile"
grep -Fq '# exact-source-variant' "$test_root/variant-rendered.Dockerfile"

apt_rendered="$test_root/apt-rendered.Dockerfile"
DOCKER_APT_MOUNT_CACHE=true "$renderer" "$apt_rendered"
[[ "$(grep -Fc 'target=/var/cache/apt,sharing=locked' "$apt_rendered")" -eq 4 ]]
[[ "$(grep -Fc 'target=/var/lib/apt,sharing=locked' "$apt_rendered")" -eq 4 ]]
[[ "$(grep -Fc 'rm -f /etc/apt/apt.conf.d/docker-clean' "$apt_rendered")" -eq 4 ]]
if grep -Fq 'rm -rf /var/lib/apt/lists/*' "$apt_rendered"; then
  echo "Expected apt cache mounts to retain package indexes" >&2
  exit 1
fi

additional_apt_source="$test_root/additional-apt.Dockerfile"
cat "$repo_root/upstream/Dockerfile" > "$additional_apt_source"
cat >> "$additional_apt_source" <<'EOF'

FROM debian:bookworm-slim AS extra-build
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*
EOF
additional_apt_rendered="$test_root/additional-apt-rendered.Dockerfile"
POSTHOG_SOURCE_DOCKERFILE="$additional_apt_source" DOCKER_APT_MOUNT_CACHE=true \
  "$renderer" "$additional_apt_rendered"
[[ "$(grep -Fc 'target=/var/cache/apt,sharing=locked' "$additional_apt_rendered")" -eq 5 ]]
[[ "$(grep -Fc 'target=/var/lib/apt,sharing=locked' "$additional_apt_rendered")" -eq 5 ]]
[[ "$(grep -Fc 'rm -f /etc/apt/apt.conf.d/docker-clean' "$additional_apt_rendered")" -eq 5 ]]

unsupported_apt_source="$test_root/unsupported-apt.Dockerfile"
sed 's/^RUN apt-get update/RUN env DEBIAN_FRONTEND=noninteractive apt-get update/' \
  "$repo_root/upstream/Dockerfile" > "$unsupported_apt_source"
if POSTHOG_SOURCE_DOCKERFILE="$unsupported_apt_source" DOCKER_APT_MOUNT_CACHE=true \
  "$renderer" "$test_root/unsupported-apt-rendered.Dockerfile" >"$test_root/error.log" 2>&1; then
  echo "Expected an apt update without cache mounts to fail" >&2
  exit 1
fi
grep -Fq 'expected a cache hook for each apt update' "$test_root/error.log"
[[ ! -e "$test_root/unsupported-apt-rendered.Dockerfile" ]]

unsupported_source="$test_root/unsupported.Dockerfile"
sed 's/bin\/turbo --filter=@posthog\/frontend build/bin\/turbo --filter=@posthog\/frontend build:changed/' \
  "$source_dockerfile" > "$unsupported_source"
if POSTHOG_SOURCE_DOCKERFILE="$unsupported_source" \
  "$renderer" "$test_root/unsupported-rendered.Dockerfile" >/dev/null 2>&1; then
  echo "Expected an unsupported upstream Dockerfile to fail closed" >&2
  exit 1
fi

echo "PostHog tool-cache Dockerfile rendering is valid."
