#!/usr/bin/env bash
set -euo pipefail

proxy_port="${BORINGCACHE_PROXY_PORT:-5000}"
proxy_log="${BORINGCACHE_PROXY_LOG_PATH:-/tmp/boringcache-proxy-${proxy_port}.log}"
build_log="$(mktemp /tmp/boringcache-build.XXXXXX.log)"
status_snapshot_path="$(mktemp /tmp/boringcache-status.XXXXXX.json)"
max_attempts=1
cache_export_pattern='expected sha256:.*got sha256:e3b0|error writing layer blob|400 Bad Request|broken pipe'
mode="${1:-full}"
backend="${BUILDKIT_BACKEND:-registry}"
cache_import_ready="${BORINGCACHE_CACHE_IMPORT_READY:-true}"
cache_requested_from_refs="${BORINGCACHE_CACHE_REQUESTED_FROM_REFS:-}"
cache_used_from_refs="${BORINGCACHE_CACHE_USED_FROM_REFS:-}"
cache_unreadable_from_refs="${BORINGCACHE_CACHE_UNREADABLE_FROM_REFS:-}"
cache_promotion_refs="${BORINGCACHE_DOCKER_PROMOTION_REFS:-}"
allow_rolling_bootstrap="${ALLOW_BORINGCACHE_ROLLING_BOOTSTRAP:-false}"
build_output="${BENCHMARK_BUILD_OUTPUT:-none}"
oci_hydration="${BORINGCACHE_OCI_HYDRATION:-metadata-only}"
native_tool_evidence_dir="$(mktemp -d /tmp/boringcache-native-tool.XXXXXX)"
chmod 0777 "$native_tool_evidence_dir" 2>/dev/null || true
native_tool_evidence_path="${native_tool_evidence_dir}/native-tool.json"
export BORINGCACHE_OBSERVABILITY_INCLUDE_CACHE_OPS="${BORINGCACHE_OBSERVABILITY_INCLUDE_CACHE_OPS:-1}"
start_proxy() { :; }
stop_proxy() { :; }
ensure_proxy_available() {
  local started elapsed
  started="$(date +%s)"
  while true; do
    if curl -fsS "http://127.0.0.1:${proxy_port}/_boringcache/status" -o "$status_snapshot_path" 2>/dev/null; then
      return 0
    fi
    elapsed=$(($(date +%s) - started))
    if (( elapsed >= 5 )); then
      return 1
    fi
    sleep 1
  done
}
flush_action_proxy() {
  local pid_file="${BORINGCACHE_PROXY_PID_FILE:-/tmp/boringcache-proxy.pid}"
  [[ -s "$pid_file" ]] || return 0

  local pid=""
  pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Registry proxy (PID: $pid) already exited"
    return 0
  fi

  echo "Stopping registry proxy (PID: $pid)..."
  if ! kill -TERM "$pid" 2>/dev/null; then
    echo "Failed to send SIGTERM to registry proxy (PID: $pid); continuing"
    return 0
  fi

  local started elapsed
  started="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$(($(date +%s) - started))
    if (( elapsed > 0 && elapsed % 30 == 0 )); then
      echo "Waiting for registry proxy to flush and exit... (${elapsed}s elapsed)"
    fi
  done
  elapsed=$(($(date +%s) - started))
  echo "Registry proxy exited gracefully after ${elapsed}s"
}
cleanup() { :; }
trap cleanup EXIT

find_step_id() {
  local pattern="$1"
  sed -nE "s/^#([0-9]+) ${pattern}.*/\\1/p" "$build_log" | tail -n1
}

find_step_seconds() {
  local step_id="$1"
  [[ -n "$step_id" ]] || return 0
  sed -nE "s/^#${step_id} DONE ([0-9]+(\\.[0-9]+)?)s$/\\1/p" "$build_log" | tail -n1
}

