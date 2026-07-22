#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ref_slug="${POSTHOG_BORINGBUILD_REF_SLUG:-main}"
scope_suffix="${POSTHOG_BORINGBUILD_SCOPE_SUFFIX:-boringbuild}"
label="BoringCache managed BuildKit"
benchmark_id="posthog"

if [[ -n "${BUILDKIT_IMAGE:-}" ]]; then
  buildkit_image="$BUILDKIT_IMAGE"
else
  buildkit_image="ghcr.io/boringcache/buildkit:v0.30.0-bc"
fi

boringcache_candidate=""
if [[ -x /workspace/bin/boringcache ]]; then
  boringcache_candidate="/workspace/bin/boringcache"
elif [[ -x "$repo_root/boringbuild/bin/boringcache" ]]; then
  boringcache_candidate="$repo_root/boringbuild/bin/boringcache"
elif [[ -x "$repo_root/boringcache-linux-musl-amd64.local" ]]; then
  boringcache_candidate="$repo_root/boringcache-linux-musl-amd64.local"
elif [[ -n "${BORINGCACHE_BIN:-}" && -x "$BORINGCACHE_BIN" ]]; then
  boringcache_candidate="$BORINGCACHE_BIN"
elif [[ -n "${BORINGBUILD_REMOTE_BORINGCACHE_BIN:-}" && -x "$BORINGBUILD_REMOTE_BORINGCACHE_BIN" ]]; then
  boringcache_candidate="$BORINGBUILD_REMOTE_BORINGCACHE_BIN"
fi

if [[ -n "$boringcache_candidate" ]]; then
  install -m 0755 "$boringcache_candidate" /usr/local/bin/boringcache
fi

if ! command -v boringcache >/dev/null 2>&1; then
  echo "boringcache CLI not found. Put a Linux boringcache binary at boringbuild/bin/boringcache, boringcache-linux-musl-amd64.local, or /workspace/bin/boringcache." >&2
  exit 1
fi

if [[ -z "${BORINGCACHE_RESTORE_TOKEN:-}" ]]; then
  echo "Missing BORINGCACHE_RESTORE_TOKEN" >&2
  exit 1
fi
if [[ -z "${BORINGCACHE_SAVE_TOKEN:-}" ]]; then
  echo "Missing BORINGCACHE_SAVE_TOKEN" >&2
  exit 1
fi
cache_workspace="${BENCHMARK_WORKSPACE:-${BORINGCACHE_DEFAULT_WORKSPACE:-}}"
if [[ -z "$cache_workspace" ]]; then
  echo "Missing BENCHMARK_WORKSPACE or BORINGCACHE_DEFAULT_WORKSPACE" >&2
  exit 1
fi
export BORINGCACHE_API_TOKEN="${BORINGCACHE_API_TOKEN:-${BORINGCACHE_RESTORE_TOKEN}}"

echo "Running ${label} through BoringBuild"
boringcache --version

export BENCHMARK_ID="${BENCHMARK_ID:-$benchmark_id}"
export BENCHMARK_WORKSPACE="$cache_workspace"
export BENCHMARK_PROJECT_REPO="${BENCHMARK_PROJECT_REPO:-PostHog/posthog}"
export BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER="${BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER:-1}"
export CACHE_LANE="${CACHE_LANE:-rolling}"
export CACHE_SCOPE="${CACHE_SCOPE:-${BENCHMARK_ID}-run-rolling-${ref_slug}-${scope_suffix}}"
export BORINGCACHE_MANAGED_BUILDKIT_IMAGE="$buildkit_image"
export BUILDKIT_IMAGE="$buildkit_image"
export BORINGCACHE_PROXY_PORT="${BORINGCACHE_PROXY_PORT:-5310}"
export BORINGCACHE_OBSERVABILITY_JSONL_PATH="${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-/tmp/${BENCHMARK_ID}-boringcache-commit-observability.jsonl}"
export ALLOW_BORINGCACHE_ROLLING_BOOTSTRAP=true
export IMAGE_TAG="${IMAGE_TAG:-posthog-benchmark:managed}"
export DOCKERFILE_PATH="${DOCKERFILE_PATH:-upstream/Dockerfile}"
export BENCHMARK_DOCKER_CONTEXT="${BENCHMARK_DOCKER_CONTEXT:-upstream}"
export BENCHMARK_OUTPUTS_PATH="${BENCHMARK_OUTPUTS_PATH:-benchmark-results/${BENCHMARK_ID}-boringcache-rolling.outputs.env}"
export BENCHMARK_PROJECT_REF="${BENCHMARK_PROJECT_REF:-}"

rm -rf benchmark-diagnostics benchmark-results benchmark-session-summary benchmark-storage
mkdir -p benchmark-results benchmark-diagnostics

"$repo_root/scripts/run-boringcache-docker-lane.sh" full
"$repo_root/scripts/write-boringcache-docker-lane-artifacts.sh"
