#!/usr/bin/env bash
set -euo pipefail

proxy_port="${BORINGCACHE_PROXY_PORT:-5000}"
proxy_log="${BORINGCACHE_PROXY_LOG_PATH:-/tmp/boringcache-proxy-${proxy_port}.log}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_log="$(mktemp -t boringcache-build.XXXXXX)"
status_snapshot_path="$(mktemp -t boringcache-status.XXXXXX)"
max_attempts="${BORINGCACHE_BUILD_MAX_ATTEMPTS:-3}"
cache_export_pattern='expected sha256:.*got sha256:e3b0|error writing layer blob|400 Bad Request|broken pipe'
mode="${1:-full}"
backend="${BUILDKIT_BACKEND:-registry}"
case "$backend" in
  registry|boringcache|state)
    ;;
  *)
    echo "Unsupported BUILDKIT_BACKEND: ${backend}" >&2
    exit 1
    ;;
esac
cache_import_ready="${BORINGCACHE_CACHE_IMPORT_READY:-true}"
cache_requested_from_refs="${BORINGCACHE_CACHE_REQUESTED_FROM_REFS:-}"
cache_used_from_refs="${BORINGCACHE_CACHE_USED_FROM_REFS:-}"
cache_unreadable_from_refs="${BORINGCACHE_CACHE_UNREADABLE_FROM_REFS:-}"
cache_promotion_refs="${BORINGCACHE_DOCKER_PROMOTION_REFS:-}"
allow_rolling_bootstrap="${ALLOW_BORINGCACHE_ROLLING_BOOTSTRAP:-false}"
build_output="${BENCHMARK_BUILD_OUTPUT:-none}"
oci_hydration="${BORINGCACHE_OCI_HYDRATION:-metadata-only}"
docker_tool_cache="${BORINGCACHE_DOCKER_TOOL_CACHE:-}"
docker_wrapper_mode="${BORINGCACHE_DOCKER_WRAPPER:-auto}"
buildkit_cache_backend="${BORINGCACHE_BUILDKIT_CACHE_BACKEND:-${BORINGCACHE_CACHE_EXPORT_TYPE:-}}"
buildkit_mountcache_offloader="${BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER:-}"
cache_export_type="$buildkit_cache_backend"
effective_cache_to=""
cache_args=()
export BORINGCACHE_OBSERVABILITY_INCLUDE_CACHE_OPS="${BORINGCACHE_OBSERVABILITY_INCLUDE_CACHE_OPS:-1}"
start_proxy() { :; }
stop_proxy() { :; }

docker_tool_cache_enabled() {
  local requested_tool="$1"
  local tool
  for tool in ${docker_tool_cache//,/ }; do
    tool="${tool%%:*}"
    [[ "$tool" == "$requested_tool" ]] && return 0
  done
  return 1
}

resolve_docker_tool_cache_value() {
  local value="$1"
  local tool="${value%%:*}"

  if [[ "$value" == *:* ]]; then
    printf '%s\n' "$value"
  else
    printf '%s:%s-%s\n' "$tool" "${CACHE_SCOPE:?Set CACHE_SCOPE}" "$tool"
  fi
}

cache_to_ref() {
  local ref="${CACHE_TO:-}"
  [[ -n "$ref" ]] || return 0
  if [[ -z "$cache_export_type" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  case "$cache_export_type" in
    registry|boringcache)
      ;;
    *)
      echo "Unsupported BuildKit cache backend: ${cache_export_type}" >&2
      exit 1
      ;;
  esac
  case "$ref" in
    type=*,*)
      printf 'type=%s,%s\n' "$cache_export_type" "${ref#type=*,}"
      ;;
    *)
      printf '%s\n' "$ref"
      ;;
  esac
}