write_build_metrics() {
  local output_path="${BENCHMARK_METRICS_OUTPUT:-}"
  [[ -n "$output_path" ]] || return 0

  local import_step=""
  local export_step=""
  local import_seconds=""
  local export_seconds=""
  local import_status=""
  local cached_steps=""

  import_step="$(find_step_id "importing cache manifest from")"
  export_step="$(find_step_id "exporting cache to registry")"
  import_seconds="$(find_step_seconds "$import_step")"
  export_seconds="$(find_step_seconds "$export_step")"
  import_status="$(build_import_status)"
  cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$build_log" || true)"

  mkdir -p "$(dirname "$output_path")"
  : > "$output_path"
  echo "cache_import_status=$import_status" >> "$output_path"
  echo "buildkit_cached_steps=$cached_steps" >> "$output_path"
  if [[ -n "$import_seconds" ]]; then
    echo "docker_cache_import_seconds=$import_seconds" >> "$output_path"
  fi
  if [[ -n "$export_seconds" ]]; then
    echo "docker_cache_export_seconds=$export_seconds" >> "$output_path"
  fi
  if [[ -n "${BORINGCACHE_BLOB_DOWNLOAD_CONCURRENCY:-}" ]]; then
    echo "blob_download_concurrency_override=${BORINGCACHE_BLOB_DOWNLOAD_CONCURRENCY}" >> "$output_path"
  fi
  if [[ -n "${BORINGCACHE_BLOB_PREFETCH_CONCURRENCY:-}" ]]; then
    echo "blob_prefetch_concurrency_override=${BORINGCACHE_BLOB_PREFETCH_CONCURRENCY}" >> "$output_path"
  fi
  if [[ -n "${BORINGCACHE_OCI_STREAM_THROUGH_MIN_BYTES:-}" ]]; then
    echo "oci_stream_through_min_bytes=${BORINGCACHE_OCI_STREAM_THROUGH_MIN_BYTES}" >> "$output_path"
  fi
  if [[ "$backend" == "auto" ]]; then
    echo "buildkit_backend=auto" >> "$output_path"
    if [[ -s "$native_tool_evidence_path" ]]; then
      echo "native_tool_evidence=$native_tool_evidence_path" >> "$output_path"
      append_native_tool_metrics "$native_tool_evidence_path" || true
    fi
  fi

  if [[ -s "$status_snapshot_path" ]] && command -v jq >/dev/null 2>&1; then
    append_status_metric() {
      local key="$1"
      local jq_expr="$2"
      local value=""
      value="$(jq -r "$jq_expr // empty" "$status_snapshot_path" 2>/dev/null || true)"
      if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$key=$value" >> "$output_path"
      fi
    }

    append_status_metric oci_hydration_policy '.startup_prefetch.startup_prefetch_oci_hydration'
    append_status_metric startup_oci_body_inserted '.startup_prefetch.startup_prefetch_oci_body_inserted'
    append_status_metric startup_oci_body_failures '.startup_prefetch.startup_prefetch_oci_body_failures'
    append_status_metric startup_oci_body_cold_blobs '.startup_prefetch.startup_prefetch_oci_body_cold_blobs'
    append_status_metric startup_oci_body_duration_ms '.startup_prefetch.startup_prefetch_oci_body_duration_ms'
    append_status_metric oci_body_local_hits '.oci_body.oci_body_local_hits'
    append_status_metric oci_body_remote_fetches '.oci_body.oci_body_remote_fetches'
    append_status_metric oci_body_local_bytes '.oci_body.oci_body_local_bytes'
    append_status_metric oci_body_remote_bytes '.oci_body.oci_body_remote_bytes'
    append_status_metric oci_body_local_duration_ms '.oci_body.oci_body_local_duration_ms'
    append_status_metric oci_body_remote_duration_ms '.oci_body.oci_body_remote_duration_ms'
    append_status_metric proxy_blob_download_max_concurrency '.session_summary.proxy.blob_download_max_concurrency'
    append_status_metric proxy_blob_prefetch_max_concurrency '.session_summary.proxy.blob_prefetch_max_concurrency'
    append_status_metric proxy_blob_prefetch_concurrency_source '.session_summary.proxy.blob_prefetch_concurrency_source'
    append_status_metric oci_stream_through_count '.oci_engine.oci_engine_stream_through_count'
    append_status_metric oci_stream_through_bytes '.oci_engine.oci_engine_stream_through_bytes'
    append_status_metric oci_stream_through_verify_duration_ms '.oci_engine.oci_engine_stream_through_verify_duration_ms'
    append_status_metric oci_stream_through_verify_failures '.oci_engine.oci_engine_stream_through_verify_failures'
    append_status_metric oci_stream_through_cache_promotion_failures '.oci_engine.oci_engine_stream_through_cache_promotion_failures'
  fi

  local observability_path="${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}"
  if [[ -n "$observability_path" && -s "$observability_path" ]] && command -v jq >/dev/null 2>&1; then
    detail_value() {
      local details="$1"
      local name="$2"
      printf '%s\n' "$details" | tr ' ' '\n' | awk -F= -v key="$name" '$1 == key { print $2; exit }'
    }
    append_metric() {
      local key="$1"
      local value="$2"
      if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$key=$value" >> "$output_path"
      fi
    }

    local plan_details=""
    plan_details="$(jq -r 'select(.operation == "oci_blob_upload_plan") | .details // empty' "$observability_path" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$plan_details" ]]; then
      append_metric oci_upload_requested_blobs "$(detail_value "$plan_details" requested_blobs)"
      append_metric oci_new_blob_count "$(detail_value "$plan_details" upload_urls)"
      append_metric oci_upload_already_present "$(detail_value "$plan_details" already_present)"
    else
      append_metric oci_new_blob_count "0"
    fi

    local uploaded_blob_bytes=""
    uploaded_blob_bytes="$(jq -s -r '
      ([range(0; length) as $i | select(.[$i].operation == "oci_blob_upload_plan") | $i] | last) as $plan
      | if $plan == null then
          0
        else
          ([range(($plan + 1); length) as $i | .[$i] | select(.operation == "oci_blob_upload") | (.request_bytes // 0)] | add // 0)
        end
    ' "$observability_path" 2>/dev/null || true)"
    append_metric oci_new_blob_bytes "${uploaded_blob_bytes:-0}"

    local batch_duration_ms=""
    batch_duration_ms="$(jq -r 'select(.operation == "oci_blob_upload_batch") | .duration_ms // empty' "$observability_path" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$batch_duration_ms" ]]; then
      awk -v ms="$batch_duration_ms" 'BEGIN { printf "oci_upload_batch_seconds=%.3f\n", ms / 1000 }' >> "$output_path"
    fi
  fi
}

