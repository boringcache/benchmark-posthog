#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="$repo_root/scripts/render-posthog-toolcache-dockerfile.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/posthog-toolcache-render.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

rendered="$test_root/rendered.Dockerfile"
"$renderer" "$rendered"

[[ "$(grep -Fc 'id=boringcache-tool-cache-env' "$rendered")" -eq 2 ]]
[[ "$(grep -Fc 'AS posthog-runtime' "$rendered")" -eq 1 ]]
[[ "$(grep -Fc 'AS boringcache-state-mount-probe' "$rendered")" -eq 1 ]]
grep -Fq 'bin/turbo --filter=@posthog/frontend build' "$rendered"
grep -Fq 'bin/turbo --filter=@posthog/plugin-transpiler build' "$rendered"

variant_source="$test_root/variant.Dockerfile"
sed '1s/$/ # exact-source-variant/' "$repo_root/upstream/Dockerfile" > "$variant_source"
POSTHOG_SOURCE_DOCKERFILE="$variant_source" "$renderer" "$test_root/variant-rendered.Dockerfile"
grep -Fq '# exact-source-variant' "$test_root/variant-rendered.Dockerfile"

unsupported_source="$test_root/unsupported.Dockerfile"
sed 's/bin\/turbo --filter=@posthog\/frontend build/bin\/turbo --filter=@posthog\/frontend build:changed/' \
  "$repo_root/upstream/Dockerfile" > "$unsupported_source"
if POSTHOG_SOURCE_DOCKERFILE="$unsupported_source" \
  "$renderer" "$test_root/unsupported-rendered.Dockerfile" >/dev/null 2>&1; then
  echo "Expected an unsupported upstream Dockerfile to fail closed" >&2
  exit 1
fi

echo "PostHog tool-cache Dockerfile rendering is valid."
