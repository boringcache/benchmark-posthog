#!/usr/bin/env bash
#
# Canonical write-benchmark-artifacts.sh
#
# Consolidates the five forks previously found across benchmark repos:
#
#   - 390-line variant (n8n, opentelemetry-java, spring-ai, storybook)
#       baseline: cold/warm timings, cache storage, transfer bytes,
#       hit-behavior note, classification block.
#
#   - 399-line variant (hugo-go)
#       adds --cache-storage-note (free-text annotation surfaced in MD
#       under "Storage note" and JSON under cache.storage_note).
#
#   - 405-line variant (grpc, zed)
#       adds --action-timings-json (path to JSON file inlined into the
#       artifact under "action_timings").
#
#   - 629-line variant (hugo, immich)
#       adds Docker buildkit timings, OCI hydration / blob diagnostics,
#       rolling cache-update diagnostics (rolling_reseed/steady_state_candidate),
#       fresh-warm cache-import-not-ok validity gating.
#
#   - 675-line variant (mastodon, posthog)
#       adds tiny-metadata-churn distinction inside the rolling reseed
#       classifier (rolling_reseed_kind, tiny_metadata_churn) plus
#       BENCHMARK_TINY_METADATA_CHURN_MAX_BLOBS / _MAX_BYTES knobs.
#
# Behavior preservation:
#   - Every flag every fork understood is supported here. Unused flags
#     default to empty and emit JSON null, leaving the consumer
#     (publish-index.rb) to coerce nil with parse_number/dig.
#   - Default values match the most permissive existing fork:
#       reseed_new_blob_threshold defaults to 0
#       tiny_metadata_churn_max_blobs defaults to 1
#       tiny_metadata_churn_max_bytes defaults to 65536
#   - Markdown lines for fork-specific metrics are only emitted when
#     the corresponding input is non-empty, so callers that never pass
#     --docker-cache-import-seconds (etc.) get the same MD they did
#     before.
#   - JSON shape is a strict superset: all blocks every fork emitted
#     are emitted here. New fields are nullable and never required
#     by the aggregator. Build-only/setup splits and Docker rolling
#     first-build fields are emitted with nullable warm fields.
#
set -euo pipefail

