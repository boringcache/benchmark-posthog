#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "BuildKit state rolling dispatch: $*" >&2
  exit 1
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "${name} is required"
}

require_value GITHUB_REPOSITORY
require_value STATE_CANARY_CLI_RELEASE_TAG
require_value STATE_CANARY_CLI_ASSET_SHA256
require_value STATE_CANARY_PLATFORM
require_value STATE_CANARY_BUILDKIT_IMAGE

workflow="${STATE_CANARY_WORKFLOW:-state-sync-v13-cas.yml}"
ref="${STATE_CANARY_REF:-${GITHUB_REF_NAME:-main}}"
rolling_scope="${STATE_CANARY_ROLLING_SCOPE:-main}"
api_origin="${STATE_CANARY_API_ORIGIN:-https://api.boringcache.com}"
plateau_tolerance="${STATE_CANARY_PLATEAU_TOLERANCE_PERCENT:-2}"
warm_generations="${STATE_CANARY_WARM_GENERATIONS:-2}"

case "$STATE_CANARY_CLI_RELEASE_TAG" in
  latest|canary|vcli-canary)
    fail "STATE_CANARY_CLI_RELEASE_TAG must be immutable"
    ;;
esac
[[ "$STATE_CANARY_CLI_RELEASE_TAG" != *[[:space:]]* ]] || \
  fail "STATE_CANARY_CLI_RELEASE_TAG must not contain whitespace"
[[ "$STATE_CANARY_CLI_ASSET_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
  fail "STATE_CANARY_CLI_ASSET_SHA256 must be 64 lowercase hexadecimal characters"
[[ "$STATE_CANARY_BUILDKIT_IMAGE" =~ ^ghcr\.io/boringcache/buildkit@sha256:[0-9a-f]{64}$ ]] || \
  fail "STATE_CANARY_BUILDKIT_IMAGE must be an exact managed image digest"
[[ "$api_origin" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || \
  fail "STATE_CANARY_API_ORIGIN must be an exact HTTPS origin"
[[ "$rolling_scope" =~ ^[A-Za-z0-9._-]+$ ]] || \
  fail "STATE_CANARY_ROLLING_SCOPE must be tag-safe"
case "$plateau_tolerance" in
  1|2|5) ;;
  *) fail "STATE_CANARY_PLATEAU_TOLERANCE_PERCENT must be 1, 2, or 5" ;;
esac
case "$warm_generations" in
  2|4|8) ;;
  *) fail "STATE_CANARY_WARM_GENERATIONS must be 2, 4, or 8" ;;
esac

case "$STATE_CANARY_PLATFORM" in
  linux-amd64)
    runner_label="${STATE_CANARY_RUNNER_LABEL:-ubuntu-latest}"
    ;;
  linux-arm64)
    runner_label="${STATE_CANARY_RUNNER_LABEL:-ubuntu-24.04-arm}"
    ;;
  *)
    fail "STATE_CANARY_PLATFORM must be linux-amd64 or linux-arm64"
    ;;
esac

source_sha="${STATE_CANARY_SOURCE_SHA:-}"
if [[ -z "$source_sha" ]]; then
  source_sha="$(git ls-tree HEAD upstream | awk 'NR == 1 { print $3 }')"
fi
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || \
  fail "could not resolve an exact upstream source SHA"

args=(
  -f run_mode=build-only
  -f cache_lane=rolling
  -f composition_mode=mount
  -f "cli_release_tag=${STATE_CANARY_CLI_RELEASE_TAG}"
  -f "cli_asset_sha256=${STATE_CANARY_CLI_ASSET_SHA256}"
  -f "cli_platform=${STATE_CANARY_PLATFORM}"
  -f "buildkit_image=${STATE_CANARY_BUILDKIT_IMAGE}"
  -f "api_origin=${api_origin}"
  -f "posthog_source=${source_sha}"
  -f "rolling_scope=${rolling_scope}"
  -f "plateau_tolerance_percent=${plateau_tolerance}"
  -f "warm_generations=${warm_generations}"
  -f "runner_label=${runner_label}"
)

for attempt in 1 2 3; do
  if gh workflow run "$workflow" \
    --repo "$GITHUB_REPOSITORY" \
    --ref "$ref" \
    "${args[@]}"; then
    echo "Queued ${STATE_CANARY_PLATFORM} BuildKit state rolling canary for ${source_sha}."
    exit 0
  fi

  if [[ "$attempt" -ge 3 ]]; then
    fail "could not dispatch ${workflow} after ${attempt} attempts"
  fi
  echo "Dispatch failed; retrying (${attempt}/3)" >&2
  sleep 5
done
