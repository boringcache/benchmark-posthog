#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dispatcher="$repo_root/scripts/dispatch-buildkit-state-rolling-canary.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/buildkit-state-dispatch-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
calls="$test_root/gh-calls.txt"
mkdir -p "$fake_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "$GH_CALLS"' \
  > "$fake_bin/gh"
chmod +x "$fake_bin/gh"

source_sha="$(printf 'a%.0s' {1..40})"
cli_sha="$(printf 'b%.0s' {1..64})"
image_sha="$(printf 'c%.0s' {1..64})"

run_dispatch() {
  env \
    PATH="$fake_bin:$PATH" \
    GH_CALLS="$calls" \
    GITHUB_REPOSITORY=boringcache/benchmark-posthog \
    GITHUB_REF_NAME=main \
    STATE_CANARY_SOURCE_SHA="$source_sha" \
    STATE_CANARY_CLI_RELEASE_TAG=vcli-canary-test123 \
    STATE_CANARY_CLI_ASSET_SHA256="$cli_sha" \
    STATE_CANARY_PLATFORM=linux-amd64 \
    STATE_CANARY_BUILDKIT_IMAGE="ghcr.io/boringcache/buildkit@sha256:${image_sha}" \
    "$@"
}

run_dispatch "$dispatcher" >/dev/null
grep -Fq -- "workflow run state-sync-v13-cas.yml" "$calls"
grep -Fq -- "--repo boringcache/benchmark-posthog --ref main" "$calls"
grep -Fq -- "-f cache_lane=rolling" "$calls"
grep -Fq -- "-f composition_mode=fixture" "$calls"
grep -Fq -- "-f posthog_source=${source_sha}" "$calls"
grep -Fq -- "-f rolling_scope=main" "$calls"
grep -Fq -- "-f runner_label=ubuntu-latest" "$calls"

: > "$calls"
run_dispatch env STATE_CANARY_PLATFORM=linux-arm64 "$dispatcher" >/dev/null
grep -Fq -- "-f cli_platform=linux-arm64" "$calls"
grep -Fq -- "-f runner_label=ubuntu-24.04-arm" "$calls"

if run_dispatch env STATE_CANARY_CLI_RELEASE_TAG=latest "$dispatcher" >/dev/null 2>&1; then
  echo "Expected a mutable CLI tag to fail" >&2
  exit 1
fi

if run_dispatch env STATE_CANARY_BUILDKIT_IMAGE=ghcr.io/boringcache/buildkit:latest "$dispatcher" >/dev/null 2>&1; then
  echo "Expected a mutable BuildKit image to fail" >&2
  exit 1
fi

if run_dispatch env STATE_CANARY_SOURCE_SHA=main "$dispatcher" >/dev/null 2>&1; then
  echo "Expected a mutable upstream source to fail" >&2
  exit 1
fi

echo "BuildKit state rolling dispatcher is valid."