benchmark=""
strategy=""
lane="fresh"
project_repo=""
project_ref=""
cold_seconds=""
cold_build_seconds=""
warm1_seconds=""
warm1_build_seconds=""
cache_storage_bytes="0"
cache_storage_source=""
cache_storage_note=""
bytes_uploaded=""
bytes_downloaded=""
hit_behavior_note=""
cli_version="${BENCHMARK_CLI_VERSION:-}"
action_ref="${BENCHMARK_ACTION_REF:-}"
action_sha="${BENCHMARK_ACTION_SHA:-}"
web_revision="${BENCHMARK_WEB_REVISION:-}"
api_url="${BENCHMARK_API_URL:-${BORINGCACHE_API_URL:-https://api.boringcache.com}}"
action_timings_json=""
workspace="${BENCHMARK_WORKSPACE:-${BORINGCACHE_WORKSPACE:-}}"
cache_tag="${BENCHMARK_CACHE_TAG:-${CACHE_SCOPE:-}}"
run_uid="${BENCHMARK_RUN_UID:-}"
mode="${BENCHMARK_MODE:-}"
adapter="${BENCHMARK_ADAPTER:-}"
restore_result="${BENCHMARK_RESTORE_RESULT:-}"
save_result="${BENCHMARK_SAVE_RESULT:-}"
publish_status="${BENCHMARK_PUBLISH_STATUS:-}"
reporting_url="${BENCHMARK_REPORTING_URL:-}"
docker_cache_from_refs="${BENCHMARK_DOCKER_CACHE_FROM_REFS:-${BORINGCACHE_CACHE_USED_FROM_REFS:-}}"
docker_cache_import_ready="${BENCHMARK_DOCKER_CACHE_IMPORT_READY:-${BORINGCACHE_CACHE_IMPORT_READY:-}}"
http_transport="${BENCHMARK_HTTP_TRANSPORT:-}"
http2_enabled="${BENCHMARK_HTTP2_ENABLED:-}"
oci_stream_through_min_bytes="${BENCHMARK_OCI_STREAM_THROUGH_MIN_BYTES:-}"
cache_session_summary_json="${BENCHMARK_CACHE_SESSION_SUMMARY_JSON:-}"
observability_jsonl="${BENCHMARK_OBSERVABILITY_JSONL:-${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}}"
launch_proof_paths="${BENCHMARK_LAUNCH_PROOF_PATHS:-}"
launch_proof_json="${BENCHMARK_LAUNCH_PROOF_JSON:-}"
cache_import_status=""
output_dir="benchmark-results"
docker_cache_import_seconds=""
docker_cache_export_seconds=""
oci_hydration_policy=""
oci_body_local_hits=""
oci_body_remote_fetches=""
oci_body_local_bytes=""
oci_body_remote_bytes=""
oci_body_local_duration_ms=""
oci_body_remote_duration_ms=""
startup_oci_body_inserted=""
startup_oci_body_failures=""
startup_oci_body_cold_blobs=""
startup_oci_body_duration_ms=""
oci_new_blob_count=""
oci_new_blob_bytes=""
oci_upload_requested_blobs=""
oci_upload_already_present=""
oci_upload_batch_seconds=""
reseed_new_blob_threshold="${BENCHMARK_RESEED_NEW_BLOB_THRESHOLD:-0}"
tiny_metadata_churn_max_blobs="${BENCHMARK_TINY_METADATA_CHURN_MAX_BLOBS:-1}"
tiny_metadata_churn_max_bytes="${BENCHMARK_TINY_METADATA_CHURN_MAX_BYTES:-65536}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark)
      benchmark="$2"
      shift 2
      ;;
    --strategy)
      strategy="$2"
      shift 2
      ;;
    --lane)
      lane="$2"
      shift 2
      ;;
    --project-repo)
      project_repo="$2"
      shift 2
      ;;
    --project-ref)
      project_ref="$2"
      shift 2
      ;;
    --cold-seconds)
      cold_seconds="$2"
      shift 2
      ;;
    --cold-build-seconds)
      cold_build_seconds="$2"
      shift 2
      ;;
    --warm1-seconds)
      warm1_seconds="$2"
      shift 2
      ;;
    --warm1-build-seconds)
      warm1_build_seconds="$2"
      shift 2
      ;;
    --cache-storage-bytes)
      cache_storage_bytes="$2"
      shift 2
      ;;
    --cache-storage-source)
      cache_storage_source="$2"
      shift 2
      ;;
    --cache-storage-note)
      cache_storage_note="$2"
      shift 2
      ;;
    --bytes-uploaded)
      bytes_uploaded="$2"
      shift 2
      ;;
    --bytes-downloaded)
      bytes_downloaded="$2"
      shift 2
      ;;
    --hit-behavior-note)
      hit_behavior_note="$2"
      shift 2
      ;;
    --cli-version)
      cli_version="$2"
      shift 2
      ;;
    --action-ref)
      action_ref="$2"
      shift 2
      ;;
    --action-sha)
      action_sha="$2"
      shift 2
      ;;
    --web-revision)
      web_revision="$2"
      shift 2
      ;;
    --api-url)
      api_url="$2"
      shift 2
      ;;
    --workspace)
      workspace="$2"
      shift 2
      ;;
    --cache-tag)
      cache_tag="$2"
      shift 2
      ;;
    --run-uid)
      run_uid="$2"
      shift 2
      ;;
    --mode)
      mode="$2"
      shift 2
      ;;
    --adapter)
      adapter="$2"
      shift 2
      ;;
    --restore-result)
      restore_result="$2"
      shift 2
      ;;
    --save-result)
      save_result="$2"
      shift 2
      ;;
    --publish-status)
      publish_status="$2"
      shift 2
      ;;
    --reporting-url)
      reporting_url="$2"
      shift 2
      ;;
    --docker-cache-from-refs)
      docker_cache_from_refs="$2"
      shift 2
      ;;
    --docker-cache-import-ready)
      docker_cache_import_ready="$2"
      shift 2
      ;;
    --cache-session-summary-json)
      cache_session_summary_json="$2"
      shift 2
      ;;
    --observability-jsonl)
      observability_jsonl="$2"
      shift 2
      ;;
    --launch-proof-path)
      if [[ -n "$launch_proof_paths" ]]; then
        launch_proof_paths+=","
      fi
      launch_proof_paths+="$2"
      shift 2
      ;;
    --launch-proof-paths)
      launch_proof_paths="$2"
      shift 2
      ;;
    --launch-proof-json)
      launch_proof_json="$2"
      shift 2
      ;;
    --cache-import-status)
      cache_import_status="$2"
      shift 2
      ;;
    --action-timings-json)
      action_timings_json="$2"
      shift 2
      ;;
    --docker-cache-import-seconds)
      docker_cache_import_seconds="$2"
      shift 2
      ;;
    --docker-cache-export-seconds)
      docker_cache_export_seconds="$2"
      shift 2
      ;;
    --http-transport)
      http_transport="$2"
      shift 2
      ;;
    --http2-enabled)
      http2_enabled="$2"
      shift 2
      ;;
    --oci-stream-through-min-bytes)
      oci_stream_through_min_bytes="$2"
      shift 2
      ;;
    --oci-hydration-policy)
      oci_hydration_policy="$2"
      shift 2
      ;;
    --oci-body-local-hits)
      oci_body_local_hits="$2"
      shift 2
      ;;
    --oci-body-remote-fetches)
      oci_body_remote_fetches="$2"
      shift 2
      ;;
    --oci-body-local-bytes)
      oci_body_local_bytes="$2"
      shift 2
      ;;
    --oci-body-remote-bytes)
      oci_body_remote_bytes="$2"
      shift 2
      ;;
    --oci-body-local-duration-ms)
      oci_body_local_duration_ms="$2"
      shift 2
      ;;
    --oci-body-remote-duration-ms)
      oci_body_remote_duration_ms="$2"
      shift 2
      ;;
    --startup-oci-body-inserted)
      startup_oci_body_inserted="$2"
      shift 2
      ;;
    --startup-oci-body-failures)
      startup_oci_body_failures="$2"
      shift 2
      ;;
    --startup-oci-body-cold-blobs)
      startup_oci_body_cold_blobs="$2"
      shift 2
      ;;
    --startup-oci-body-duration-ms)
      startup_oci_body_duration_ms="$2"
      shift 2
      ;;
    --oci-new-blob-count)
      oci_new_blob_count="$2"
      shift 2
      ;;
    --oci-new-blob-bytes)
      oci_new_blob_bytes="$2"
      shift 2
      ;;
    --oci-upload-requested-blobs)
      oci_upload_requested_blobs="$2"
      shift 2
      ;;
    --oci-upload-already-present)
      oci_upload_already_present="$2"
      shift 2
      ;;
    --oci-upload-batch-seconds)
      oci_upload_batch_seconds="$2"
      shift 2
      ;;
    --reseed-new-blob-threshold)
      reseed_new_blob_threshold="$2"
      shift 2
      ;;
    --tiny-metadata-churn-max-blobs)
      tiny_metadata_churn_max_blobs="$2"
      shift 2
      ;;
    --tiny-metadata-churn-max-bytes)
      tiny_metadata_churn_max_bytes="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$benchmark" || -z "$strategy" || -z "$project_repo" || -z "$project_ref" || -z "$cold_seconds" ]]; then
  echo "Missing required arguments" >&2
  exit 1