use_wrapped_boringcache_build() {
  case "$docker_wrapper_mode" in
    always)
      return 0
      ;;
    never)
      return 1
      ;;
    auto)
      if [[ "$buildkit_cache_backend" == "boringcache" ]]; then
        [[ -n "$docker_tool_cache" ]] && return 0
        [[ -z "${CACHE_TO:-}" ]] && return 0
        return 1
      fi
      [[ -n "$docker_tool_cache" ]] && return 0
      [[ -z "${CACHE_FROM:-}" && -z "${CACHE_TO:-}" ]] && return 0
      return 1
      ;;
    *)
      echo "Unknown BORINGCACHE_DOCKER_WRAPPER: ${docker_wrapper_mode}" >&2
      exit 1
      ;;
  esac
}

native_buildkit_tool_cache_injection() {
  [[ "$buildkit_cache_backend" == "boringcache" ]]
}

verify_posthog_turbo_tool_cache_contract() {
  docker_tool_cache_enabled turbo || return 0

  if native_buildkit_tool_cache_injection; then
    echo "Using native BoringCache BuildKit Turbo tool-cache injection for ${DOCKERFILE_PATH:-Dockerfile}"
    return 0
  fi

  local dockerfile_path="${DOCKERFILE_PATH:-}"
  local dockerfile="${repo_root}/${dockerfile_path}"
  if [[ ! -f "$dockerfile" ]]; then
    echo "Docker tool-cache turbo requested, but Dockerfile does not exist: ${dockerfile_path:-none}" >&2
    exit 1
  fi

  if ! grep -q "boringcache-tool-cache-env" "$dockerfile"; then
    echo "Docker tool-cache turbo requested, but ${dockerfile_path} does not declare the static boringcache-tool-cache-env secret mount." >&2
    echo "Use a Dockerfile rendered with scripts/render-posthog-toolcache-dockerfile.sh or another Dockerfile with the stable tool-cache contract." >&2
    exit 1
  fi

  echo "Verified BoringCache Turbo remote cache secret mounts in ${dockerfile_path}"
}

assert_turbo_remote_cache_used() {
  docker_tool_cache_enabled turbo || return 0

  if grep -q "Remote caching disabled" "$build_log"; then
    capture_proxy_status
    write_build_metrics
    write_build_diagnostics
    echo "Turbo tool-cache was requested, but Turbo reported remote caching disabled." >&2
    grep -E "bin/turbo|Remote caching|TURBO_|boringcache-tool-cache-env|tool env" "$build_log" | tail -n 120 >&2 || true
    exit 1
  fi

  if ! grep -q "Remote caching enabled" "$build_log"; then
    if turbo_tool_cache_layers_restored_from_docker_cache; then
      echo "Turbo tool-cache was requested; Turbo RUN layers were restored from Docker cache before Turbo executed."
      return 0
    fi

    capture_proxy_status
    write_build_metrics
    write_build_diagnostics
    echo "Turbo tool-cache was requested, but the build log did not show Turbo remote caching enabled." >&2
    grep -E "bin/turbo|Remote caching|TURBO_|boringcache-tool-cache-env|tool env" "$build_log" | tail -n 120 >&2 || true
    exit 1
  fi
}