append_native_tool_metrics() {
  local evidence_file="$1"
  [[ -s "$evidence_file" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local requested uploaded already_present uploaded_bytes export_seconds save_seconds
  requested="$(jq -r '.publisher.final_save_checked_blob_count // .publisher.final_save_graph_blob_count // empty' "$evidence_file" 2>/dev/null || true)"
  uploaded="$(jq -r '.publisher.final_save_uploaded_blob_count // empty' "$evidence_file" 2>/dev/null || true)"
  already_present="$(jq -r '.publisher.final_save_already_present_blob_count // empty' "$evidence_file" 2>/dev/null || true)"
  uploaded_bytes="$(jq -r '.publisher.final_save_uploaded_blob_bytes // .publisher.final_save_missing_blob_bytes // empty' "$evidence_file" 2>/dev/null || true)"
  export_seconds="$(jq -r '.publisher.final_export_seconds // empty' "$evidence_file" 2>/dev/null || true)"
  save_seconds="$(jq -r '.publisher.final_save_seconds // empty' "$evidence_file" 2>/dev/null || true)"
  if [[ -z "$already_present" && "$requested" =~ ^[0-9]+$ && "$uploaded" =~ ^[0-9]+$ ]]; then
    already_present="$(( requested > uploaded ? requested - uploaded : 0 ))"
  fi

  append_metric() {
    local key="$1"
    local value="$2"
    if [[ -n "$value" && "$value" != "null" ]]; then
      echo "$key=$value" >> "$output_path"
    fi
  }

  append_metric oci_upload_requested_blobs "$requested"
  append_metric oci_new_blob_count "$uploaded"
  append_metric oci_upload_already_present "$already_present"
  append_metric oci_new_blob_bytes "$uploaded_bytes"
  append_metric oci_upload_batch_seconds "$save_seconds"
  if [[ "$export_seconds" =~ ^[0-9]+([.][0-9]+)?$ && "$save_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v export_s="$export_seconds" -v save_s="$save_seconds" 'BEGIN { printf "docker_cache_export_seconds=%.3f\n", export_s + save_s }' >> "$output_path"
  fi
}


capture_proxy_status() {
  local output_path="${1:-$status_snapshot_path}"
  curl -fsS "http://127.0.0.1:${proxy_port}/_boringcache/status" -o "$output_path" 2>/dev/null || true
}

cache_from_requested() {
  [[ "$mode" =~ ^(full|partial-warm)$ ]] && { [[ -n "$cache_requested_from_refs" ]] || [[ -n "${CACHE_FROM:-}" ]]; }
}

cache_from_usable() {
  [[ -n "${CACHE_FROM:-}" ]] || [[ -n "$cache_used_from_refs" ]]
}

require_readable_cache_import() {
  cache_from_requested || return 0

  if ! cache_from_usable; then
    echo "BoringCache Docker import had no usable refs." >&2
    echo "requested refs: ${cache_requested_from_refs}" >&2
    echo "used refs: ${cache_used_from_refs}" >&2
    echo "unreadable refs: ${cache_unreadable_from_refs}" >&2
    if [[ "$mode" == "full" && "$allow_rolling_bootstrap" == "true" ]]; then
      echo "Continuing without a readable import so this rolling run can publish the rolling-scope OCI alias." >&2
      return 0
    fi
    write_build_diagnostics
    exit 1
  fi

  if [[ "$cache_import_ready" != "true" ]]; then
    echo "BoringCache Docker import was not ready." >&2
    echo "requested refs: ${cache_requested_from_refs}" >&2
    echo "used refs: ${cache_used_from_refs}" >&2
    echo "unreadable refs: ${cache_unreadable_from_refs}" >&2
    if [[ "$mode" == "full" && "$allow_rolling_bootstrap" == "true" ]]; then
      echo "Continuing with the usable import subset so this rolling run can refresh the rolling-scope OCI alias." >&2
      return 0
    fi
    write_build_diagnostics
    exit 1
  fi
}

build_import_status() {
  if grep -Eq 'inferred cache manifest type|importing cache manifest' "$build_log"; then
    echo "ok"
  elif grep -Eq 'failed to configure .*cache importer' "$build_log"; then
    echo "not_found"
  elif cache_from_requested && ! cache_from_usable; then
    echo "proxy_unreadable"
  else
    echo "none"
  fi
}

write_build_diagnostics() {
  local output_path="${BENCHMARK_DIAGNOSTICS_OUTPUT:-}"
  [[ -n "$output_path" ]] || return 0

  local cached_steps=""
  cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$build_log" || true)"
  local observability_path="${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}"

  mkdir -p "$(dirname "$output_path")"
  {
    echo "strategy=boringcache"
    echo "buildkit_backend=${backend}"
    echo "mode=${mode}"
    echo "builder=${BUILDER:-}"
    echo "cache_scope=${CACHE_SCOPE:-}"
    echo "cache_from=${CACHE_FROM:-}"
    echo "cache_import_ready=${cache_import_ready}"
    echo "cache_requested_from_refs=${cache_requested_from_refs}"
    echo "cache_used_from_refs=${cache_used_from_refs}"
    echo "cache_unreadable_from_refs=${cache_unreadable_from_refs}"
    echo "cache_promotion_refs=${cache_promotion_refs}"
    echo "cache_to=${CACHE_TO:-}"
    echo "registry_proxy_tags=${BORINGCACHE_REGISTRY_PROXY_TAGS:-}"
    echo "blob_download_concurrency_override=${BORINGCACHE_BLOB_DOWNLOAD_CONCURRENCY:-}"
    echo "blob_prefetch_concurrency_override=${BORINGCACHE_BLOB_PREFETCH_CONCURRENCY:-}"
    echo "oci_stream_through_min_bytes=${BORINGCACHE_OCI_STREAM_THROUGH_MIN_BYTES:-}"
    printf 'cache_args='
    printf '%q ' "${cache_args[@]}"
    printf '\n'
    echo "import_status=$(build_import_status)"
    echo "cached_steps=${cached_steps}"
    echo "import_lines<<EOF"
    grep -E 'importing cache manifest|failed to configure .*cache importer|inferred cache manifest type' "$build_log" || true
    echo "EOF"
    echo "export_lines<<EOF"
    grep -E 'exporting cache to registry|DONE [0-9.]+s$' "$build_log" | tail -n 80 || true
    echo "EOF"
    echo "proxy_summary<<EOF"
    grep -E 'Mode:|OCI Human Tags|Internal Registry Root Tag|Startup mode|Full-tag hydration|OCI body hydration|OCI HEAD|SESSION tool=oci|KV flush|root publish|error|warn' "$proxy_log" | tail -n 160 || true
    echo "EOF"
    echo "proxy_status<<EOF"
    if [[ -s "$status_snapshot_path" ]]; then
      cat "$status_snapshot_path"
    fi
    echo "EOF"
    echo "slow_done_lines<<EOF"
    grep -E '^#[0-9]+ DONE [0-9]+(\.[0-9]+)?s$' "$build_log" | tail -n 80 || true
    echo "EOF"
    echo "observability_jsonl=${observability_path}"
    echo "native_tool_evidence=${native_tool_evidence_path}"
    if [[ -s "$native_tool_evidence_path" ]]; then
      echo "native_tool_summary<<EOF"
      jq -c '{restore, publisher, command, publish}' "$native_tool_evidence_path" 2>/dev/null || cat "$native_tool_evidence_path"
      echo "EOF"
    fi
    if [[ -n "$observability_path" && -s "$observability_path" ]]; then
      printf 'observability_events='
      wc -l < "$observability_path" | tr -d ' '
      printf '\n'
      echo "observability_summary<<EOF"
      grep -E 'cache_session_summary|oci_blob_upload|upload_session_commit|cache_finalize_publish|receipt|429|rate' "$observability_path" | tail -n 160 || true
      echo "EOF"
    fi
  } > "$output_path"
}

run_auto_build() {
  local phase_hint="cold"
  if [[ "$mode" == "partial-warm" ]]; then
    phase_hint="warm"
  elif [[ "${CACHE_LANE:-fresh}" == "rolling" ]]; then
    phase_hint="commit"
  fi

  local boringcache_args=(
    boringcache docker
    --workspace "${BENCHMARK_WORKSPACE:?Set BENCHMARK_WORKSPACE}"
    --tag "${CACHE_SCOPE:?Set CACHE_SCOPE}"
    --backend auto
    --port "$proxy_port"
    --cache-mode max
    --no-platform
    --no-git
    --oci-hydration "$oci_hydration"
    --metadata-hint "benchmark=${BENCHMARK_ID:-docker}"
    --metadata-hint "phase=${phase_hint}"
    --metadata-hint "lane=${CACHE_LANE:-fresh}"
    --metadata-hint "backend=auto"
    --native-tool-evidence-json "$native_tool_evidence_path"
    --fail-on-cache-error
  )
  if [[ "$mode" == "partial-warm" ]]; then
    boringcache_args+=(--read-only)
  fi

  local boringcache_bin
  boringcache_bin="$(command -v boringcache)"
  local boringcache_cmd=("$boringcache_bin")
  if [[ "${BORINGCACHE_AUTO_USE_SUDO:-}" != "0" && "${GITHUB_ACTIONS:-}" == "true" && "$(uname -s)" == "Linux" && "$(id -u)" != "0" ]] && command -v sudo >/dev/null 2>&1; then
    echo "Auto backend using sudo so BoringCache can read the Docker BuildKit root on GitHub-hosted Linux." >&2
    boringcache_cmd=(sudo -E "$boringcache_bin")
  fi

  : > "$build_log"
  set +e
  DOCKER_BUILDKIT=1 BORINGCACHE_TIMING_TRACE=1 "${boringcache_cmd[@]}" "${boringcache_args[@]:1}" -- \
    docker buildx build \
    --file "$DOCKERFILE_PATH" \
    --tag "$IMAGE_TAG" \
    --progress=plain \
    "${extra_args[@]}" \
    "${cache_args[@]}" \
    "${output_args[@]}" \
    "$BENCHMARK_DOCKER_CONTEXT" 2>&1 | tee "$build_log"
  status=${PIPESTATUS[0]}
  set -e
}


attempt=1
while true; do
  cache_args=()
  extra_args=()
  output_args=()
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    extra_args+=("$arg")
  done <<< "${DOCKER_BUILD_EXTRA_ARGS:-}"

  case "$build_output" in
    none)
      ;;
    load)
      output_args+=(--load)
      ;;
    local-registry)
      output_args+=(--push)
      ;;
    *)
      echo "Unknown BENCHMARK_BUILD_OUTPUT: ${build_output}" >&2
      exit 1
      ;;
  esac

  if [[ "$mode" == "full" ]]; then
    if [[ "$backend" == "registry" ]]; then
      [[ -n "${CACHE_FROM:-}" ]] && cache_args+=(--cache-from "$CACHE_FROM")
      [[ -n "${CACHE_TO:-}" ]] && cache_args+=(--cache-to "$CACHE_TO")
    fi
  elif [[ "$mode" == "seed-cache" ]]; then
    # --no-cache is required for type=registry export: without it, buildx
    # sees cached layers from the builder and skips pushing blobs to the
    # registry proxy, so the proxy never uploads to BoringCache backend.
    cache_args=(--no-cache)
    if [[ "$backend" == "registry" ]]; then
      [[ -n "${CACHE_TO:-}" ]] && cache_args+=(--cache-to "$CACHE_TO")
    fi
  elif [[ "$mode" == "partial-warm" ]]; then
    # Read-only: no --cache-to.
    if [[ "$backend" == "registry" ]]; then
      [[ -n "${CACHE_FROM:-}" ]] && cache_args+=(--cache-from "$CACHE_FROM")
    fi
  else
    echo "Unknown build mode: $mode" >&2
    exit 1
  fi

  if [[ "$backend" == "auto" ]]; then
    run_auto_build
  else
    require_readable_cache_import
    start_proxy
    if ! ensure_proxy_available; then
      echo "Registry proxy status was unavailable before build start (attempt ${attempt}/${max_attempts})" >&2
      tail -n 200 "$proxy_log" || true
      if [[ "$attempt" -ge "$max_attempts" ]]; then
        write_build_diagnostics
        exit 1
      fi
      stop_proxy
      attempt=$((attempt + 1))
      sleep 3
      continue
    fi

    : > "$build_log"
    set +e
    DOCKER_BUILDKIT=1 docker buildx build \
      --builder "$BUILDER" \
      --file "$DOCKERFILE_PATH" \
      --tag "$IMAGE_TAG" \
      --progress=plain \
      "${extra_args[@]}" \
      "${cache_args[@]}" \
      "${output_args[@]}" \
      "$BENCHMARK_DOCKER_CONTEXT" 2>&1 | tee "$build_log"
    status=${PIPESTATUS[0]}
    set -e
  fi

  if [[ "$status" -eq 0 ]]; then
    import_status="$(build_import_status)"
    if [[ "$mode" == "partial-warm" && "$import_status" != "ok" ]]; then
      capture_proxy_status
      write_build_metrics
      echo "Warm build completed without a usable registry cache import (status: ${import_status}); refusing invalid fresh sample." >&2
      if [[ -n "${BENCHMARK_METRICS_OUTPUT:-}" && -s "$BENCHMARK_METRICS_OUTPUT" ]]; then
        cat "$BENCHMARK_METRICS_OUTPUT" >&2
      fi
      exit 1
    fi
    if [[ "$mode" =~ ^(full|seed-cache)$ ]] && grep -Eq "$cache_export_pattern" "$build_log"; then
      capture_proxy_status
      write_build_metrics
      write_build_diagnostics
      echo "Build succeeded but registry cache export reported an error; failing benchmark." >&2
      tail -n 200 "$build_log" || true
      tail -n 400 "$proxy_log" || true
      stop_proxy
      exit 1
    fi
    capture_proxy_status
    if [[ "$backend" == "registry" && "$mode" =~ ^(seed-cache|full)$ ]]; then
      # Stop proxy gracefully so it can flush pending uploads.
      echo "Flushing proxy cache to backend..."
      flush_action_proxy
    fi
    # Dump proxy log for diagnostics
    echo "=== Proxy log (${mode}, last 200 lines) ==="
    tail -n 200 "$proxy_log" 2>/dev/null || true
    echo "=== End proxy log ==="
    write_build_metrics
    write_build_diagnostics
    break
  fi

  stop_proxy


  if [[ "$attempt" -ge "$max_attempts" ]]; then
    echo "Build (${mode}) failed after ${max_attempts} attempts" >&2
    tail -n 200 "$build_log" || true
    tail -n 400 "$proxy_log" || true
    write_build_diagnostics
    exit "$status"
  fi

done