fi

case "$lane" in
  fresh|rolling)
    ;;
  *)
    echo "Unsupported lane: $lane" >&2
    exit 1
    ;;
esac

if [[ -z "$cache_storage_source" ]]; then
  cache_storage_source="unspecified"
fi

if ! [[ "$cache_storage_bytes" =~ ^[0-9]+$ ]]; then
  cache_storage_bytes="0"
fi

json_num_or_null() {
  local v="$1"
  if [[ -z "$v" ]]; then
    echo "null"
  else
    echo "$v"
  fi
}

json_string_or_null() {
  local v="$1"
  if [[ -z "$v" ]]; then
    echo "null"
  else
    jq -Rn --arg value "$v" '$value'
  fi
}

json_bool_or_null() {
  local v="$1"
  case "$v" in
    true|TRUE|1|yes|YES)
      echo "true"
      ;;
    false|FALSE|0|no|NO)
      echo "false"
      ;;
    *)
      echo "null"
      ;;
  esac
}

json_array_from_csv_or_null() {
  local v="$1"
  if [[ -z "$v" ]]; then
    echo "null"
  else
    jq -Rn --arg value "$v" '$value | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
  fi
}

sanitize_uint() {
  local v="$1"
  if [[ -n "$v" && "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    echo ""
  fi
}

sanitize_number() {
  local v="$1"
  if [[ -n "$v" && "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "$v"
  else
    echo ""
  fi
}

sanitize_token() {
  local v="$1"
  if [[ -n "$v" && "$v" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "$v"
  else
    echo ""
  fi
}

health_url_for_api_base() {
  local base="${1%/}"
  case "$base" in
    */v1|*/v2)
      printf '%s/v2/health\n' "${base%/*}"
      ;;
    *)
      printf '%s/v2/health\n' "$base"
      ;;
  esac
}

collect_default_product_refs() {
  if [[ -z "$cli_version" && "$strategy" == "boringcache" ]] && command -v boringcache >/dev/null 2>&1; then
    local version_output
    version_output="$(boringcache --version 2>/dev/null | head -n 1 || true)"
    if [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
      cli_version="v${BASH_REMATCH[1]}"
    else
      cli_version="$version_output"
    fi
  fi

  if [[ -z "$action_ref" && "$strategy" == "boringcache" ]]; then
    action_ref="boringcache/one@v1"
  fi

  if [[ -z "$action_sha" && "$action_ref" =~ ^([^@]+)@(.+)$ ]]; then
    local action_repo="${BASH_REMATCH[1]}"
    local action_ref_name="${BASH_REMATCH[2]}"
    if [[ "$action_ref_name" =~ ^[0-9a-f]{40}$ ]]; then
      action_sha="$action_ref_name"
    elif command -v git >/dev/null 2>&1; then
      local remote_url="https://github.com/${action_repo}.git"
      local resolved refspec
      for refspec in "refs/tags/${action_ref_name}^{}" "refs/tags/${action_ref_name}" "refs/heads/${action_ref_name}"; do
        resolved="$(git ls-remote "$remote_url" "$refspec" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
        if [[ "$resolved" =~ ^[0-9a-f]{40}$ ]]; then
          action_sha="$resolved"
          break
        fi
      done
    fi
  fi

  if [[ -z "$web_revision" && -n "$api_url" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local health_url health_json
    health_url="$(health_url_for_api_base "$api_url")"
    health_json="$(curl -fsS --max-time 5 -A "BoringCacheBenchmark/1.0" "$health_url" 2>/dev/null || true)"
    if [[ -n "$health_json" ]]; then
      web_revision="$(printf '%s' "$health_json" | jq -r '.revision // empty' 2>/dev/null || true)"
    fi
  fi
}

infer_default_launch_context() {
  if [[ -z "$run_uid" && -n "${GITHUB_RUN_ID:-}" ]]; then
    run_uid="gh-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
  fi

  if [[ -z "$mode" && "$strategy" == "boringcache" ]]; then
    case "$benchmark" in
      *hugo*|*immich*|*mastodon*|*posthog*)
        mode="docker"
        ;;
      *grpc*|*bazel*)
        mode="bazel"
        ;;
      *zed*|*sccache*)
        mode="sccache"
        ;;
      *gradle*|*otel*)
        mode="gradle"
        ;;
      *maven*|*spring*)
        mode="maven"
        ;;
      *n8n*|*turbo*)
        mode="turbo"
        ;;
      *go*)
        mode="go"
        ;;
    esac
  fi

  if [[ -z "$adapter" && "$strategy" == "boringcache" ]]; then
    case "$mode" in
      docker|buildkit)
        adapter="oci"
        ;;
      go)
        adapter="gocache"
        ;;
      turbo)
        adapter="turborepo"
        ;;
      *)
        adapter="$mode"
        ;;
    esac
  fi
}