turbo_tool_cache_layers_restored_from_docker_cache() {
  local frontend_step=""
  local plugin_step=""
  local line

  while IFS= read -r line; do
    [[ "$line" == *"RUN "* ]] || continue
    [[ "$line" == *"bin/turbo"* ]] || continue
    [[ "$line" =~ ^#([0-9]+)[[:space:]] ]] || continue

    if [[ "$line" == *"@posthog/frontend build"* ]]; then
      frontend_step="${BASH_REMATCH[1]}"
    elif [[ "$line" == *"@posthog/plugin-transpiler build"* ]]; then
      plugin_step="${BASH_REMATCH[1]}"
    fi
  done < "$build_log"

  [[ -n "$frontend_step" && -n "$plugin_step" ]] || return 1
  turbo_tool_cache_step_restored_from_docker_cache "$frontend_step" &&
    turbo_tool_cache_step_restored_from_docker_cache "$plugin_step"
}

turbo_tool_cache_step_restored_from_docker_cache() {
  local step_id="$1"

  if grep -qE "^#${step_id} CACHED$" "$build_log"; then
    return 0
  fi

  grep -qE "^#${step_id} (sha256:|extracting )" "$build_log" &&
    ! grep -qE "^#${step_id} [0-9]+(\\.[0-9]+)?[[:space:]]" "$build_log"
}

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
find_step_id() {
  local pattern="$1"
  sed -nE "s/^#([0-9]+) ${pattern}.*/\\1/p" "$build_log" | tail -n1
}

find_step_seconds() {
  local step_id="$1"
  [[ -n "$step_id" ]] || return 0
  sed -nE "s/^#${step_id} DONE ([0-9]+(\\.[0-9]+)?)s$/\\1/p" "$build_log" | tail -n1
}

find_progress_seconds() {
  local label="$1"
  sed -nE "s/^#[0-9]+ ${label} ([0-9]+(\\.[0-9]+)?)s done$/\\1/p" "$build_log" | tail -n1
}

buildkit_prewarm_summary() {
  sed -nE 's/^#[0-9]+ cache prewarm (queued=.*) done$/\1/p' "$build_log" | tail -n1
}

summary_value() {
  local details="$1"
  local name="$2"
  printf '%s\n' "$details" | tr ' ' '\n' | awk -F= -v key="$name" '$1 == key { print $2; exit }'
}

duration_seconds_value() {
  local raw="$1"
  [[ -n "$raw" ]] || return 0
  awk -v raw="$raw" '
    function emit(value) {
      if (value == int(value)) {
        printf "%d", value
      } else {
        printf "%.3f", value
      }
    }

    BEGIN {
      rest = raw
      total = 0

      if (rest ~ /^[0-9.]+ms$/) {
        sub(/ms$/, "", rest)
        emit(rest / 1000)
        exit
      }

      if (rest ~ /h/) {
        split(rest, parts, "h")
        total += parts[1] * 3600
        rest = parts[2]
      }

      if (rest ~ /m/) {
        split(rest, parts, "m")
        total += parts[1] * 60
        rest = parts[2]
      }

      if (rest ~ /s$/) {
        sub(/s$/, "", rest)
        if (rest != "") {
          total += rest
        }
      } else if (rest ~ /^[0-9.]+$/) {
        total += rest
      }

      emit(total)
    }
  '
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
  local prewarm_seconds=""
  local prepare_seconds=""
  local send_seconds=""
  local prewarm_summary=""

  import_step="$(find_step_id "importing cache manifest from")"
  export_step="$(find_step_id "exporting cache to boringcache")"
  if [[ -z "$export_step" ]]; then
    export_step="$(find_step_id "exporting cache to registry")"
  fi
  import_seconds="$(find_step_seconds "$import_step")"
  export_seconds="$(find_step_seconds "$export_step")"
  import_status="$(build_import_status)"
  cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$build_log" || true)"
  prewarm_seconds="$(find_progress_seconds "waiting for cache prewarm")"
  prepare_seconds="$(find_progress_seconds "preparing build cache for export")"
  send_seconds="$(find_progress_seconds "sending cache export")"
  prewarm_summary="$(buildkit_prewarm_summary)"

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
  if [[ -n "$prewarm_seconds" ]]; then
    echo "buildkit_cache_prewarm_seconds=$prewarm_seconds" >> "$output_path"
  fi
  if [[ -n "$prepare_seconds" ]]; then
    echo "buildkit_cache_prepare_seconds=$prepare_seconds" >> "$output_path"
  fi
  if [[ -n "$send_seconds" ]]; then
    echo "buildkit_cache_send_seconds=$send_seconds" >> "$output_path"
  fi
  if [[ -n "$prewarm_summary" ]]; then
    write_prewarm_value() {
      local key="$1"
      local name="$2"
      echo "${key}=$(summary_value "$prewarm_summary" "$name")" >> "$output_path"
    }

    write_prewarm_duration() {
      local key="$1"
      local name="$2"
      local raw=""
      raw="$(summary_value "$prewarm_summary" "$name")"
      if [[ -n "$raw" ]]; then
        echo "${key}=$(duration_seconds_value "$raw")" >> "$output_path"
      else
        echo "${key}=" >> "$output_path"
      fi
    }

    write_prewarm_pair() {
      local first_key="$1"
      local second_key="$2"
      local name="$3"
      local raw=""
      raw="$(summary_value "$prewarm_summary" "$name")"
      if [[ "$raw" == */* ]]; then
        echo "${first_key}=${raw%%/*}" >> "$output_path"
        echo "${second_key}=${raw##*/}" >> "$output_path"
      else
        echo "${first_key}=" >> "$output_path"
        echo "${second_key}=" >> "$output_path"
      fi
    }

    echo "buildkit_cache_prewarm_queued=$(summary_value "$prewarm_summary" queued)" >> "$output_path"
    echo "buildkit_cache_prewarm_dropped=$(summary_value "$prewarm_summary" dropped)" >> "$output_path"
    echo "buildkit_cache_prewarm_canceled=$(summary_value "$prewarm_summary" canceled)" >> "$output_path"
    echo "buildkit_cache_prewarm_retried=$(summary_value "$prewarm_summary" retried)" >> "$output_path"
    echo "buildkit_cache_prewarm_deferred=$(summary_value "$prewarm_summary" deferred)" >> "$output_path"
    echo "buildkit_cache_prewarm_prepared=$(summary_value "$prewarm_summary" prepared)" >> "$output_path"
    echo "buildkit_cache_prewarm_body_prepared=$(summary_value "$prewarm_summary" body_prepared)" >> "$output_path"
    echo "buildkit_cache_prewarm_committed_bodies=$(summary_value "$prewarm_summary" committed_bodies)" >> "$output_path"
    echo "buildkit_cache_prewarm_delegated_bodies=$(summary_value "$prewarm_summary" delegated_bodies)" >> "$output_path"
    echo "buildkit_cache_prewarm_owned_bodies=$(summary_value "$prewarm_summary" owned_bodies)" >> "$output_path"
    echo "buildkit_cache_prewarm_owned_body_bytes=$(summary_value "$prewarm_summary" owned_body_bytes)" >> "$output_path"
    echo "buildkit_cache_prewarm_owned_body_max=$(summary_value "$prewarm_summary" owned_body_max)" >> "$output_path"
    echo "buildkit_cache_prewarm_resolved=$(summary_value "$prewarm_summary" resolved)" >> "$output_path"
    echo "buildkit_cache_prewarm_reused=$(summary_value "$prewarm_summary" reused)" >> "$output_path"
    echo "buildkit_cache_prewarm_uploaded=$(summary_value "$prewarm_summary" uploaded)" >> "$output_path"
    echo "buildkit_cache_prewarm_failed=$(summary_value "$prewarm_summary" failed)" >> "$output_path"
    echo "buildkit_cache_prewarm_recursive=$(summary_value "$prewarm_summary" recursive)" >> "$output_path"
    echo "buildkit_cache_prewarm_direct=$(summary_value "$prewarm_summary" direct)" >> "$output_path"
    echo "buildkit_cache_prewarm_missed=$(summary_value "$prewarm_summary" missed)" >> "$output_path"
    write_prewarm_duration buildkit_cache_prewarm_body_time_seconds body_time
    write_prewarm_duration buildkit_cache_prewarm_body_max_seconds body_max
    write_prewarm_duration buildkit_cache_prewarm_resolve_time_seconds resolve_time
    write_prewarm_duration buildkit_cache_prewarm_resolve_max_seconds resolve_max
    write_prewarm_duration buildkit_cache_prewarm_upload_time_seconds upload_time
    write_prewarm_duration buildkit_cache_prewarm_upload_max_seconds upload_max
    write_prewarm_value buildkit_cache_prewarm_queue_depth queue_depth
    write_prewarm_value buildkit_cache_prewarm_max_queue_depth max_queue_depth
    write_prewarm_pair buildkit_cache_prewarm_body_slot_limit buildkit_cache_prewarm_body_slot_max body_slots
    write_prewarm_value buildkit_cache_prewarm_body_active body_active
    write_prewarm_value buildkit_cache_prewarm_body_active_max body_active_max
    write_prewarm_value buildkit_cache_prewarm_body_scaleups body_scaleups
    write_prewarm_value buildkit_cache_prewarm_body_downshifts body_downshifts
    write_prewarm_value buildkit_cache_prewarm_body_backlog_reliefs body_backlog_reliefs
    write_prewarm_value buildkit_cache_prewarm_cpu_pressure_seconds cpu_pressure_seconds
    write_prewarm_value buildkit_cache_prewarm_io_pressure_seconds io_pressure_seconds
    write_prewarm_value buildkit_cache_prewarm_body_phase body_phase
    write_prewarm_duration buildkit_cache_prewarm_image_output_overlap_seconds image_output_overlap
    write_prewarm_value buildkit_cache_prewarm_cache_only_transitions cache_only_transitions
    write_prewarm_value buildkit_cache_prewarm_slot_limit_min slot_limit_min
    write_prewarm_value buildkit_cache_prewarm_slot_limit_max slot_limit_max
    write_prewarm_duration buildkit_cache_prewarm_body_wait_seconds body_wait
    write_prewarm_duration buildkit_cache_prewarm_body_wait_max_seconds body_wait_max
    write_prewarm_pair buildkit_cache_prewarm_workers_current buildkit_cache_prewarm_workers_max workers
  fi
  if [[ -n "$docker_tool_cache" ]]; then
    echo "docker_tool_cache=${docker_tool_cache}" >> "$output_path"
  fi
  if [[ -n "$buildkit_mountcache_offloader" ]]; then
    echo "buildkit_mountcache_offloader=${buildkit_mountcache_offloader}" >> "$output_path"
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
  [[ "$backend" != "state" ]] || return 0
  curl -fsS "http://127.0.0.1:${proxy_port}/_boringcache/status" -o "$output_path" 2>/dev/null || true
}

cache_from_requested() {
  [[ "$mode" =~ ^(full|partial-warm)$ ]] && { [[ -n "$cache_requested_from_refs" ]] || [[ -n "${CACHE_FROM:-}" ]]; }
}

cache_from_usable() {
  [[ "$cache_import_ready" == "true" ]] && { [[ -n "${CACHE_FROM:-}" ]] || [[ -n "$cache_used_from_refs" ]]; }
}

cache_from_import_arg_available() {
  [[ "$cache_import_ready" == "true" && -n "${CACHE_FROM:-}" ]]
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
  if [[ "$backend" == "state" && -s "${BORINGCACHE_STATE_SUMMARY_PATH:-}" ]]; then
    local state_restore_status=""
    state_restore_status="$(jq -r '.restore.status // empty' "$BORINGCACHE_STATE_SUMMARY_PATH" 2>/dev/null || true)"
    case "$state_restore_status" in
      restored)
        echo "ok"
        return
        ;;
      miss)
        echo "bootstrap_miss"
        return
        ;;
      discarded)
        echo "proxy_unreadable"
        return
        ;;
    esac
  fi

  if grep -Eq 'failed to configure .*cache importer|cache manifest.*(manifest unknown|not found)|importing cache manifest.*(manifest unknown|not found)' "$build_log"; then
    echo "not_found"
  elif grep -Eq 'inferred cache manifest type|importing cache manifest' "$build_log"; then
    echo "ok"
  elif cache_from_requested && ! cache_from_usable && [[ "$mode" == "full" && "$allow_rolling_bootstrap" == "true" ]]; then
    echo "bootstrap_miss"
  elif cache_from_requested && ! cache_from_usable; then
    echo "proxy_unreadable"
  else
    echo "none"
  fi
}

