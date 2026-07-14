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
[[ "$(grep -Fc 'AS posthog-runtime' "$rendered")" -eq 1 ]]
[[ "$(grep -Fc 'AS boringcache-state-mount-probe' "$rendered")" -eq 1 ]]
grep -Fq 'bin/turbo --filter=@posthog/frontend build' "$rendered"
grep -Fq 'bin/turbo --filter=@posthog/plugin-transpiler build' "$rendered"

variant_source="$test_root/variant.Dockerfile"
sed '1s/$/ # exact-source-variant/' "$source_dockerfile" > "$variant_source"
POSTHOG_SOURCE_DOCKERFILE="$variant_source" "$renderer" "$test_root/variant-rendered.Dockerfile"
grep -Fq '# exact-source-variant' "$test_root/variant-rendered.Dockerfile"

unsupported_source="$test_root/unsupported.Dockerfile"
sed 's/bin\/turbo --filter=@posthog\/frontend build/bin\/turbo --filter=@posthog\/frontend build:changed/' \
  "$source_dockerfile" > "$unsupported_source"
if POSTHOG_SOURCE_DOCKERFILE="$unsupported_source" \
  "$renderer" "$test_root/unsupported-rendered.Dockerfile" >/dev/null 2>&1; then
  echo "Expected an unsupported upstream Dockerfile to fail closed" >&2
  exit 1
fi

echo "PostHog tool-cache Dockerfile rendering is valid."