session_summary_payload_from_inputs() {
  if [[ -n "$cache_session_summary_json" ]]; then
    if [[ ! -f "$cache_session_summary_json" ]]; then
      echo "Missing cache session summary JSON: $cache_session_summary_json" >&2
      exit 1
    fi
    jq -c '.' "$cache_session_summary_json"
    return
  fi

  if [[ -n "$observability_jsonl" && -s "$observability_jsonl" ]]; then
    local summary
    summary="$(jq -c 'select(.operation == "cache_session_summary") | .summary // .details // .' "$observability_jsonl" 2>/dev/null | tail -n 1 || true)"
    if [[ -n "$summary" ]]; then
      printf '%s\n' "$summary"
      return
    fi
  fi

  echo "null"
}

launch_proof_paths_payload_from_inputs() {
  if [[ -n "$launch_proof_json" ]]; then
    if [[ ! -f "$launch_proof_json" ]]; then
      echo "Missing launch proof JSON: $launch_proof_json" >&2
      exit 1
    fi
    jq -c '.' "$launch_proof_json"
    return
  fi

  if [[ -n "$launch_proof_paths" ]]; then
    jq -Rn --arg value "$launch_proof_paths" '$value | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
    return
  fi

  echo "[]"
}

if [[ -n "$bytes_uploaded" ]] && ! [[ "$bytes_uploaded" =~ ^[0-9]+$ ]]; then
  bytes_uploaded=""
fi
if [[ -n "$bytes_downloaded" ]] && ! [[ "$bytes_downloaded" =~ ^[0-9]+$ ]]; then
  bytes_downloaded=""
