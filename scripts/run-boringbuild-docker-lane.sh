#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

lane="${POSTHOG_BORINGBUILD_LANE:-buildkit}"
ref_slug="${POSTHOG_BORINGBUILD_REF_SLUG:-main}"
scope_suffix="${POSTHOG_BORINGBUILD_SCOPE_SUFFIX:-boringbuild}"
builder_name="${POSTHOG_BORINGBUILD_BUILDER:-posthog-boringbuild-${lane//[^A-Za-z0-9_.-]/-}-$$}"

cleanup_boringbuild_lane() {
  docker buildx rm -f "$builder_name" >/dev/null 2>&1 || true
}
trap cleanup_boringbuild_lane EXIT

case "$lane" in
  oci)
    label="BC OCI"
    benchmark_id="posthog"
    backend="registry"
    cache_backend=""
    mountcache_offloader=""
    ;;
  buildkit)
    label="BC BuildKit Backend"
    benchmark_id="posthog-bc-buildkit-mountcache"
    backend="registry"
    cache_backend="boringcache"
    mountcache_offloader="1"
    ;;
  *)
    echo "Unknown POSTHOG_BORINGBUILD_LANE: $lane (expected oci or buildkit)" >&2
    exit 1
    ;;
esac

if [[ -n "${BUILDKIT_IMAGE:-}" ]]; then
  buildkit_image="$BUILDKIT_IMAGE"
else
  buildkit_image="mirror.gcr.io/moby/buildkit:buildx-stable-1"
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

if [[ "$backend" == "registry" && "$cache_backend" != "boringcache" ]]; then
  docker buildx rm -f "$builder_name" >/dev/null 2>&1 || true
  docker buildx create \
    --name "$builder_name" \
    --driver docker-container \
    --driver-opt "image=${buildkit_image}" \
    --driver-opt network=host \
    --use >/dev/null
  docker buildx inspect "$builder_name" --bootstrap
fi

export BENCHMARK_ID="${BENCHMARK_ID:-$benchmark_id}"
export BENCHMARK_WORKSPACE="$cache_workspace"
export BENCHMARK_PROJECT_REPO="${BENCHMARK_PROJECT_REPO:-PostHog/posthog}"
export BUILDKIT_BACKEND="$backend"
export BORINGCACHE_BUILDKIT_CACHE_BACKEND="$cache_backend"
export BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER="$mountcache_offloader"
export CACHE_LANE="${CACHE_LANE:-rolling}"
export CACHE_SCOPE="${CACHE_SCOPE:-${BENCHMARK_ID}-run-rolling-${ref_slug}-${scope_suffix}}"
export BORINGCACHE_MANAGED_BUILDKIT_IMAGE="$buildkit_image"
export BUILDKIT_IMAGE="$buildkit_image"
if [[ "$cache_backend" == "boringcache" ]]; then
  export BUILDER=""
else
  export BUILDER="$builder_name"
fi
export BORINGCACHE_DOCKER_WRAPPER=always
export BORINGCACHE_PROXY_PORT="${BORINGCACHE_PROXY_PORT:-5310}"
export BORINGCACHE_OBSERVABILITY_JSONL_PATH="${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-/tmp/${BENCHMARK_ID}-boringcache-commit-observability.jsonl}"
export ALLOW_BORINGCACHE_ROLLING_BOOTSTRAP=true
export IMAGE_TAG="${IMAGE_TAG:-posthog-benchmark:${lane}}"
export DOCKERFILE_PATH="${DOCKERFILE_PATH:-upstream/Dockerfile}"
export BENCHMARK_DOCKER_CONTEXT="${BENCHMARK_DOCKER_CONTEXT:-upstream}"
export BENCHMARK_OUTPUTS_PATH="${BENCHMARK_OUTPUTS_PATH:-benchmark-results/${BENCHMARK_ID}-boringcache-rolling.outputs.env}"
export BENCHMARK_PROJECT_REF="${BENCHMARK_PROJECT_REF:-}"

rm -rf benchmark-diagnostics benchmark-results benchmark-session-summary benchmark-storage
mkdir -p benchmark-results benchmark-diagnostics

"$repo_root/scripts/run-boringcache-docker-lane.sh" full
"$repo_root/scripts/write-boringcache-docker-lane-artifacts.sh"
