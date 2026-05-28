#!/usr/bin/env bash
set -euo pipefail

mode="${1:-full}"
benchmark_id="${BENCHMARK_ID:-docker}"
workspace="${BENCHMARK_WORKSPACE:-${GITHUB_REPOSITORY:-boringcache/benchmarks}}"
cache_scope="${CACHE_SCOPE:?Set CACHE_SCOPE}"
dockerfile_path="${DOCKERFILE_PATH:?Set DOCKERFILE_PATH}"
docker_context="${BENCHMARK_DOCKER_CONTEXT:?Set BENCHMARK_DOCKER_CONTEXT}"
image_tag="${IMAGE_TAG:-${benchmark_id}:native}"
buildkit_image="${BUILDKIT_IMAGE:-moby/buildkit:buildx-stable-1}"
cli_image="${BORINGCACHE_NATIVE_CLI_IMAGE:-buildpack-deps:noble-curl}"
proxy_port="${BORINGCACHE_PROXY_PORT:-5100}"
oci_hydration="${BORINGCACHE_OCI_HYDRATION:-metadata-only}"
build_log="$(mktemp /tmp/boringcache-native-build.XXXXXX.log)"
native_tool_evidence_path="$(mktemp /tmp/boringcache-native-tool.XXXXXX.json)"
buildctl_dir="$(mktemp -d /tmp/boringcache-buildctl.XXXXXX)"
run_slug="$(printf '%s' "${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${benchmark_id}-${mode}-${cache_scope}" | shasum -a 256 | awk '{print substr($1, 1, 12)}')"
network="bc-native-${run_slug}"
root_volume="bc-native-${run_slug}-root"
cache_volume="bc-native-${run_slug}-cache"
buildkit_name="bc-native-${run_slug}-bk"
cli_name="bc-native-${run_slug}-cli"

case "$mode" in
  full | seed-cache | partial-warm)
    ;;
  *)
    echo "Unknown build mode: $mode" >&2
    exit 1
    ;;
esac

boringcache_bin="$(command -v boringcache || true)"
if [[ -z "$boringcache_bin" || ! -x "$boringcache_bin" ]]; then
  echo "Missing boringcache binary on PATH" >&2
  exit 1
fi

if [[ -z "${BORINGCACHE_RESTORE_TOKEN:-}${BORINGCACHE_SAVE_TOKEN:-}${BORINGCACHE_API_TOKEN:-}" ]]; then
  echo "Set BORINGCACHE_RESTORE_TOKEN/BORINGCACHE_SAVE_TOKEN or BORINGCACHE_API_TOKEN." >&2
  exit 1
fi