fi
if [[ -n "$cold_build_seconds" ]] && ! [[ "$cold_build_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  cold_build_seconds=""
fi
if [[ -n "$warm1_build_seconds" ]] && ! [[ "$warm1_build_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  warm1_build_seconds=""
fi
cache_import_status="$(sanitize_token "$cache_import_status")"
docker_cache_import_ready="$(sanitize_token "$docker_cache_import_ready")"

if [[ -n "$docker_cache_import_seconds" ]] && ! [[ "$docker_cache_import_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  docker_cache_import_seconds=""
fi
if [[ -n "$docker_cache_export_seconds" ]] && ! [[ "$docker_cache_export_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  docker_cache_export_seconds=""
fi
oci_body_local_hits="$(sanitize_uint "$oci_body_local_hits")"
oci_body_remote_fetches="$(sanitize_uint "$oci_body_remote_fetches")"
oci_body_local_bytes="$(sanitize_uint "$oci_body_local_bytes")"
oci_body_remote_bytes="$(sanitize_uint "$oci_body_remote_bytes")"
oci_body_local_duration_ms="$(sanitize_uint "$oci_body_local_duration_ms")"
oci_body_remote_duration_ms="$(sanitize_uint "$oci_body_remote_duration_ms")"
startup_oci_body_inserted="$(sanitize_uint "$startup_oci_body_inserted")"
startup_oci_body_failures="$(sanitize_uint "$startup_oci_body_failures")"
startup_oci_body_cold_blobs="$(sanitize_uint "$startup_oci_body_cold_blobs")"
startup_oci_body_duration_ms="$(sanitize_uint "$startup_oci_body_duration_ms")"
oci_new_blob_count="$(sanitize_uint "$oci_new_blob_count")"
oci_new_blob_bytes="$(sanitize_uint "$oci_new_blob_bytes")"
oci_upload_requested_blobs="$(sanitize_uint "$oci_upload_requested_blobs")"
oci_upload_already_present="$(sanitize_uint "$oci_upload_already_present")"
oci_upload_batch_seconds="$(sanitize_number "$oci_upload_batch_seconds")"
reseed_new_blob_threshold="$(sanitize_uint "$reseed_new_blob_threshold")"
reseed_new_blob_threshold="${reseed_new_blob_threshold:-0}"
tiny_metadata_churn_max_blobs="$(sanitize_uint "$tiny_metadata_churn_max_blobs")"
tiny_metadata_churn_max_blobs="${tiny_metadata_churn_max_blobs:-1}"
tiny_metadata_churn_max_bytes="$(sanitize_uint "$tiny_metadata_churn_max_bytes")"
tiny_metadata_churn_max_bytes="${tiny_metadata_churn_max_bytes:-65536}"
collect_default_product_refs
infer_default_launch_context

action_timings_payload="null"
if [[ -n "$action_timings_json" ]]; then
  if [[ ! -f "$action_timings_json" ]]; then
    echo "Missing action timings JSON: $action_timings_json" >&2
    exit 1
  fi
  action_timings_payload="$(jq -c '.' "$action_timings_json")"
fi
session_summary_payload="$(session_summary_payload_from_inputs)"
launch_proof_paths_payload="$(launch_proof_paths_payload_from_inputs)"

warm_count=0
warm_total=0
if [[ -n "$warm1_seconds" ]]; then
  warm_count=$((warm_count + 1))
  warm_total=$((warm_total + warm1_seconds))
fi

pct_vs_cold() {
  local value="$1"
  awk -v cold="$cold_seconds" -v v="$value" 'BEGIN { if (cold <= 0) { print "0.00" } else { printf "%.2f", ((cold - v) / cold) * 100 } }'
}

if [[ $warm_count -gt 0 ]]; then
  warm_avg=$(awk -v total="$warm_total" -v count="$warm_count" 'BEGIN { printf "%.2f", total / count }')
  warm_improvement_pct=$(pct_vs_cold "$warm_avg")
else
  warm_avg="null"
  warm_improvement_pct="null"
fi

cache_storage_mib=$(awk -v bytes="$cache_storage_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')
warm_rerun_succeeded=$([[ -n "$warm1_seconds" ]] && echo true || echo false)
cold_setup_seconds=""
warm1_setup_seconds=""
if [[ -n "$cold_seconds" && -n "$cold_build_seconds" ]]; then
  cold_setup_seconds="$(awk -v total="$cold_seconds" -v build="$cold_build_seconds" 'BEGIN { v = total - build; if (v < 0) { v = 0 }; printf "%.0f", v }')"
fi
if [[ -n "$warm1_seconds" && -n "$warm1_build_seconds" ]]; then
  warm1_setup_seconds="$(awk -v total="$warm1_seconds" -v build="$warm1_build_seconds" 'BEGIN { v = total - build; if (v < 0) { v = 0 }; printf "%.0f", v }')"
fi
rolling_first_build_seconds=""
rolling_warm_seconds=""
if [[ "$lane" == "rolling" ]]; then
  rolling_first_build_seconds="$cold_seconds"
  rolling_warm_seconds="$warm1_seconds"
fi
sample_valid=true
reporting_mode="comparative"
reporting_reason=""
reporting_note=""
validity_reason=""

rolling_reseed="null"
steady_state_candidate="null"
rolling_reseed_kind=""
tiny_metadata_churn=false
reseed_reason=""
if [[ "$lane" == "rolling" && "$strategy" == "boringcache" ]]; then
  if [[ -n "$cache_import_status" || -n "$oci_new_blob_count" ]]; then
    if [[ -n "$cache_import_status" && "$cache_import_status" != "ok" ]]; then
      rolling_reseed="null"
      steady_state_candidate="false"
      rolling_reseed_kind="cache_import_not_ok"
      reseed_reason="rolling cache import status was ${cache_import_status}"
    else
      rolling_reseed="false"
      steady_state_candidate="true"
      rolling_reseed_kind="none"
      if [[ -n "$oci_new_blob_count" ]]; then
        reseed_reason="rolling imported prior cache; ${oci_new_blob_count} new OCI blobs recorded as continuous-commit cache updates"
        if [[ -n "$oci_new_blob_bytes" ]]; then
          reseed_reason+=" (${oci_new_blob_bytes} bytes)"
        fi
      else
        reseed_reason="rolling imported prior cache; OCI upload diagnostics unavailable"
      fi
    fi
  fi
fi

if [[ "$strategy" == "boringcache" && "$lane" == "fresh" && -n "$warm1_seconds" && -n "$cache_import_status" && "$cache_import_status" != "ok" ]]; then
  warm_rerun_succeeded=false
  sample_valid=false
  reporting_mode="invalid"
  reporting_reason="fresh_warm_cache_import_not_ok"
  reporting_note="Fresh BoringCache warm reruns require a usable cache import; treat this run as invalid."
  validity_reason="fresh_warm_cache_import_not_ok"
elif [[ "$strategy" == "boringcache" && "$lane" == "rolling" && -n "$cache_import_status" && "$cache_import_status" != "ok" ]]; then
  reporting_mode="investigation_only"
  reporting_reason="rolling_cache_import_not_ok"
  reporting_note="Rolling BoringCache seed completed without a usable cache import; treat this run as investigation-only."
fi

lane_label() {
  case "$1" in
    rolling) echo "Rolling historical" ;;
    *) echo "Fresh isolated" ;;
  esac
}

first_build_label() {
  case "$1" in
    rolling) echo "First build after upstream sync" ;;
    *) echo "Cold build" ;;
  esac
}

comparison_header_label() {
  case "$1" in
    rolling) echo "vs First build" ;;
    *) echo "vs Cold" ;;
  esac
}

mkdir -p "$output_dir"
json_path="$output_dir/${benchmark}-${strategy}-${lane}.json"
md_path="$output_dir/${benchmark}-${strategy}-${lane}.md"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
lane_label_value="$(lane_label "$lane")"
first_build_label_value="$(first_build_label "$lane")"
comparison_header_label_value="$(comparison_header_label "$lane")"

cat > "$json_path" <<JSON
{
  "benchmark": "$benchmark",
  "strategy": "$strategy",
  "lane": "$lane",
  "lane_label": "$lane_label_value",
  "first_build_label": "$first_build_label_value",
  "project": {
    "repo": "$project_repo",
    "ref": "$project_ref"
  },
  "product_refs": {
    "cli_version": $(json_string_or_null "$cli_version"),
    "action_ref": $(json_string_or_null "$action_ref"),
    "action_sha": $(json_string_or_null "$action_sha"),
    "web_revision": $(json_string_or_null "$web_revision"),
    "api_url": $(json_string_or_null "$api_url")
  },
  "workspace": $(json_string_or_null "$workspace"),
  "cache_tag": $(json_string_or_null "$cache_tag"),
  "run_uid": $(json_string_or_null "$run_uid"),
  "mode": $(json_string_or_null "$mode"),
  "adapter": $(json_string_or_null "$adapter"),
  "docker_cache_from_refs": $(json_array_from_csv_or_null "$docker_cache_from_refs"),
  "docker_cache_import_ready": $(json_bool_or_null "$docker_cache_import_ready"),
  "http_transport": $(json_string_or_null "$http_transport"),
  "http2_enabled": $(json_bool_or_null "$http2_enabled"),
  "oci_stream_through_min_bytes": $(json_num_or_null "$oci_stream_through_min_bytes"),
  "restore_result": $(json_string_or_null "$restore_result"),
  "save_result": $(json_string_or_null "$save_result"),
  "publish_status": $(json_string_or_null "$publish_status"),
  "session_summary": $session_summary_payload,
  "reporting_url": $(json_string_or_null "$reporting_url"),
  "launch_proof_paths": $launch_proof_paths_payload,
  "generated_at": "$generated_at",
  "runs": {
    "cold_seconds": $(json_num_or_null "$cold_seconds"),
    "cold_build_seconds": $(json_num_or_null "$cold_build_seconds"),
    "cold_restore_or_setup_seconds": $(json_num_or_null "$cold_setup_seconds"),
    "warm1_seconds": $(json_num_or_null "$warm1_seconds"),
    "warm1_build_seconds": $(json_num_or_null "$warm1_build_seconds"),
    "warm1_restore_or_setup_seconds": $(json_num_or_null "$warm1_setup_seconds"),
    "rolling_first_build_seconds": $(json_num_or_null "$rolling_first_build_seconds"),
    "rolling_warm_seconds": $(json_num_or_null "$rolling_warm_seconds")
  },
  "speed": {
    "warm_average_seconds": $warm_avg,
    "warm_vs_cold_improvement_pct": $warm_improvement_pct
  },
  "cache": {
    "storage_bytes": $cache_storage_bytes,
    "storage_mib": $cache_storage_mib,
    "storage_source": "$cache_storage_source",
    "storage_note": $(json_string_or_null "$cache_storage_note")
  },
  "docker_cache": {
    "import_seconds": $(json_num_or_null "$docker_cache_import_seconds"),
    "export_seconds": $(json_num_or_null "$docker_cache_export_seconds")
  },
  "oci": {
    "hydration_policy": $(json_string_or_null "$oci_hydration_policy"),
    "body_local_hits": $(json_num_or_null "$oci_body_local_hits"),
    "body_remote_fetches": $(json_num_or_null "$oci_body_remote_fetches"),
    "body_local_bytes": $(json_num_or_null "$oci_body_local_bytes"),
    "body_remote_bytes": $(json_num_or_null "$oci_body_remote_bytes"),
    "body_local_duration_ms": $(json_num_or_null "$oci_body_local_duration_ms"),
    "body_remote_duration_ms": $(json_num_or_null "$oci_body_remote_duration_ms"),
    "startup_body_inserted": $(json_num_or_null "$startup_oci_body_inserted"),
    "startup_body_failures": $(json_num_or_null "$startup_oci_body_failures"),
    "startup_body_cold_blobs": $(json_num_or_null "$startup_oci_body_cold_blobs"),
    "startup_body_duration_ms": $(json_num_or_null "$startup_oci_body_duration_ms"),
    "new_blob_count": $(json_num_or_null "$oci_new_blob_count"),
    "new_blob_bytes": $(json_num_or_null "$oci_new_blob_bytes"),
    "upload_requested_blobs": $(json_num_or_null "$oci_upload_requested_blobs"),
    "upload_already_present": $(json_num_or_null "$oci_upload_already_present"),
    "upload_batch_seconds": $(json_num_or_null "$oci_upload_batch_seconds")
  },
  "classification": {
    "sample_valid": $sample_valid,
    "reporting_mode": $(json_string_or_null "$reporting_mode"),
    "reporting_reason": $(json_string_or_null "$reporting_reason"),
    "reporting_note": $(json_string_or_null "$reporting_note"),
    "validity_reason": $(json_string_or_null "$validity_reason"),
    "cache_import_status": $(json_string_or_null "$cache_import_status"),
    "rolling_reseed": $rolling_reseed,
    "steady_state_candidate": $steady_state_candidate,
    "rolling_reseed_kind": $(json_string_or_null "$rolling_reseed_kind"),
    "tiny_metadata_churn": $tiny_metadata_churn,
    "tiny_metadata_churn_max_blobs": $tiny_metadata_churn_max_blobs,
    "tiny_metadata_churn_max_bytes": $tiny_metadata_churn_max_bytes,
    "reseed_new_blob_threshold": $reseed_new_blob_threshold,
    "reseed_reason": $(json_string_or_null "$reseed_reason")
  },
  "action_timings": $action_timings_payload,
  "transfer": {
    "bytes_uploaded": $(json_num_or_null "$bytes_uploaded"),
    "bytes_downloaded": $(json_num_or_null "$bytes_downloaded")
  },
  "hit_behavior": {
    "warm_rerun_succeeded": $warm_rerun_succeeded,
    "note": $(json_string_or_null "$hit_behavior_note")
  }
}
JSON

{
  echo "## ${benchmark} (${strategy}, ${lane_label_value})"
  echo ""
  echo "| Phase | Time | ${comparison_header_label_value} |"
  echo "|-------|------|---------|"
  echo "| ${first_build_label_value} | ${cold_seconds}s | — |"

  if [[ -n "$warm1_seconds" ]]; then
    echo "| Warm #1 | ${warm1_seconds}s | -$(pct_vs_cold "$warm1_seconds")% |"
  fi

  echo ""
  echo "| Metric | Value |"
  echo "|--------|-------|"
  echo "| Lane | ${lane_label_value} |"
  echo "| Project | \`${project_repo}\` |"
  echo "| Commit | \`${project_ref}\` |"
  if [[ -n "$cli_version" ]]; then
    echo "| CLI version | \`${cli_version}\` |"
  fi
  if [[ -n "$action_ref" ]]; then
    echo "| Action ref | \`${action_ref}\` |"
  fi
  if [[ -n "$action_sha" ]]; then
    echo "| Action SHA | \`${action_sha}\` |"
  fi
  if [[ -n "$web_revision" ]]; then
    echo "| Web revision | \`${web_revision}\` |"
  fi

  if [[ "$warm_avg" != "null" ]]; then
    echo "| Warm avg | ${warm_avg}s (${warm_improvement_pct}% faster) |"
  fi
  if [[ -n "$cold_build_seconds" ]]; then
    echo "| Cold build-only | ${cold_build_seconds}s |"
  fi
  if [[ -n "$cold_setup_seconds" ]]; then
    echo "| Cold restore/setup | ${cold_setup_seconds}s |"
  fi
  if [[ -n "$warm1_build_seconds" ]]; then
    echo "| Warm build-only | ${warm1_build_seconds}s |"
  fi
  if [[ -n "$warm1_setup_seconds" ]]; then
    echo "| Warm restore/setup | ${warm1_setup_seconds}s |"
  fi
  echo "| Reporting mode | ${reporting_mode} |"
  if [[ "$sample_valid" != "true" ]]; then
    echo "| Validity reason | ${validity_reason} |"
  fi
  if [[ -n "$reporting_reason" ]]; then
    echo "| Reporting reason | ${reporting_reason} |"
  fi
  if [[ -n "$cache_import_status" ]]; then
    echo "| Cache import status | ${cache_import_status} |"
  fi

  if [[ "$cache_storage_bytes" != "0" ]]; then
    echo "| Cache storage | ${cache_storage_mib} MiB |"
    echo "| Storage source | ${cache_storage_source} |"
    if [[ -n "$cache_storage_note" ]]; then
      echo "| Storage note | ${cache_storage_note} |"
    fi
  fi

  if [[ -n "$docker_cache_import_seconds" ]]; then
    echo "| Docker cache import | ${docker_cache_import_seconds}s |"
  fi
  if [[ -n "$docker_cache_export_seconds" ]]; then
    echo "| Docker cache export | ${docker_cache_export_seconds}s |"
  fi
  if [[ -n "$oci_hydration_policy" ]]; then
    echo "| OCI hydration | ${oci_hydration_policy} |"
  fi
  if [[ -n "$http_transport" ]]; then
    echo "| HTTP transport | ${http_transport} |"
  fi
  if [[ -n "$oci_stream_through_min_bytes" ]]; then
    echo "| OCI stream-through min bytes | ${oci_stream_through_min_bytes} |"
  fi
  if [[ -n "$oci_body_remote_fetches" ]]; then
    echo "| OCI remote body fetches | ${oci_body_remote_fetches} |"
  fi
  if [[ -n "$oci_body_remote_bytes" ]]; then
    echo "| OCI remote body bytes | ${oci_body_remote_bytes} |"
  fi
  if [[ -n "$startup_oci_body_inserted" ]]; then
    echo "| Startup OCI bodies inserted | ${startup_oci_body_inserted} |"
  fi
  if [[ -n "$startup_oci_body_cold_blobs" ]]; then
    echo "| Startup OCI cold bodies | ${startup_oci_body_cold_blobs} |"
  fi
  if [[ -n "$oci_new_blob_count" ]]; then
    echo "| New OCI blobs uploaded | ${oci_new_blob_count} |"
  fi
  if [[ -n "$oci_new_blob_bytes" ]]; then
    echo "| New OCI blob bytes | ${oci_new_blob_bytes} |"
  fi
  if [[ "$rolling_reseed" != "null" ]]; then
    rolling_label="continuous-commit update"
    if [[ "$rolling_reseed" == "true" ]]; then
      if [[ "$tiny_metadata_churn" == "true" ]]; then
        rolling_label="tiny metadata churn"
      else
        rolling_label="reseed"
      fi
    fi
    echo "| Rolling classification | ${rolling_label} |"
    echo "| Rolling classification reason | ${reseed_reason} |"
  fi
  if [[ -n "$reporting_note" ]]; then
    echo "| Reporting note | ${reporting_note} |"
  fi

  if [[ -n "$bytes_uploaded" ]]; then
    echo "| Bytes uploaded | ${bytes_uploaded} |"
  fi
  if [[ -n "$bytes_downloaded" ]]; then
    echo "| Bytes downloaded | ${bytes_downloaded} |"
  fi
  if [[ -n "$hit_behavior_note" ]]; then
    echo "| Note | ${hit_behavior_note} |"
  fi
} > "$md_path"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "json_path=$json_path" >> "$GITHUB_OUTPUT"
  echo "md_path=$md_path" >> "$GITHUB_OUTPUT"
fi
