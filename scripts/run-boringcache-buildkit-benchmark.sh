#!/usr/bin/env bash
set -euo pipefail

proxy_port="${BORINGCACHE_PROXY_PORT:-5000}"
proxy_log="${BORINGCACHE_PROXY_LOG_PATH:-/tmp/boringcache-proxy-${proxy_port}.log}"
build_log="$(mktemp /tmp/boringcache-build.XXXXXX.log)"
status_snapshot_path="$(mktemp /tmp/boringcache-status.XXXXXX.json)"
max_attempts=1
cache_export_pattern='expected sha256:.*got sha256:e3b0|error writing layer blob|400 Bad Request|broken pipe'
mode="${1:-full}"
cache_import_ready="${BORINGCACHE_CACHE_IMPORT_READY:-true}"
cache_requested_from_refs="${BORINGCACHE_CACHE_REQUESTED_FROM_REFS:-}"
cache_used_from_refs="${BORINGCACHE_CACHE_USED_FROM_REFS:-}"
cache_unreadable_from_refs="${BORINGCACHE_CACHE_UNREADABLE_FROM_REFS:-}"
cache_promotion_refs="${BORINGCACHE_DOCKER_PROMOTION_REFS:-}"
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

  import_step="$(find_step_id "importing cache manifest from")"
  export_step="$(find_step_id "exporting cache to registry")"
  import_seconds="$(find_step_seconds "$import_step")"
  export_seconds="$(find_step_seconds "$export_step")"
  import_status="$(build_import_status)"

  mkdir -p "$(dirname "$output_path")"
  : > "$output_path"
  echo "cache_import_status=$import_status" >> "$output_path"
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
    echo "BoringCache Docker import had no usable refs; refusing invalid cache sample." >&2
    echo "requested refs: ${cache_requested_from_refs}" >&2
    echo "used refs: ${cache_used_from_refs}" >&2
    echo "unreadable refs: ${cache_unreadable_from_refs}" >&2
    write_build_diagnostics
    exit 1
  fi

  if [[ "$cache_import_ready" != "true" ]]; then
    echo "BoringCache Docker import was not ready; refusing invalid cache sample." >&2
    echo "requested refs: ${cache_requested_from_refs}" >&2
    echo "used refs: ${cache_used_from_refs}" >&2
    echo "unreadable refs: ${cache_unreadable_from_refs}" >&2
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


attempt=1
while true; do
  cache_args=()
  if [[ "$mode" == "full" ]]; then
    [[ -n "${CACHE_FROM:-}" ]] && cache_args+=(--cache-from "$CACHE_FROM")
    [[ -n "${CACHE_TO:-}" ]] && cache_args+=(--cache-to "$CACHE_TO")
  elif [[ "$mode" == "seed-cache" ]]; then
    # --no-cache is required for type=registry export: without it, buildx
    # sees cached layers from the builder and skips pushing blobs to the
    # registry proxy, so the proxy never uploads to BC backend.
    cache_args=(--no-cache)
    [[ -n "${CACHE_TO:-}" ]] && cache_args+=(--cache-to "$CACHE_TO")
  elif [[ "$mode" == "partial-warm" ]]; then
    # Read-only: no --cache-to.
    [[ -n "${CACHE_FROM:-}" ]] && cache_args+=(--cache-from "$CACHE_FROM")
  else
    echo "Unknown build mode: $mode" >&2
    exit 1
  fi
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
    "${cache_args[@]}" \
    "$BENCHMARK_DOCKER_CONTEXT" 2>&1 | tee "$build_log"
  status=${PIPESTATUS[0]}
  set -e

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
    if [[ "$mode" =~ ^(seed-cache|full)$ ]]; then
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