transient_build_failure() {
  grep -Eq 'i/o timeout|TLS handshake timeout|DeadlineExceeded: .*failed to resolve source metadata|failed to do request|connection reset by peer|connection refused|503 Service Unavailable|502 Bad Gateway|429 Too Many Requests' "$build_log"
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
    echo "buildkit_cache_backend=${buildkit_cache_backend:-registry}"
    echo "buildkit_mountcache_offloader=${buildkit_mountcache_offloader:-}"
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
    echo "effective_cache_to=${effective_cache_to}"
    echo "cache_export_type=${cache_export_type}"
    echo "registry_proxy_tags=${BORINGCACHE_REGISTRY_PROXY_TAGS:-}"
    echo "docker_tool_cache=${docker_tool_cache}"
    printf 'cache_args='
    if [[ "${cache_args[*]-}" != "" ]]; then
      printf '%q ' "${cache_args[@]}"
    fi
    printf '\n'
    echo "import_status=$(build_import_status)"
    echo "cached_steps=${cached_steps}"
    echo "import_lines<<EOF"
    grep -E 'importing cache manifest|failed to configure .*cache importer|inferred cache manifest type' "$build_log" || true
    echo "EOF"
    echo "export_lines<<EOF"
    grep -E 'exporting cache to (registry|boringcache)|waiting for cache prewarm|cache prewarm|preparing build cache for export|sending cache export|writing (config|cache image manifest)|DONE [0-9.]+s$' "$build_log" | tail -n 120 || true
    echo "EOF"
    echo "mountcache_lines<<EOF"
    grep -E 'boringcache cache mount (hydrate|publish)' "$build_log" | tail -n 160 || true
    echo "EOF"
    echo "proxy_summary<<EOF"
    if [[ "$backend" != "state" ]]; then
      grep -E 'Mode:|OCI Human Tags|Internal Registry Root Tag|Startup mode|Full-tag hydration|OCI body hydration|OCI HEAD|SESSION tool=oci|KV flush|root publish|boringcache cache mount|error|warn' "$proxy_log" | tail -n 160 || true
    fi
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

run_wrapped_boringcache_build() {
  local phase_hint="cold"
  if [[ "$mode" == "partial-warm" ]]; then
    phase_hint="warm"
  elif [[ "${CACHE_LANE:-fresh}" == "rolling" ]]; then
    phase_hint="commit"
  fi
  local cli_backend="$backend"
  if [[ "$buildkit_cache_backend" == "boringcache" ]]; then
    cli_backend="boringcache"
  fi

  local boringcache_args=(
    boringcache docker
    --workspace "${BENCHMARK_WORKSPACE:?Set BENCHMARK_WORKSPACE}"
    --tag "${CACHE_SCOPE:?Set CACHE_SCOPE}"
    --backend "$cli_backend"
    --no-platform
    --no-git
    --metadata-hint "benchmark=posthog"
    --metadata-hint "phase=${phase_hint}"
    --metadata-hint "lane=${CACHE_LANE:-fresh}"
    --metadata-hint "backend=${cli_backend}"
    --fail-on-cache-error
  )

  if [[ "$cli_backend" != "state" ]]; then
    boringcache_args+=(
      --port "$proxy_port"
      --cache-mode max
      --oci-hydration "$oci_hydration"
    )
  fi

  if [[ -n "$docker_tool_cache" && "${BORINGCACHE_DOCKER_TOOL_CACHE_ON_DEMAND:-false}" == "true" ]]; then
    boringcache_args+=(--on-demand)
  fi

  if [[ -n "$docker_tool_cache" ]]; then
    local tool_cache_value
    local resolved_tool_cache_value
    for tool_cache_value in ${docker_tool_cache//,/ }; do
      [[ -n "$tool_cache_value" ]] || continue
      resolved_tool_cache_value="$(resolve_docker_tool_cache_value "$tool_cache_value")"
      boringcache_args+=(--tool-cache "$resolved_tool_cache_value")
    done
  fi

  if [[ "$mode" == "partial-warm" ]]; then
    boringcache_args+=(--read-only)
  fi

  local boringcache_bin
  boringcache_bin="$(command -v boringcache)"
  local boringcache_cmd=("$boringcache_bin")

  local builder_args=()
  if [[ -n "${BUILDER:-}" && "$cli_backend" != "boringcache" ]]; then
    builder_args=(--builder "$BUILDER")
  fi

  local wrapped_cache_args=()
  local cache_arg
  if [[ "${cache_args[*]-}" != "" ]]; then
    for cache_arg in "${cache_args[@]}"; do
      if [[ "$cache_arg" == "--no-cache" ]]; then
        wrapped_cache_args+=("$cache_arg")
      fi
    done
  fi

  : > "$build_log"
  set +e +u
  DOCKER_BUILDKIT=1 BORINGCACHE_TIMING_TRACE=1 "${boringcache_cmd[@]}" "${boringcache_args[@]:1}" -- \
    docker buildx build \
    "${builder_args[@]}" \
    --file "$DOCKERFILE_PATH" \
    --tag "$IMAGE_TAG" \
    --progress=plain \
    "${extra_args[@]}" \
    "${wrapped_cache_args[@]}" \
    "${output_args[@]}" \
    "$BENCHMARK_DOCKER_CONTEXT" 2>&1 | tee "$build_log"
  status=${PIPESTATUS[0]}
  set -e -u
}


attempt=1
verify_posthog_turbo_tool_cache_contract
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
      cache_from_import_arg_available && cache_args+=(--cache-from "$CACHE_FROM")
      cache_to="$(cache_to_ref)"
      effective_cache_to="$cache_to"
      [[ -n "$cache_to" ]] && cache_args+=(--cache-to "$cache_to")
    fi
  elif [[ "$mode" == "seed-cache" ]]; then
    # --no-cache is required for type=registry export: without it, buildx
    # sees cached layers from the builder and skips pushing blobs to the
    # registry proxy, so the proxy never uploads to BoringCache backend.
    cache_args=(--no-cache)
    if [[ "$backend" == "registry" ]]; then
      cache_to="$(cache_to_ref)"
      effective_cache_to="$cache_to"
      [[ -n "$cache_to" ]] && cache_args+=(--cache-to "$cache_to")
    fi
  elif [[ "$mode" == "partial-warm" ]]; then
    # Read-only: no --cache-to.
    if [[ "$backend" == "registry" ]]; then
      cache_from_import_arg_available && cache_args+=(--cache-from "$CACHE_FROM")
    fi
  else
    echo "Unknown build mode: $mode" >&2
    exit 1
  fi

  if use_wrapped_boringcache_build; then
    run_wrapped_boringcache_build
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
    echo "Effective cache args:"
    if [[ "${cache_args[*]-}" != "" ]]; then
      printf '  %q' "${cache_args[@]}"
    fi
    printf '\n'
    set +e +u
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
    set -e -u
  fi

  if [[ "$status" -eq 0 ]]; then
    assert_turbo_remote_cache_used
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
      tail -n 400 "$proxy_log" 2>/dev/null || true
      stop_proxy
      exit 1
    fi
    capture_proxy_status
    if [[ "$backend" == "registry" && "$mode" =~ ^(seed-cache|full)$ ]]; then
      # Stop proxy gracefully so it can flush pending uploads.
      echo "Flushing proxy cache to backend..."
      flush_action_proxy
    fi
    if [[ "$backend" != "state" ]]; then
      echo "=== Proxy log (${mode}, last 200 lines) ==="
      tail -n 200 "$proxy_log" 2>/dev/null || true
      echo "=== End proxy log ==="
    fi
    write_build_metrics
    write_build_diagnostics
    break
  fi

  stop_proxy


  if [[ "$attempt" -ge "$max_attempts" ]]; then
    echo "Build (${mode}) failed after ${max_attempts} attempts" >&2
    tail -n 200 "$build_log" || true
    tail -n 400 "$proxy_log" 2>/dev/null || true
    write_build_diagnostics
    exit "$status"
  fi

  if ! transient_build_failure; then
    echo "Build (${mode}) failed with a non-transient error on attempt ${attempt}/${max_attempts}" >&2
    tail -n 200 "$build_log" || true
    tail -n 400 "$proxy_log" 2>/dev/null || true
    write_build_diagnostics
    exit "$status"
  fi

  echo "Build (${mode}) failed with a transient registry/network error on attempt ${attempt}/${max_attempts}; retrying..." >&2
  attempt=$((attempt + 1))
  sleep $((attempt * 5))

done