context_abs="$(cd "$docker_context" && pwd)"
dockerfile_dir="$(cd "$(dirname "$dockerfile_path")" && pwd)"
dockerfile_abs="${dockerfile_dir}/$(basename "$dockerfile_path")"
if [[ "$dockerfile_abs" == "$context_abs"/* ]]; then
  dockerfile_rel="${dockerfile_abs#"$context_abs"/}"
elif [[ "$dockerfile_abs" == "$context_abs" ]]; then
  dockerfile_rel="$(basename "$dockerfile_path")"
else
  echo "Native BuildKit lane requires the Dockerfile to live under the Docker context." >&2
  echo "dockerfile_path=${dockerfile_path}" >&2
  echo "docker_context=${docker_context}" >&2
  exit 1
fi

cleanup() {
  docker rm -f "$buildkit_name" >/dev/null 2>&1 || true
  docker volume rm -f "$root_volume" "$cache_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$buildctl_dir"
}
trap cleanup EXIT

container="$(docker create "$buildkit_image")"
docker cp "${container}:/usr/bin/buildctl" "${buildctl_dir}/buildctl"
docker rm "$container" >/dev/null
chmod +x "${buildctl_dir}/buildctl"

docker network create "$network" >/dev/null
docker volume create "$root_volume" >/dev/null
docker volume create "$cache_volume" >/dev/null

docker run -d \
  --name "$buildkit_name" \
  --network "$network" \
  --privileged \
  -v "${root_volume}:/var/lib/buildkit" \
  "$buildkit_image" \
  --addr tcp://0.0.0.0:1234 \
  --oci-worker=true \
  --containerd-worker=false \
  --oci-worker-gc=false >/dev/null

for _ in $(seq 1 90); do
  if docker exec "$buildkit_name" buildctl --addr tcp://127.0.0.1:1234 debug workers >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

dockerfile_opts=()
while IFS= read -r raw_arg; do
  arg="${raw_arg#"${raw_arg%%[![:space:]]*}"}"
  arg="${arg%"${arg##*[![:space:]]}"}"
  [[ -n "$arg" ]] || continue

  case "$arg" in
    --build-arg=*)
      dockerfile_opts+=(--opt "build-arg:${arg#--build-arg=}")
      ;;
    --build-arg\ *)
      dockerfile_opts+=(--opt "build-arg:${arg#--build-arg }")
      ;;
    --target=*)
      dockerfile_opts+=(--opt "target=${arg#--target=}")
      ;;
    --target\ *)
      dockerfile_opts+=(--opt "target=${arg#--target }")
      ;;
    --platform=*)
      dockerfile_opts+=(--opt "platform=${arg#--platform=}")
      ;;
    --platform\ *)
      dockerfile_opts+=(--opt "platform=${arg#--platform }")
      ;;
    --label=*)
      dockerfile_opts+=(--opt "label:${arg#--label=}")
      ;;
    --label\ *)
      dockerfile_opts+=(--opt "label:${arg#--label }")
      ;;
    *)
      echo "Unsupported native BuildKit docker_build_args entry: ${arg}" >&2
      exit 1
      ;;
  esac
done <<< "${DOCKER_BUILD_EXTRA_ARGS:-}"

buildctl_command=(
  buildctl --addr "tcp://${buildkit_name}:1234" build
  --frontend dockerfile.v0
  --local context=/src
  --local dockerfile=/src
  --opt "filename=${dockerfile_rel}"
  --progress=plain
)

if [[ "$mode" == "seed-cache" ]]; then
  buildctl_command+=(--no-cache)
fi
buildctl_command+=("${dockerfile_opts[@]}")

phase_hint="cold"
if [[ "$mode" == "partial-warm" ]]; then
  phase_hint="warm"
elif [[ "${CACHE_LANE:-fresh}" == "rolling" ]]; then
  phase_hint="commit"
fi

boringcache_args=(
  boringcache buildkit
  --workspace "$workspace"
  --tag "$cache_scope"
  --no-platform
  --no-git
  --host 0.0.0.0
  --endpoint-host "$cli_name"
  --port "$proxy_port"
  --backend native
  --buildkit-root /buildkit
  --buildkit-cache-root /cache
  --native-tool-evidence-json /evidence/native-tool.json
  --oci-hydration "$oci_hydration"
  --metadata-hint "benchmark=${benchmark_id}"
  --metadata-hint "phase=${phase_hint}"
  --metadata-hint "lane=${CACHE_LANE:-fresh}"
  --metadata-hint "backend=native"
  --fail-on-cache-error
)

if [[ "$mode" == "partial-warm" ]]; then
  boringcache_args+=(--read-only)
fi

timed_command=(
  bash -lc
  'started="$(date +%s)"; "$@"; status="$?"; ended="$(date +%s)"; echo "boringcache timing: container command status=${status} seconds=$((ended - started))"; exit "$status"'
  boringcache-timing
)

github_env=(
  -e GITHUB_ACTIONS
  -e GITHUB_REPOSITORY
  -e GITHUB_RUN_ID
  -e GITHUB_RUN_ATTEMPT
  -e GITHUB_REF
  -e GITHUB_REF_NAME
  -e GITHUB_REF_TYPE
  -e GITHUB_SHA
  -e GITHUB_EVENT_NAME
  -e GITHUB_BASE_REF
  -e GITHUB_HEAD_REF
  -e GITHUB_SERVER_URL
)

started="$(date +%s)"
set +e
docker run --rm \
  --privileged \
  --name "$cli_name" \
  --network "$network" \
  -e BORINGCACHE_API_TOKEN \
  -e BORINGCACHE_RESTORE_TOKEN \
  -e BORINGCACHE_SAVE_TOKEN \
  -e BORINGCACHE_OCI_BODY_PREFETCH_MAX_MB \
  -e BORINGCACHE_TIMING_TRACE=1 \
  "${github_env[@]}" \
  -v "${boringcache_bin}:/usr/local/bin/boringcache:ro" \
  -v "${buildctl_dir}/buildctl:/usr/local/bin/buildctl:ro" \
  -v "${context_abs}:/src:ro" \
  -v "${root_volume}:/buildkit" \
  -v "${cache_volume}:/cache" \
  -v "$(dirname "$native_tool_evidence_path"):/evidence" \
  "$cli_image" \
  "${timed_command[@]}" \
  "${boringcache_args[@]}" \
  -- \
  "${buildctl_command[@]}" \
  2>&1 | tee "$build_log"
status="${PIPESTATUS[0]}"
set -e
ended="$(date +%s)"
wall_seconds="$((ended - started))"

cp "$(dirname "$native_tool_evidence_path")/native-tool.json" "$native_tool_evidence_path" 2>/dev/null || true

cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$build_log" || true)"
if grep -Eq 'failed to configure .*cache importer|cache manifest.*(manifest unknown|not found)|importing cache manifest.*(manifest unknown|not found)' "$build_log"; then
  import_status="not_found"
elif grep -Eq 'inferred cache manifest type|importing cache manifest' "$build_log"; then
  import_status="ok"
else
  import_status="none"
fi

import_step="$(sed -nE 's/^#([0-9]+) importing cache manifest.*/\1/p' "$build_log" | tail -n1 || true)"
if [[ -n "$import_step" ]]; then
  import_seconds="$(sed -nE "s/^#${import_step} DONE ([0-9]+(\\.[0-9]+)?)s$/\\1/p" "$build_log" | tail -n1 || true)"
else
  import_seconds=""
fi

final_export_seconds="$(sed -nE 's/^buildkit-cache online-publish: final export status=[0-9]+ seconds=([0-9]+)$/\1/p' "$build_log" | tail -n1 || true)"
final_save_seconds="$(sed -nE 's/^buildkit-cache online-publish: final save status=[0-9]+ seconds=([0-9]+)$/\1/p' "$build_log" | tail -n1 || true)"
final_publish_seconds=""
if [[ -n "$final_export_seconds" && -n "$final_save_seconds" ]]; then
  final_publish_seconds="$(awk -v export_s="$final_export_seconds" -v save_s="$final_save_seconds" 'BEGIN { printf "%.3f", export_s + save_s }')"
fi

write_metric() {
  local key="$1"
  local value="$2"
  [[ -n "$value" && "$value" != "null" ]] || return 0
  echo "${key}=${value}" >> "$metrics_output"
}

if [[ -n "${BENCHMARK_METRICS_OUTPUT:-}" ]]; then
  metrics_output="$BENCHMARK_METRICS_OUTPUT"
  mkdir -p "$(dirname "$metrics_output")"
  : > "$metrics_output"
  write_metric cache_import_status "$import_status"
  write_metric docker_cache_import_seconds "$import_seconds"
  write_metric docker_cache_export_seconds "$final_publish_seconds"
  write_metric buildkit_backend native
  if [[ -s "$native_tool_evidence_path" ]] && command -v jq >/dev/null 2>&1; then
    write_metric oci_new_blob_count "$(jq -r '.publisher.final_publish_blob_count // empty' "$native_tool_evidence_path" 2>/dev/null || true)"
    write_metric oci_new_blob_bytes "$(jq -r '.publisher.final_publish_layer_bytes // empty' "$native_tool_evidence_path" 2>/dev/null || true)"
    write_metric oci_upload_requested_blobs "$(jq -r '.publisher.final_publish_blob_count // empty' "$native_tool_evidence_path" 2>/dev/null || true)"
    write_metric oci_upload_already_present "$(jq -r '.publisher.upload_already_present // empty' "$native_tool_evidence_path" 2>/dev/null || true)"
    write_metric oci_upload_batch_seconds "$final_publish_seconds"
  fi
fi

if [[ -n "${BENCHMARK_DIAGNOSTICS_OUTPUT:-}" ]]; then
  diagnostics_output="$BENCHMARK_DIAGNOSTICS_OUTPUT"
  mkdir -p "$(dirname "$diagnostics_output")"
  {
    echo "strategy=boringcache"
    echo "buildkit_backend=native"
    echo "mode=${mode}"
    echo "cache_scope=${cache_scope}"
    echo "workspace=${workspace}"
    echo "image_tag=${image_tag}"
    echo "dockerfile_path=${dockerfile_path}"
    echo "docker_context=${docker_context}"
    echo "dockerfile_rel=${dockerfile_rel}"
    echo "import_status=${import_status}"
    echo "cached_steps=${cached_steps}"
    echo "wall_seconds=${wall_seconds}"
    echo "container_command_seconds=$(sed -nE 's/^boringcache timing: container command status=[0-9]+ seconds=([0-9]+)$/\1/p' "$build_log" | tail -n1 || true)"
    echo "native_tool_evidence=${native_tool_evidence_path}"
    echo "buildctl_args<<EOF"
    printf '%q ' "${buildctl_command[@]}" "${dockerfile_opts[@]}"
    printf '\n'
    echo "EOF"
    echo "import_lines<<EOF"
    grep -E 'importing cache manifest|failed to configure .*cache importer|inferred cache manifest type' "$build_log" || true
    echo "EOF"
    echo "publish_lines<<EOF"
    grep -E 'buildkit-cache online-publish|Native BuildKit publish|boringcache timing: cas save|error|warn' "$build_log" | tail -n 160 || true
    echo "EOF"
    echo "slow_done_lines<<EOF"
    grep -E '^#[0-9]+ DONE [0-9]+(\.[0-9]+)?s$' "$build_log" | tail -n 80 || true
    echo "EOF"
    if [[ -s "$native_tool_evidence_path" ]]; then
      echo "native_tool_summary<<EOF"
      jq -c '{restore, publisher, command, publish}' "$native_tool_evidence_path" 2>/dev/null || cat "$native_tool_evidence_path"
      echo "EOF"
    fi
  } > "$diagnostics_output"
fi

if [[ "$status" -ne 0 ]]; then
  echo "Native BuildKit benchmark failed with status ${status}" >&2
  tail -n 200 "$build_log" >&2 || true
  exit "$status"
fi

if [[ "$mode" == "partial-warm" && "$import_status" != "ok" ]]; then
  echo "Warm native BuildKit build completed without a usable cache import (status: ${import_status}); refusing invalid fresh sample." >&2
  if [[ -n "${BENCHMARK_METRICS_OUTPUT:-}" && -s "${BENCHMARK_METRICS_OUTPUT}" ]]; then
    cat "${BENCHMARK_METRICS_OUTPUT}" >&2
  fi
  exit 1
fi
