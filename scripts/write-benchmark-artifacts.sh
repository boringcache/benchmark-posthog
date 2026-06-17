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
#       rolling cache-bootstrap/update diagnostics (legacy rolling_reseed/steady_state_candidate),
#       fresh-warm cache-import-not-ok validity gating.
#
#   - 675-line variant (mastodon, posthog)
#       adds tiny-metadata-churn distinction inside the rolling bootstrap
#       classifier (legacy rolling_reseed_kind, tiny_metadata_churn) plus
#       BENCHMARK_TINY_METADATA_CHURN_MAX_BLOBS / _MAX_BYTES knobs.
#
# Behavior preservation:
#   - Every flag every fork understood is supported here. Unused flags
#     default to empty and emit JSON null, leaving the consumer
#     (publish-index.rb) to coerce nil with parse_number/dig.
#   - Default values match the most permissive existing fork:
#       legacy reseed_new_blob_threshold defaults to 0
#       tiny_metadata_churn_max_blobs defaults to 1
#       tiny_metadata_churn_max_bytes defaults to 65536
#   - Markdown lines for fork-specific metrics are only emitted when
#     the corresponding input is non-empty, so callers that never pass
#     --docker-cache-import-seconds (etc.) get the same MD they did
#     before.
#   - JSON shape is a strict superset: all blocks every fork emitted
#     are emitted here. New fields are nullable and never required
#     by the aggregator. Build-only/setup splits and Docker rolling
#     commit-build fields are emitted with nullable warm fields.
#   - GitHub run context is emitted uniformly for every lane so native,
#     OCI, ECR, and Actions Cache artifacts can be compared by run id,
#     run number, and attempt without guessing from artifact names.
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
cache_storage_breakdown_json=""
bytes_uploaded=""
network_bytes_uploaded=""
bytes_downloaded=""
hit_behavior_note=""
tool_outcomes_json=""
native_tool_evidence_json="${BENCHMARK_NATIVE_TOOL_EVIDENCE_JSON:-}"
native_tool_stats_file="${BENCHMARK_NATIVE_TOOL_STATS_FILE:-}"
native_tool_kind="${BENCHMARK_NATIVE_TOOL_KIND:-}"
sccache_stats_file="${BENCHMARK_SCCACHE_STATS_FILE:-}"
cli_version="${BENCHMARK_CLI_VERSION:-}"
action_ref="${BENCHMARK_ACTION_REF:-}"
action_sha="${BENCHMARK_ACTION_SHA:-}"
web_revision="${BENCHMARK_WEB_REVISION:-}"
api_url="${BENCHMARK_API_URL:-${BORINGCACHE_API_URL:-https://api.boringcache.com}}"
action_timings_json=""
github_repository="${BENCHMARK_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
github_workflow="${BENCHMARK_GITHUB_WORKFLOW:-${GITHUB_WORKFLOW:-}}"
github_job="${BENCHMARK_GITHUB_JOB:-${GITHUB_JOB:-}}"
github_run_id="${BENCHMARK_GITHUB_RUN_ID:-${GITHUB_RUN_ID:-}}"
github_run_number="${BENCHMARK_GITHUB_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
github_run_attempt="${BENCHMARK_GITHUB_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-}}"
github_ref="${BENCHMARK_GITHUB_REF:-${GITHUB_REF:-}}"
github_ref_name="${BENCHMARK_GITHUB_REF_NAME:-${GITHUB_REF_NAME:-}}"
github_sha="${BENCHMARK_GITHUB_SHA:-${GITHUB_SHA:-}}"
github_server_url="${BENCHMARK_GITHUB_SERVER_URL:-${GITHUB_SERVER_URL:-https://github.com}}"
workspace="${BENCHMARK_WORKSPACE:-${BORINGCACHE_WORKSPACE:-}}"
cache_tag="${BENCHMARK_CACHE_TAG:-${CACHE_SCOPE:-}}"
run_uid="${BENCHMARK_RUN_UID:-}"
paired_run_id="${BENCHMARK_PAIRED_RUN_ID:-}"
mode="${BENCHMARK_MODE:-}"
adapter="${BENCHMARK_ADAPTER:-}"
restore_result="${BENCHMARK_RESTORE_RESULT:-}"
save_result="${BENCHMARK_SAVE_RESULT:-}"
publish_status="${BENCHMARK_PUBLISH_STATUS:-}"
reporting_url="${BENCHMARK_REPORTING_URL:-}"
prior_cache_state="${BENCHMARK_PRIOR_CACHE_STATE:-}"
docker_cache_from_refs="${BENCHMARK_DOCKER_CACHE_FROM_REFS:-${BORINGCACHE_CACHE_USED_FROM_REFS:-}}"
docker_cache_import_ready="${BENCHMARK_DOCKER_CACHE_IMPORT_READY:-${BORINGCACHE_CACHE_IMPORT_READY:-}}"
http_transport="${BENCHMARK_HTTP_TRANSPORT:-}"
http2_enabled="${BENCHMARK_HTTP2_ENABLED:-}"
oci_stream_through_min_bytes="${BENCHMARK_OCI_STREAM_THROUGH_MIN_BYTES:-}"
cache_session_summary_json="${BENCHMARK_CACHE_SESSION_SUMMARY_JSON:-}"
issue_candidates_json="${BENCHMARK_ISSUE_CANDIDATES_JSON:-}"
observability_jsonl="${BENCHMARK_OBSERVABILITY_JSONL:-${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}}"
launch_proof_paths="${BENCHMARK_LAUNCH_PROOF_PATHS:-}"
launch_proof_json="${BENCHMARK_LAUNCH_PROOF_JSON:-}"
cache_import_status=""
output_dir="benchmark-results"
docker_cache_import_seconds=""
docker_cache_export_seconds=""
buildkit_cached_steps="${BENCHMARK_BUILDKIT_CACHED_STEPS:-}"
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
startup_prefetch_duration_ms="${BENCHMARK_STARTUP_PREFETCH_DURATION_MS:-${request_metrics_startup_prefetch_duration_ms:-}}"
startup_prefetch_target_blobs="${BENCHMARK_STARTUP_PREFETCH_TARGET_BLOBS:-${request_metrics_startup_prefetch_target_blobs:-}}"
startup_prefetch_target_bytes="${BENCHMARK_STARTUP_PREFETCH_TARGET_BYTES:-${request_metrics_startup_prefetch_target_bytes:-}}"
startup_prefetch_concurrency="${BENCHMARK_STARTUP_PREFETCH_CONCURRENCY:-${request_metrics_startup_prefetch_concurrency:-}}"
startup_prefetch_initial_concurrency="${BENCHMARK_STARTUP_PREFETCH_INITIAL_CONCURRENCY:-${request_metrics_startup_prefetch_initial_concurrency:-}}"
startup_prefetch_final_concurrency="${BENCHMARK_STARTUP_PREFETCH_FINAL_CONCURRENCY:-${request_metrics_startup_prefetch_final_concurrency:-}}"
startup_prefetch_max_observed_concurrency="${BENCHMARK_STARTUP_PREFETCH_MAX_OBSERVED_CONCURRENCY:-${request_metrics_startup_prefetch_max_observed_concurrency:-}}"
startup_prefetch_concurrency_reason="${BENCHMARK_STARTUP_PREFETCH_CONCURRENCY_REASON:-${request_metrics_startup_prefetch_concurrency_reason:-}}"
startup_prefetch_retries="${BENCHMARK_STARTUP_PREFETCH_RETRIES:-${request_metrics_startup_prefetch_retries:-}}"
startup_prefetch_failures="${BENCHMARK_STARTUP_PREFETCH_FAILURES:-${request_metrics_startup_prefetch_failures:-}}"
oci_new_blob_count=""
oci_new_blob_bytes=""
oci_upload_requested_blobs=""
oci_upload_already_present=""
oci_upload_batch_seconds=""
reseed_new_blob_threshold="${BENCHMARK_RESEED_NEW_BLOB_THRESHOLD:-0}"
tiny_metadata_churn_max_blobs="${BENCHMARK_TINY_METADATA_CHURN_MAX_BLOBS:-1}"
tiny_metadata_churn_max_bytes="${BENCHMARK_TINY_METADATA_CHURN_MAX_BYTES:-65536}"
artifact_surface="${BENCHMARK_ARTIFACT_SURFACE:-benchmark}"

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
    --storage-breakdown-json)
      cache_storage_breakdown_json="$2"
      shift 2
      ;;
    --bytes-uploaded)
      bytes_uploaded="$2"
      shift 2
      ;;
    --network-bytes-uploaded)
      network_bytes_uploaded="$2"
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
    --tool-outcomes-json)
      tool_outcomes_json="$2"
      shift 2
      ;;
    --native-tool-evidence-json)
      native_tool_evidence_json="$2"
      shift 2
      ;;
    --native-tool-stats-file)
      native_tool_stats_file="$2"
      shift 2
      ;;
    --native-tool)
      native_tool_kind="$2"
      shift 2
      ;;
    --sccache-stats-file)
      sccache_stats_file="$2"
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
    --paired-run-id)
      paired_run_id="$2"
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
    --prior-cache-state)
      prior_cache_state="$2"
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
    --issue-candidates-json)
      issue_candidates_json="$2"
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
    --buildkit-cached-steps)
      buildkit_cached_steps="$2"
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
    --startup-prefetch-duration-ms)
      startup_prefetch_duration_ms="$2"
      shift 2
      ;;
    --startup-prefetch-target-blobs)
      startup_prefetch_target_blobs="$2"
      shift 2
      ;;
    --startup-prefetch-target-bytes)
      startup_prefetch_target_bytes="$2"
      shift 2
      ;;
    --startup-prefetch-concurrency)
      startup_prefetch_concurrency="$2"
      shift 2
      ;;
    --startup-prefetch-initial-concurrency)
      startup_prefetch_initial_concurrency="$2"
      shift 2
      ;;
    --startup-prefetch-final-concurrency)
      startup_prefetch_final_concurrency="$2"
      shift 2
      ;;
    --startup-prefetch-max-observed-concurrency)
      startup_prefetch_max_observed_concurrency="$2"
      shift 2
      ;;
    --startup-prefetch-concurrency-reason)
      startup_prefetch_concurrency_reason="$2"
      shift 2
      ;;
    --startup-prefetch-retries)
      startup_prefetch_retries="$2"
      shift 2
      ;;
    --startup-prefetch-failures)
      startup_prefetch_failures="$2"
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
    --artifact-surface)
      artifact_surface="$2"
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

case "$artifact_surface" in
  benchmark|single-phase-proof)
    ;;
  *)
    echo "Unsupported artifact surface: $artifact_surface" >&2
    exit 1
    ;;
esac

single_phase_proof=false
if [[ "$artifact_surface" == "single-phase-proof" ]]; then
  single_phase_proof=true
fi

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

scrub_single_phase_text_payload() {
  jq -c '
    def scrub:
      if type == "object" then
        with_entries(.value |= scrub)
      elif type == "array" then
        map(scrub)
      elif type == "string" then
        gsub("not available in the warmed cache"; "not found in the cache")
        | gsub("warmed cache"; "available cache")
      else
        .
      end;
    scrub
  ' <<< "$1"
}

scrub_single_phase_diagnostic_ids_payload() {
  local current_lane="$1"
  jq -c --arg lane "$current_lane" '
    def hidden($id):
      $id == "partial_cache_reuse" or ($lane == "fresh" and $id == "cache_miss_quality");
    def scrub:
      if type == "object" then
        with_entries(.value |= scrub)
        | if (has("reason_codes") and ((.reason_codes | type) == "array")) then
            .reason_codes |= map(select(hidden(.) | not))
          else
            .
          end
        | if hidden((.primary_bottleneck // "") | tostring) then
            .primary_bottleneck = null
          else
            .
          end
      elif type == "array" then
        map(scrub)
        | map(select((type != "object") or (hidden((.kind // .id // "") | tostring) | not)))
      else
        .
      end;
    scrub
  ' <<< "$2"
}

json_payload_from_optional_file() {
  local label="$1"
  local path="$2"
  if [[ -z "$path" ]]; then
    echo "null"
    return
  fi

  if [[ ! -f "$path" ]]; then
    echo "Missing ${label} JSON: $path" >&2
    exit 1
  fi

  jq -c '.' "$path"
}

sccache_text_stat() {
  local path="$1"
  local label="$2"
  awk -v label="$label" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (substr(line, 1, length(label)) != label) {
        next
      }
      rest = substr(line, length(label) + 1)
      if (rest !~ /^[[:space:]][[:space:]]+/) {
        next
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", rest)
      print rest
      exit
    }
  ' "$path"
}

sccache_uint_stat() {
  local path="$1"
  local label="$2"
  local value
  value="$(sccache_text_stat "$path" "$label" | tr -d ',')"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo ""
  fi
}

sccache_seconds_stat() {
  local path="$1"
  local label="$2"
  local value
  value="$(sccache_text_stat "$path" "$label")"
  value="${value%% s*}"
  value="${value%% sec*}"
  sanitize_number "$value"
}

sccache_reason_counts_payload() {
  local path="$1"
  awk '
    /^Non-cacheable reasons:/ {
      in_reasons = 1
      next
    }
    in_reasons && /^[[:space:]]*$/ {
      exit
    }
    in_reasons {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") {
        next
      }
      value = line
      sub(/^.*[[:space:]][[:space:]]+/, "", value)
      key = line
      sub(/[[:space:]][[:space:]]+[0-9]+$/, "", key)
      if (key != "" && value ~ /^[0-9]+$/) {
        printf "%s\t%s\n", key, value
      }
    }
  ' "$path" | jq -Rnc 'reduce inputs as $line ({}; ($line | split("\t")) as $parts | if ($parts | length) == 2 then . + {($parts[0]): ($parts[1] | tonumber)} else . end)'
}

sccache_native_tool_payload_from_stats() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Missing sccache stats file: $path" >&2
    exit 1
  fi

  local compile_requests compile_requests_executed cache_hits cache_misses
  local hit_c_cpp hit_rust miss_c_cpp miss_rust
  local non_cacheable_calls average_cache_read_hit_seconds average_cache_write_seconds average_compiler_seconds
  local cache_errors cache_read_errors cache_write_errors cache_timeouts
  local non_cacheable_reasons

  compile_requests="$(sccache_uint_stat "$path" "Compile requests")"
  compile_requests_executed="$(sccache_uint_stat "$path" "Compile requests executed")"
  cache_hits="$(sccache_uint_stat "$path" "Cache hits")"
  cache_misses="$(sccache_uint_stat "$path" "Cache misses")"
  hit_c_cpp="$(sccache_uint_stat "$path" "Cache hits (C/C++)")"
  hit_rust="$(sccache_uint_stat "$path" "Cache hits (Rust)")"
  miss_c_cpp="$(sccache_uint_stat "$path" "Cache misses (C/C++)")"
  miss_rust="$(sccache_uint_stat "$path" "Cache misses (Rust)")"
  non_cacheable_calls="$(sccache_uint_stat "$path" "Non-cacheable calls")"
  if [[ -z "$non_cacheable_calls" ]]; then
    non_cacheable_calls="$(sccache_uint_stat "$path" "Non-cacheable compilations")"
  fi
  average_cache_read_hit_seconds="$(sccache_seconds_stat "$path" "Average cache read hit")"
  average_cache_write_seconds="$(sccache_seconds_stat "$path" "Average cache write")"
  average_compiler_seconds="$(sccache_seconds_stat "$path" "Average compiler")"
  cache_errors="$(sccache_uint_stat "$path" "Cache errors")"
  cache_read_errors="$(sccache_uint_stat "$path" "Cache read errors")"
  cache_write_errors="$(sccache_uint_stat "$path" "Cache write errors")"
  cache_timeouts="$(sccache_uint_stat "$path" "Cache timeouts")"
  non_cacheable_reasons="$(sccache_reason_counts_payload "$path")"

  jq -n -c \
    --arg tool "sccache" \
    --arg source "sccache --show-stats" \
    --argjson compile_requests "$(json_num_or_null "$compile_requests")" \
    --argjson compile_requests_executed "$(json_num_or_null "$compile_requests_executed")" \
    --argjson cache_hits "$(json_num_or_null "$cache_hits")" \
    --argjson cache_misses "$(json_num_or_null "$cache_misses")" \
    --argjson hit_c_cpp "$(json_num_or_null "$hit_c_cpp")" \
    --argjson hit_rust "$(json_num_or_null "$hit_rust")" \
    --argjson miss_c_cpp "$(json_num_or_null "$miss_c_cpp")" \
    --argjson miss_rust "$(json_num_or_null "$miss_rust")" \
    --argjson non_cacheable_calls "$(json_num_or_null "$non_cacheable_calls")" \
    --argjson average_cache_read_hit_seconds "$(json_num_or_null "$average_cache_read_hit_seconds")" \
    --argjson average_cache_write_seconds "$(json_num_or_null "$average_cache_write_seconds")" \
    --argjson average_compiler_seconds "$(json_num_or_null "$average_compiler_seconds")" \
    --argjson cache_errors "$(json_num_or_null "$cache_errors")" \
    --argjson cache_read_errors "$(json_num_or_null "$cache_read_errors")" \
    --argjson cache_write_errors "$(json_num_or_null "$cache_write_errors")" \
    --argjson cache_timeouts "$(json_num_or_null "$cache_timeouts")" \
    --argjson non_cacheable_reasons "$non_cacheable_reasons" \
    '
      def compact:
        with_entries(select(.value != null and .value != "" and .value != {}));
      {
        "tool": $tool,
        "schema_version": "native_tool_evidence.v1",
        "stats_source": $source,
        "compile_requests": $compile_requests,
        "compile_requests_executed": $compile_requests_executed,
        "cache_hits": $cache_hits,
        "cache_misses": $cache_misses,
        "hit_rate": (
          if ($cache_hits != null and $cache_misses != null and ($cache_hits + $cache_misses) > 0)
          then ((($cache_hits * 1000) / ($cache_hits + $cache_misses) | round) / 10)
          else null
          end
        ),
        "hit_counts": ({
          "c_cpp": $hit_c_cpp,
          "rust": $hit_rust
        } | compact),
        "miss_counts": ({
          "c_cpp": $miss_c_cpp,
          "rust": $miss_rust
        } | compact),
        "non_cacheable_calls": $non_cacheable_calls,
        "non_cacheable_reasons": $non_cacheable_reasons,
        "average_cache_read_hit_seconds": $average_cache_read_hit_seconds,
        "average_cache_write_seconds": $average_cache_write_seconds,
        "average_compiler_seconds": $average_compiler_seconds,
        "cache_errors": $cache_errors,
        "cache_read_errors": $cache_read_errors,
        "cache_write_errors": $cache_write_errors,
        "cache_timeouts": $cache_timeouts
      } | compact
    '
}

native_tool_payload_from_inputs() {
  if [[ -n "$native_tool_evidence_json" ]]; then
    if [[ ! -f "$native_tool_evidence_json" ]]; then
      echo "Missing native tool evidence JSON: $native_tool_evidence_json" >&2
      exit 1
    fi
    jq -c 'if type == "object" then . else error("native tool evidence must be a JSON object") end' "$native_tool_evidence_json"
    return
  fi

  local stats_path="${native_tool_stats_file:-$sccache_stats_file}"
  local tool="${native_tool_kind:-${adapter:-$mode}}"
  if [[ -n "$stats_path" ]]; then
    case "$tool" in
      sccache|rust-sccache|"")
        sccache_native_tool_payload_from_stats "$stats_path"
        return
        ;;
      *)
        echo "Raw native stats parsing is not implemented for tool: $tool" >&2
        exit 1
        ;;
    esac
  fi

  echo "null"
}

number_from_payload() {
  local payload="$1"
  local query="$2"
  if [[ "$payload" == "null" ]]; then
    echo ""
    return
  fi

  jq -r "def number_or_empty: if type == \"number\" then . elif type == \"string\" then (tonumber? // empty) else empty end; (${query}) | number_or_empty" <<< "$payload"
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

  if [[ -z "$mode" ]]; then
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
      *storybook*|*nx*)
        mode="nx"
        ;;
      *n8n*|*turbo*)
        mode="turbo"
        ;;
      *go*)
        mode="go"
        ;;
    esac
  fi

  if [[ -z "$adapter" ]]; then
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
      nx)
        adapter="nx"
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

  local token="${BORINGCACHE_RESTORE_TOKEN:-${BORINGCACHE_API_TOKEN:-}}"
  local run_identity="${run_uid:-${GITHUB_RUN_ID:-}}"
  local provider_run_identity="${GITHUB_RUN_ID:-}"
  local display_run_identity=""
  if [[ "$run_identity" =~ ^gh-([0-9]+)-[0-9]+$ ]]; then
    display_run_identity="${BASH_REMATCH[1]}"
  fi
  if [[ "$strategy" == "boringcache" && -n "$workspace" && -n "$token" && -n "$run_identity" ]]; then
    local namespace_slug="${workspace%%/*}"
    local workspace_slug="${workspace#*/}"
    if [[ -n "$namespace_slug" && -n "$workspace_slug" && "$namespace_slug" != "$workspace_slug" ]] && command -v curl >/dev/null 2>&1; then
      local api_base="${api_url%/}"
      local sessions_url
      if [[ "$api_base" == */v2 ]]; then
        sessions_url="${api_base}/workspaces/${namespace_slug}/${workspace_slug}/sessions?period=24h&limit=100"
      else
        sessions_url="${api_base}/v2/workspaces/${namespace_slug}/${workspace_slug}/sessions?period=24h&limit=100"
      fi

      local attempt
      for attempt in 1 2 3 4 5 6 7 8; do
        local response
        response="$(curl -fsS -H "Authorization: Bearer ${token}" "$sessions_url" 2>/dev/null || true)"
        if [[ -n "$response" ]]; then
          local summary
          summary="$(
            jq -c \
              --arg run_uid "$run_identity" \
              --arg provider_run_uid "$provider_run_identity" \
              --arg display_run_uid "$display_run_identity" '
              def wanted:
                [$run_uid, $provider_run_uid, $display_run_uid]
                | map(select(length > 0));
              def wanted_run($candidate):
                ($candidate | length) > 0
                and (
                  (wanted | index($candidate))
                  or (($provider_run_uid | length) > 0 and ($candidate | endswith(":" + $provider_run_uid)))
                  or (($display_run_uid | length) > 0 and ($candidate | endswith(":" + $display_run_uid)))
                );
              (.sessions // [])
              | map(select(
                  ((.run_uid // "") as $candidate | wanted_run($candidate))
                  or ((.run_identity.uid // "") as $candidate | wanted_run($candidate))
                  or ((.run_identity.provider_run_uid // "") as $candidate | wanted_run($candidate))
                ))
              | first // empty
            ' <<< "$response" 2>/dev/null || true
          )"
          if [[ -n "$summary" ]]; then
            printf '%s\n' "$summary"
            return
          fi
        fi

        if [[ "$attempt" -lt 8 ]]; then
          sleep 2
        fi
      done
    fi
  fi

  echo "null"
}

issue_candidates_payload_from_inputs() {
  if [[ -n "$issue_candidates_json" ]]; then
    if [[ ! -f "$issue_candidates_json" ]]; then
      echo "Missing issue candidates JSON: $issue_candidates_json" >&2
      exit 1
    fi
    jq -c 'if type == "array" then . elif type == "object" then (.issue_candidates // .candidates // []) else [] end' "$issue_candidates_json"
    return
  fi

  if [[ "$session_summary_payload" != "null" ]]; then
    jq -c '(.classification.issue_candidates // .review.issue_candidates // .issue_candidates // []) | if type == "array" then . else [] end' <<< "$session_summary_payload"
    return
  fi

  echo "[]"
}

cache_read_rollup_payload_from_summary() {
  if [[ "$session_summary_payload" == "null" ]]; then
    echo '{"hits":null,"misses":null,"hit_rate":null}'
    return
  fi

  jq -c '
    def number_or_null:
      if type == "number" then .
      elif type == "string" then (try tonumber catch null)
      else null
      end;
    (((if (.tool | type) == "object" then .tool.cache_read_hit_count else null end) // .metrics.total_hits // .metrics.hit_count // .hit_count // .classification.cache_temperature.hits // .classification.bottleneck.evidence.hits // .cache_read_hit_count) | number_or_null) as $hits |
    (((if (.tool | type) == "object" then .tool.cache_read_miss_count else null end) // .metrics.total_misses // .metrics.miss_count // .miss_count // .classification.cache_temperature.misses // .classification.bottleneck.evidence.misses // .cache_read_miss_count) | number_or_null) as $misses |
    {
      hits: $hits,
      misses: $misses,
      hit_rate: (
        if ($hits != null and $misses != null and ($hits + $misses) > 0)
        then ((($hits * 1000) / ($hits + $misses) | round) / 10)
        else null
        end
      )
    }
  ' <<< "$session_summary_payload"
}

cache_review_payload_from_summary() {
  if [[ "$session_summary_payload" == "null" && "$native_tool_payload" == "null" ]]; then
    echo "null"
    return
  fi

  jq -c --argjson native_tool "$native_tool_payload" '
    def number_or_null:
      if type == "number" then .
      elif type == "string" then (try tonumber catch null)
      else null
      end;
    def array_or_empty:
      if type == "array" then . else [] end;
    def bounded_strings:
      array_or_empty | map(tostring) | .[:8];
    def tool_name($native):
      if (.tool | type) == "string" then .tool
      elif (.tool | type) == "object" then (.tool.tool // .tool.name // .tool.adapter // .adapter // null)
      else (.adapter // $native.tool // null)
      end;
    def cache_target:
      .cache_target // .target // (
        if (.workspace // null) != null or (.tag // null) != null or (.mode // null) != null
        then {workspace: (.workspace // null), tag: (.tag // null), mode: (.mode // null)}
        else null
        end
      );
    def issue_candidates:
      (.classification.issue_candidates // .review.issue_candidates // .issue_candidates // [])
      | array_or_empty
      | map({
          "kind": (.kind // null),
          "owner": (.owner // null),
          "surface": (.surface // null),
          "severity": (.severity // null),
          "confidence": ((.confidence // null) | number_or_null),
          "summary": (.summary // null),
          "suggested_action": (.suggested_action // null)
        })
      | .[:5];
    ($native_tool // {}) as $native |
    (((if (.tool | type) == "object" then .tool.cache_read_hit_count else null end) // .metrics.total_hits // .metrics.hit_count // .hit_count // .classification.cache_temperature.hits // .classification.bottleneck.evidence.hits // .cache_read_hit_count // $native.cache_hits // $native.hit_count) | number_or_null) as $hits |
    (((if (.tool | type) == "object" then .tool.cache_read_miss_count else null end) // .metrics.total_misses // .metrics.miss_count // .miss_count // .classification.cache_temperature.misses // .classification.bottleneck.evidence.misses // .cache_read_miss_count // $native.cache_misses // $native.miss_count) | number_or_null) as $misses |
    ((.metrics.hit_rate // .hit_rate // .classification.cache_temperature.hit_rate // .classification.bottleneck.evidence.hit_rate // $native.hit_rate) | number_or_null) as $reported_hit_rate |
    ((.metrics.duration_seconds // .duration_seconds) | number_or_null) as $duration_seconds |
    ((.duration_ms // null) | number_or_null) as $duration_ms |
    ((.oci.oci_engine_publish_total_duration_ms // .buildkit.export_duration_ms // null) | number_or_null) as $publish_ms |
    ((.startup_prefetch.startup_prefetch_oci_duration_ms // .startup_prefetch.duration_ms // null) | number_or_null) as $startup_ms |
    (($native.non_cacheable_calls // 0) | number_or_null) as $non_cacheable_calls |
    (.review.primary_bottleneck // .classification.primary_bottleneck // .classification.bottleneck.primary_bottleneck // .classification.bottleneck.state // (
      if ($misses != null and $misses > 0) then "cache_miss_quality"
      elif ($non_cacheable_calls != null and $non_cacheable_calls > 0) then "native_tool_work"
      else null
      end
    )) as $primary_bottleneck |
    {
      "schema_version": "benchmark_cache_review.v1",
      "summary_schema": (.summary_schema // .schema // .schema_version // "cache_session_summary.v2"),
      "summary_session_id": (.summary_session_id // .session_id // .identity.summary_session_id // null),
      "tool": tool_name($native),
      "cache_target": cache_target,
      "project_hints": ((.project_hints // []) | array_or_empty),
      "phase_hints": ((.phase_hints // []) | array_or_empty),
      "primary_bottleneck": $primary_bottleneck,
      "diagnostic_classification": (.review.diagnostic.classification // .classification.bottleneck.state // .classification.cache_temperature.state // null),
      "reason_codes": ([
        if ($startup_ms != null and $startup_ms >= 3000) then "setup_overhead" else empty end,
        if ($misses != null and $misses > 0) then "cache_miss_quality" else empty end,
        if ($publish_ms != null and $publish_ms >= 5000) then "save_export" else empty end,
        if ($non_cacheable_calls != null and $non_cacheable_calls > 0) then "native_tool_work" else empty end,
        if (($primary_bottleneck // "") == "cache_side_clear" and (($misses // 0) == 0) and (((.error_count // .classification.cache_temperature.errors // .classification.bottleneck.evidence.errors // 0) | number_or_null) == 0)) then "native_tool_work" else empty end
      ] | unique),
      "native_tool": (if $native == {} then null else $native end),
      "diagnostic_label": (.review.diagnostic.label // null),
      "customer_state": (.review.customer_state // .review.state // null),
      "customer_summary": (.review.customer_summary // .review.summary // null),
      "service_side_issue": (.review.service_side_issue // false),
      "operator_issue": (.review.operator_issue // false),
      "value_outcome": (.review.value_outcome // null),
      "value_owner": (.review.value_owner // null),
      "value_headline": (.review.value_headline // null),
      "value_detail": (.review.value_detail // null),
      "value_next_action": (.review.value_next_action // null),
      "value_evidence": ((.review.value_evidence // []) | bounded_strings),
      "hit_count": $hits,
      "miss_count": $misses,
      "hit_rate": (
        if ($hits != null and $misses != null and ($hits + $misses) > 0)
        then ((($hits * 1000) / ($hits + $misses) | round) / 10)
        else $reported_hit_rate
        end
      ),
      "error_count": ((.metrics.total_errors // .metrics.error_count // (if (.tool | type) == "object" then .tool.error_count else null end) // .error_count // .classification.cache_temperature.errors // .classification.bottleneck.evidence.errors) | number_or_null),
      "bytes_read": ((.metrics.total_bytes_read // .metrics.bytes_read // (if (.tool | type) == "object" then .tool.cache_read_bytes else null end) // .bytes_read // .storage.oci_engine_storage_get_bytes // .storage.bytes // .oci.oci_engine_blob_served_bytes) | number_or_null),
      "bytes_written": ((.metrics.total_bytes_written // .metrics.bytes_written // (if (.tool | type) == "object" then .tool.cache_write_bytes else null end) // .bytes_written // .oci.oci_engine_borrowed_upload_session_bytes) | number_or_null),
      "duration_seconds": ($duration_seconds // (if $duration_ms != null then ($duration_ms / 1000) else null end)),
      "issue_candidates": issue_candidates
    }
  ' <<< "$session_summary_payload"
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
if [[ -n "$network_bytes_uploaded" ]] && ! [[ "$network_bytes_uploaded" =~ ^[0-9]+$ ]]; then
  network_bytes_uploaded=""
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
paired_run_id="$(sanitize_token "$paired_run_id")"
prior_cache_state="$(sanitize_token "$prior_cache_state")"
docker_cache_import_ready="$(sanitize_token "$docker_cache_import_ready")"

if [[ -n "$docker_cache_import_seconds" ]] && ! [[ "$docker_cache_import_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  docker_cache_import_seconds=""
fi
if [[ -n "$docker_cache_export_seconds" ]] && ! [[ "$docker_cache_export_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  docker_cache_export_seconds=""
fi
buildkit_cached_steps="$(sanitize_uint "$buildkit_cached_steps")"
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
startup_prefetch_duration_ms="$(sanitize_uint "$startup_prefetch_duration_ms")"
startup_prefetch_target_blobs="$(sanitize_uint "$startup_prefetch_target_blobs")"
startup_prefetch_target_bytes="$(sanitize_uint "$startup_prefetch_target_bytes")"
startup_prefetch_concurrency="$(sanitize_uint "$startup_prefetch_concurrency")"
startup_prefetch_initial_concurrency="$(sanitize_uint "$startup_prefetch_initial_concurrency")"
startup_prefetch_final_concurrency="$(sanitize_uint "$startup_prefetch_final_concurrency")"
startup_prefetch_max_observed_concurrency="$(sanitize_uint "$startup_prefetch_max_observed_concurrency")"
startup_prefetch_concurrency_reason="$(sanitize_token "$startup_prefetch_concurrency_reason")"
startup_prefetch_retries="$(sanitize_uint "$startup_prefetch_retries")"
startup_prefetch_failures="$(sanitize_uint "$startup_prefetch_failures")"
oci_new_blob_count="$(sanitize_uint "$oci_new_blob_count")"
oci_new_blob_bytes="$(sanitize_uint "$oci_new_blob_bytes")"
oci_upload_requested_blobs="$(sanitize_uint "$oci_upload_requested_blobs")"
oci_upload_already_present="$(sanitize_uint "$oci_upload_already_present")"
oci_upload_batch_seconds="$(sanitize_number "$oci_upload_batch_seconds")"
network_bytes_uploaded_source=""
if [[ -n "$network_bytes_uploaded" ]]; then
  network_bytes_uploaded_source="network_bytes_uploaded_input"
elif [[ -n "$oci_new_blob_bytes" ]]; then
  network_bytes_uploaded="$oci_new_blob_bytes"
  network_bytes_uploaded_source="oci_new_blob_bytes"
fi
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
issue_candidates_payload="$(issue_candidates_payload_from_inputs)"
cache_read_rollup_payload="$(cache_read_rollup_payload_from_summary)"
native_tool_payload="$(native_tool_payload_from_inputs)"
cache_review_payload="$(cache_review_payload_from_summary)"
launch_proof_paths_payload="$(launch_proof_paths_payload_from_inputs)"
storage_breakdown_payload="$(json_payload_from_optional_file "storage breakdown" "$cache_storage_breakdown_json")"
tool_outcomes_payload="$(json_payload_from_optional_file "tool outcomes" "$tool_outcomes_json")"

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

slow_build_seconds="${cold_build_seconds:-$cold_seconds}"
slow_setup_seconds="$cold_setup_seconds"
slow_post_cleanup_seconds="$(number_from_payload "$action_timings_payload" '.phases.seed.archive_save.post_step_non_save_seconds // .seed.archive_save.post_step_non_save_seconds')"
slow_cache_restore_seconds="$docker_cache_import_seconds"
if [[ -z "$slow_cache_restore_seconds" ]]; then
  slow_cache_restore_seconds="$(number_from_payload "$action_timings_payload" '.phases.seed.archive_restore.total_seconds // .seed.archive_restore.total_seconds')"
fi
slow_cache_save_export_seconds="$docker_cache_export_seconds"
if [[ -z "$slow_cache_save_export_seconds" ]]; then
  slow_cache_save_export_seconds="$(number_from_payload "$action_timings_payload" '.phases.seed.archive_save.total_seconds // .seed.archive_save.total_seconds')"
fi
slow_hit_count="$(jq -r '.hits // empty' <<< "$cache_read_rollup_payload")"
slow_miss_count="$(jq -r '.misses // empty' <<< "$cache_read_rollup_payload")"
slow_hit_rate="$(jq -r '.hit_rate // empty' <<< "$cache_read_rollup_payload")"
slow_native_hit_count="$(number_from_payload "$native_tool_payload" '.cache_hits // .hit_count')"
slow_native_miss_count="$(number_from_payload "$native_tool_payload" '.cache_misses // .miss_count')"
slow_native_hit_rate="$(number_from_payload "$native_tool_payload" '.hit_rate')"
slow_native_non_cacheable_calls="$(number_from_payload "$native_tool_payload" '.non_cacheable_calls')"
if [[ -z "$slow_hit_count" ]]; then
  slow_hit_count="$slow_native_hit_count"
fi
if [[ -z "$slow_miss_count" ]]; then
  slow_miss_count="$slow_native_miss_count"
fi
if [[ -z "$slow_hit_rate" ]]; then
  slow_hit_rate="$slow_native_hit_rate"
fi
slow_new_blob_bytes="$oci_new_blob_bytes"
slow_prior_cache_state="$prior_cache_state"
if [[ -z "$slow_prior_cache_state" ]]; then
  if [[ -n "$cache_import_status" && "$cache_import_status" == "ok" ]]; then
    slow_prior_cache_state="usable_import"
  elif [[ -n "$cache_import_status" ]]; then
    slow_prior_cache_state="unusable_import"
  elif [[ "$lane" == "fresh" ]]; then
    slow_prior_cache_state="not_expected"
  else
    slow_prior_cache_state="unknown"
  fi
fi

slow_hypotheses_payload="$(jq -n -c \
  --arg import_status "$cache_import_status" \
  --arg prior_cache_state "$slow_prior_cache_state" \
  --argjson buildkit_cached_steps "$(json_num_or_null "$buildkit_cached_steps")" \
  --argjson build "$(json_num_or_null "$slow_build_seconds")" \
  --argjson setup "$(json_num_or_null "$slow_setup_seconds")" \
  --argjson post_cleanup "$(json_num_or_null "$slow_post_cleanup_seconds")" \
  --argjson cache_restore "$(json_num_or_null "$slow_cache_restore_seconds")" \
  --argjson cache_save_export "$(json_num_or_null "$slow_cache_save_export_seconds")" \
  --argjson miss_count "$(json_num_or_null "$slow_miss_count")" \
  --argjson hit_rate "$(json_num_or_null "$slow_hit_rate")" \
  --argjson non_cacheable_calls "$(json_num_or_null "$slow_native_non_cacheable_calls")" \
  --argjson new_blob_bytes "$(json_num_or_null "$slow_new_blob_bytes")" \
  --argjson issue_candidates "$issue_candidates_payload" \
  '
  def dominates($value; $build):
    $value != null and (($value >= 60) or ($build != null and $build > 0 and (($value / $build) >= 0.25)));
  [
    if ($import_status != "" and $import_status != "ok") then
      {
        "id": "prior_cache_unusable",
        "confidence": "high",
        "summary": "Prior cache import was not usable for this run.",
        "evidence": {"cache_import_status": $import_status, "prior_cache_state": $prior_cache_state}
      }
    else empty end,
    if ($import_status == "ok" and $buildkit_cached_steps == 0) then
      {
        "id": "docker_import_without_reuse",
        "confidence": "high",
        "summary": "BuildKit imported cache metadata but reported zero cached steps.",
        "evidence": {"cache_import_status": $import_status, "buildkit_cached_steps": $buildkit_cached_steps}
      }
    else empty end,
    if dominates($setup; $build) then
      {
        "id": "setup_overhead",
        "confidence": "medium",
        "summary": "Setup or restore overhead is large relative to build time.",
        "evidence": {"setup_seconds": $setup, "build_seconds": $build}
      }
    else empty end,
    if dominates($cache_restore; $build) then
      {
        "id": "cache_restore_overhead",
        "confidence": "medium",
        "summary": "Cache restore/import time is a likely slow-build contributor.",
        "evidence": {"cache_restore_seconds": $cache_restore, "build_seconds": $build}
      }
    else empty end,
    if dominates($cache_save_export; $build) then
      {
        "id": "cache_save_export_overhead",
        "confidence": "high",
        "summary": "Cache save/export time is a likely slow-build contributor.",
        "evidence": {"cache_save_export_seconds": $cache_save_export, "build_seconds": $build}
      }
    else empty end,
    if dominates($post_cleanup; $build) then
      {
        "id": "post_cleanup_overhead",
        "confidence": "medium",
        "summary": "Post-step cleanup outside cache save is a likely slow-build contributor.",
        "evidence": {"post_cleanup_seconds": $post_cleanup, "build_seconds": $build}
      }
    else empty end,
    if ($hit_rate != null and $hit_rate < 80) then
      {
        "id": "partial_cache_reuse",
        "confidence": "medium",
        "summary": "Hit rate is below the benchmark reuse floor.",
        "evidence": {"hit_rate": $hit_rate}
      }
    else empty end,
    if ($miss_count != null and $miss_count > 0) then
      {
        "id": "cache_miss_quality",
        "confidence": (if ($hit_rate != null and $hit_rate >= 90) then "low" else "medium" end),
        "summary": "The native tool still missed cache entries during the measured build.",
        "evidence": {"miss_count": $miss_count, "hit_rate": $hit_rate}
      }
    else empty end,
    if ($non_cacheable_calls != null and $non_cacheable_calls > 0) then
      {
        "id": "native_tool_work",
        "confidence": "medium",
        "summary": "The native tool reported non-cacheable local work.",
        "evidence": {"non_cacheable_calls": $non_cacheable_calls}
      }
    else empty end,
    if ($new_blob_bytes != null and $new_blob_bytes >= 1073741824) then
      {
        "id": "large_cache_update",
        "confidence": "medium",
        "summary": "The run exported more than 1 GiB of new cache blobs.",
        "evidence": {"new_blob_bytes": $new_blob_bytes}
      }
    else empty end,
    if (($issue_candidates | length) > 0) then
      {
        "id": "mcp_issue_candidate_present",
        "confidence": "high",
        "summary": "Review telemetry already emitted at least one issue candidate.",
        "evidence": {"candidate_count": ($issue_candidates | length), "first_kind": ($issue_candidates[0].kind // null)}
      }
    else empty end
  ]')"
if [[ "$single_phase_proof" == "true" ]]; then
  slow_hypotheses_payload="$(scrub_single_phase_diagnostic_ids_payload "$lane" "$slow_hypotheses_payload")"
fi
slow_reason_payload="$(jq -n -c \
  --arg schema "benchmark_slow_reason.v1" \
  --arg benchmark "$benchmark" \
  --arg strategy "$strategy" \
  --arg lane "$lane" \
  --arg run_uid "$run_uid" \
  --arg paired_run_id "$paired_run_id" \
  --arg prior_cache_state "$slow_prior_cache_state" \
  --argjson build "$(json_num_or_null "$slow_build_seconds")" \
  --argjson setup "$(json_num_or_null "$slow_setup_seconds")" \
  --argjson post_cleanup "$(json_num_or_null "$slow_post_cleanup_seconds")" \
  --argjson cache_restore "$(json_num_or_null "$slow_cache_restore_seconds")" \
  --argjson cache_save_export "$(json_num_or_null "$slow_cache_save_export_seconds")" \
  --argjson buildkit_cached_steps "$(json_num_or_null "$buildkit_cached_steps")" \
  --argjson hit_count "$(json_num_or_null "$slow_hit_count")" \
  --argjson miss_count "$(json_num_or_null "$slow_miss_count")" \
  --argjson hit_rate "$(json_num_or_null "$slow_hit_rate")" \
  --argjson new_blob_bytes "$(json_num_or_null "$slow_new_blob_bytes")" \
  --argjson native_tool "$native_tool_payload" \
  --argjson issue_candidates "$issue_candidates_payload" \
  --argjson hypotheses "$slow_hypotheses_payload" \
  '{
    "schema_version": $schema,
    "benchmark": $benchmark,
    "strategy": $strategy,
    "lane": $lane,
    "run_uid": (if $run_uid == "" then null else $run_uid end),
    "paired_run_id": (if $paired_run_id == "" then null else $paired_run_id end),
    "build_seconds": $build,
    "setup_seconds": $setup,
    "post_cleanup_seconds": $post_cleanup,
    "cache_restore_seconds": $cache_restore,
    "cache_save_export_seconds": $cache_save_export,
    "buildkit_cached_steps": $buildkit_cached_steps,
    "hit_count": $hit_count,
    "miss_count": $miss_count,
    "hit_rate": $hit_rate,
    "prior_cache_state": $prior_cache_state,
    "new_blob_bytes": $new_blob_bytes,
    "native_tool": $native_tool,
    "issue_candidates": $issue_candidates,
    "hypotheses": $hypotheses
  }')"
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
      rolling_reseed_kind="rolling_bootstrap_or_cache_evicted"
      reseed_reason="rolling did not find a usable prior cache import (${cache_import_status}); this run populated the rolling cache"
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
elif [[ "$lane" == "rolling" && -n "$cache_import_status" && "$cache_import_status" != "ok" ]]; then
  reporting_mode="investigation_only"
  reporting_reason="rolling_cache_import_not_ok"
  reporting_note="Rolling cache import was unavailable, so this sample populated the rolling cache and is excluded from parity claims."
elif [[ "$strategy" == "boringcache" && "$lane" == "rolling" && "$cache_import_status" == "ok" && "$buildkit_cached_steps" == "0" && ( "$mode" == "docker" || "$adapter" == "oci" ) ]]; then
  rolling_reseed="null"
  steady_state_candidate="false"
  rolling_reseed_kind="rolling_import_no_reuse"
  reporting_mode="investigation_only"
  reporting_reason="rolling_cache_import_no_reuse"
  reporting_note="Rolling cache import completed, but BuildKit reported zero cached steps; this sample behaved like a cold build and is excluded from parity claims."
  reseed_reason="rolling imported prior cache metadata, but BuildKit reported zero cached steps"
fi

lane_label() {
  case "$1" in
    rolling) echo "Rolling" ;;
    *) echo "Fresh" ;;
  esac
}

first_build_label() {
  case "$1" in
    rolling) echo "Commit build" ;;
    *) echo "Cold build" ;;
  esac
}

comparison_header_label() {
  case "$1" in
    rolling) echo "vs Commit build" ;;
    *) echo "vs Cold" ;;
  esac
}

strategy_label() {
  case "$1" in
    actions-cache) echo "GHA" ;;
    boringcache) echo "BC" ;;
    depot-cache) echo "Depot" ;;
    buildbuddy-cache) echo "BuildBuddy" ;;
    *) echo "$1" ;;
  esac
}

mkdir -p "$output_dir"
json_path="$output_dir/${benchmark}-${strategy}-${lane}.json"
md_path="$output_dir/${benchmark}-${strategy}-${lane}.md"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
lane_label_value="$(lane_label "$lane")"
first_build_label_value="$(first_build_label "$lane")"
first_build_detail_label_value="${first_build_label_value% build}"
comparison_header_label_value="$(comparison_header_label "$lane")"
strategy_label_value="$(strategy_label "$strategy")"
session_summary_output_payload="$session_summary_payload"
native_tool_output_payload="$native_tool_payload"
cache_review_output_payload="$cache_review_payload"

if [[ "$single_phase_proof" == "true" ]]; then
  session_summary_output_payload="$(jq -c '
    def compact:
      with_entries(select(.value != null and .value != "" and .value != {}));
    if type != "object" then
      null
    else
      {
        "schema": (.summary_schema // .schema_version // .schema // null),
        "metrics": (.metrics // null),
        "review": (.review // null),
        "classification": (.classification // null),
        "cache_target": (.cache_target // .tag // null)
      } | compact
    end
  ' <<< "$session_summary_payload")"
  native_tool_output_payload="$(jq -c '
    def compact:
      with_entries(select(.value != null and .value != "" and .value != {}));
    if type != "object" then
      null
    else
      {
        "tool": (.tool // null),
        "schema_version": (.schema_version // null),
        "cache_tag": (.cache_tag // null),
        "command": (.command // null),
        "restore": ({
          "classification": (.restore.classification // null)
        } | compact),
        "publish": ({
          "cache_temperature": (.publish.cache_temperature // null),
          "mode": (.publish.mode // null)
        } | compact)
      } | compact
    end
  ' <<< "$native_tool_payload")"
  slow_reason_payload="$(jq -c --argjson native_tool "$native_tool_output_payload" '.native_tool = $native_tool' <<< "$slow_reason_payload")"
  cache_review_output_payload="$(jq -c --argjson native_tool "$native_tool_output_payload" '
    if type != "object" then
      null
    else
      .native_tool = $native_tool
    end
  ' <<< "$cache_review_payload")"
  session_summary_output_payload="$(scrub_single_phase_text_payload "$session_summary_output_payload")"
  native_tool_output_payload="$(scrub_single_phase_text_payload "$native_tool_output_payload")"
  cache_review_output_payload="$(scrub_single_phase_text_payload "$cache_review_output_payload")"
  slow_reason_payload="$(scrub_single_phase_text_payload "$slow_reason_payload")"
  session_summary_output_payload="$(scrub_single_phase_diagnostic_ids_payload "$lane" "$session_summary_output_payload")"
  native_tool_output_payload="$(scrub_single_phase_diagnostic_ids_payload "$lane" "$native_tool_output_payload")"
  cache_review_output_payload="$(scrub_single_phase_diagnostic_ids_payload "$lane" "$cache_review_output_payload")"
  slow_reason_payload="$(scrub_single_phase_diagnostic_ids_payload "$lane" "$slow_reason_payload")"
fi

if [[ "$single_phase_proof" == "true" ]]; then
  runs_payload="$(jq -n -c \
    --arg lane "$lane" \
    --arg label "$first_build_label_value" \
    --argjson measured_seconds "$(json_num_or_null "$cold_seconds")" \
    --argjson measured_build_seconds "$(json_num_or_null "$cold_build_seconds")" \
    --argjson measured_setup_seconds "$(json_num_or_null "$cold_setup_seconds")" \
    '{
      "measured_label": $label,
      "measured_seconds": $measured_seconds,
      "measured_build_seconds": $measured_build_seconds,
      "measured_restore_or_setup_seconds": $measured_setup_seconds,
      "cold_build_seconds": (if $lane == "fresh" then $measured_seconds else null end),
      "commit_build_seconds": (if $lane == "rolling" then $measured_seconds else null end)
    } | with_entries(select(.value != null))')"
  speed_payload="null"
  classification_payload="$(jq -n -c \
    --arg lane "$lane" \
    --arg reporting_mode "$reporting_mode" \
    --arg reporting_reason "$reporting_reason" \
    --arg reporting_note "$reporting_note" \
    --arg validity_reason "$validity_reason" \
    --arg cache_import_status "$cache_import_status" \
    --arg rolling_update_kind "$rolling_reseed_kind" \
    --arg rolling_update_reason "$reseed_reason" \
    --argjson sample_valid "$sample_valid" \
    --argjson steady_state_candidate "$steady_state_candidate" \
    --argjson tiny_metadata_churn "$tiny_metadata_churn" \
    --argjson tiny_metadata_churn_max_blobs "$tiny_metadata_churn_max_blobs" \
    --argjson tiny_metadata_churn_max_bytes "$tiny_metadata_churn_max_bytes" \
    'def blank_to_null: if . == "" then null else . end;
    {
      "sample_valid": $sample_valid,
      "reporting_mode": ($reporting_mode | blank_to_null),
      "reporting_reason": ($reporting_reason | blank_to_null),
      "reporting_note": ($reporting_note | blank_to_null),
      "validity_reason": ($validity_reason | blank_to_null),
      "cache_import_status": ($cache_import_status | blank_to_null)
    }
    + (
      if $lane == "rolling" then
        {
          "rolling_update": {
            "steady_state_candidate": $steady_state_candidate,
            "kind": ($rolling_update_kind | if . == "none" then "continuous_commit_update" else blank_to_null end),
            "tiny_metadata_churn": $tiny_metadata_churn,
            "tiny_metadata_churn_max_blobs": $tiny_metadata_churn_max_blobs,
            "tiny_metadata_churn_max_bytes": $tiny_metadata_churn_max_bytes,
            "reason": ($rolling_update_reason | blank_to_null)
          }
        }
      else
        {}
      end
    )')"
  hit_behavior_payload="$(jq -n -c \
    --arg note "$hit_behavior_note" \
    '{
      "note": (if $note == "" then null else $note end)
    }')"
else
  runs_payload="$(jq -n -c \
    --argjson cold_seconds "$(json_num_or_null "$cold_seconds")" \
    --argjson cold_build_seconds "$(json_num_or_null "$cold_build_seconds")" \
    --argjson cold_setup_seconds "$(json_num_or_null "$cold_setup_seconds")" \
    --argjson warm1_seconds "$(json_num_or_null "$warm1_seconds")" \
    --argjson warm1_build_seconds "$(json_num_or_null "$warm1_build_seconds")" \
    --argjson warm1_setup_seconds "$(json_num_or_null "$warm1_setup_seconds")" \
    --argjson rolling_first_build_seconds "$(json_num_or_null "$rolling_first_build_seconds")" \
    --argjson rolling_warm_seconds "$(json_num_or_null "$rolling_warm_seconds")" \
    '{
      "cold_seconds": $cold_seconds,
      "cold_build_seconds": $cold_build_seconds,
      "cold_restore_or_setup_seconds": $cold_setup_seconds,
      "warm1_seconds": $warm1_seconds,
      "warm1_build_seconds": $warm1_build_seconds,
      "warm1_restore_or_setup_seconds": $warm1_setup_seconds,
      "rolling_first_build_seconds": $rolling_first_build_seconds,
      "rolling_warm_seconds": $rolling_warm_seconds
    }')"
  speed_payload="$(jq -n -c \
    --argjson warm_average_seconds "$warm_avg" \
    --argjson warm_vs_cold_improvement_pct "$warm_improvement_pct" \
    '{
      "warm_average_seconds": $warm_average_seconds,
      "warm_vs_cold_improvement_pct": $warm_vs_cold_improvement_pct
    }')"
  classification_payload="$(jq -n -c \
    --arg reporting_mode "$reporting_mode" \
    --arg reporting_reason "$reporting_reason" \
    --arg reporting_note "$reporting_note" \
    --arg validity_reason "$validity_reason" \
    --arg cache_import_status "$cache_import_status" \
    --arg rolling_reseed_kind "$rolling_reseed_kind" \
    --arg reseed_reason "$reseed_reason" \
    --argjson sample_valid "$sample_valid" \
    --argjson rolling_reseed "$rolling_reseed" \
    --argjson steady_state_candidate "$steady_state_candidate" \
    --argjson tiny_metadata_churn "$tiny_metadata_churn" \
    --argjson tiny_metadata_churn_max_blobs "$tiny_metadata_churn_max_blobs" \
    --argjson tiny_metadata_churn_max_bytes "$tiny_metadata_churn_max_bytes" \
    --argjson reseed_new_blob_threshold "$reseed_new_blob_threshold" \
    'def blank_to_null: if . == "" then null else . end;
    {
      "sample_valid": $sample_valid,
      "reporting_mode": ($reporting_mode | blank_to_null),
      "reporting_reason": ($reporting_reason | blank_to_null),
      "reporting_note": ($reporting_note | blank_to_null),
      "validity_reason": ($validity_reason | blank_to_null),
      "cache_import_status": ($cache_import_status | blank_to_null),
      "rolling_reseed": $rolling_reseed,
      "steady_state_candidate": $steady_state_candidate,
      "rolling_reseed_kind": ($rolling_reseed_kind | blank_to_null),
      "tiny_metadata_churn": $tiny_metadata_churn,
      "tiny_metadata_churn_max_blobs": $tiny_metadata_churn_max_blobs,
      "tiny_metadata_churn_max_bytes": $tiny_metadata_churn_max_bytes,
      "reseed_new_blob_threshold": $reseed_new_blob_threshold,
      "reseed_reason": ($reseed_reason | blank_to_null)
    }')"
  hit_behavior_payload="$(jq -n -c \
    --arg note "$hit_behavior_note" \
    --argjson warm_rerun_succeeded "$warm_rerun_succeeded" \
    '{
      "warm_rerun_succeeded": $warm_rerun_succeeded,
      "note": (if $note == "" then null else $note end)
    }')"
fi

github_run_url=""
if [[ -n "$github_server_url" && -n "$github_repository" && -n "$github_run_id" ]]; then
  github_run_url="${github_server_url%/}/${github_repository}/actions/runs/${github_run_id}"
fi

cat > "$json_path" <<JSON
{
  "benchmark": "$benchmark",
  "strategy": "$strategy",
  "strategy_label": "$strategy_label_value",
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
  "run_context": {
    "github_repository": $(json_string_or_null "$github_repository"),
    "github_workflow": $(json_string_or_null "$github_workflow"),
    "github_job": $(json_string_or_null "$github_job"),
    "github_run_id": $(json_num_or_null "$github_run_id"),
    "github_run_number": $(json_num_or_null "$github_run_number"),
    "github_run_attempt": $(json_num_or_null "$github_run_attempt"),
    "github_run_url": $(json_string_or_null "$github_run_url"),
    "github_ref": $(json_string_or_null "$github_ref"),
    "github_ref_name": $(json_string_or_null "$github_ref_name"),
    "github_sha": $(json_string_or_null "$github_sha")
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
  "session_summary": $session_summary_output_payload,
  "cache_review": $cache_review_output_payload,
  "native_tool": $native_tool_output_payload,
  "reporting_url": $(json_string_or_null "$reporting_url"),
  "launch_proof_paths": $launch_proof_paths_payload,
  "slow_reason": $slow_reason_payload,
  "generated_at": "$generated_at",
  "runs": $runs_payload,
  "speed": $speed_payload,
  "cache": {
    "storage_bytes": $cache_storage_bytes,
    "storage_mib": $cache_storage_mib,
    "storage_source": "$cache_storage_source",
    "storage_note": $(json_string_or_null "$cache_storage_note"),
    "storage_breakdown": $storage_breakdown_payload
  },
  "docker_cache": {
    "import_seconds": $(json_num_or_null "$docker_cache_import_seconds"),
    "export_seconds": $(json_num_or_null "$docker_cache_export_seconds"),
    "cached_steps": $(json_num_or_null "$buildkit_cached_steps")
  },
  "startup_prefetch": {
    "duration_ms": $(json_num_or_null "$startup_prefetch_duration_ms"),
    "target_blobs": $(json_num_or_null "$startup_prefetch_target_blobs"),
    "target_bytes": $(json_num_or_null "$startup_prefetch_target_bytes"),
    "concurrency": $(json_num_or_null "$startup_prefetch_concurrency"),
    "initial_concurrency": $(json_num_or_null "$startup_prefetch_initial_concurrency"),
    "final_concurrency": $(json_num_or_null "$startup_prefetch_final_concurrency"),
    "max_observed_concurrency": $(json_num_or_null "$startup_prefetch_max_observed_concurrency"),
    "concurrency_reason": $(json_string_or_null "$startup_prefetch_concurrency_reason"),
    "retries": $(json_num_or_null "$startup_prefetch_retries"),
    "failures": $(json_num_or_null "$startup_prefetch_failures")
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
  "classification": $classification_payload,
  "action_timings": $action_timings_payload,
  "transfer": {
    "bytes_uploaded": $(json_num_or_null "$network_bytes_uploaded"),
    "network_bytes_uploaded": $(json_num_or_null "$network_bytes_uploaded"),
    "network_bytes_uploaded_source": $(json_string_or_null "$network_bytes_uploaded_source"),
    "bytes_downloaded": $(json_num_or_null "$bytes_downloaded")
  },
  "hit_behavior": $hit_behavior_payload,
  "tool_outcomes": $tool_outcomes_payload
}
JSON

{
  echo "## ${benchmark} (${strategy_label_value}, ${lane_label_value})"
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
  if [[ -n "$github_run_id" ]]; then
    if [[ -n "$github_run_url" ]]; then
      echo "| GitHub run | [${github_run_id}](${github_run_url}) |"
    else
      echo "| GitHub run | ${github_run_id} |"
    fi
  fi
  if [[ -n "$github_run_number" ]]; then
    echo "| GitHub run number | ${github_run_number} |"
  fi
  if [[ -n "$github_run_attempt" ]]; then
    echo "| GitHub run attempt | ${github_run_attempt} |"
  fi
  if [[ -n "$github_job" ]]; then
    echo "| GitHub job | \`${github_job}\` |"
  fi
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
    echo "| ${first_build_detail_label_value} build-only | ${cold_build_seconds}s |"
  fi
  if [[ -n "$cold_setup_seconds" ]]; then
    echo "| ${first_build_detail_label_value} restore/setup | ${cold_setup_seconds}s |"
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
  if [[ -n "$buildkit_cached_steps" ]]; then
    echo "| BuildKit cached steps | ${buildkit_cached_steps} |"
  fi
  echo "| Slow reason build | ${slow_build_seconds}s |"
  if [[ -n "$slow_setup_seconds" ]]; then
    echo "| Slow reason setup | ${slow_setup_seconds}s |"
  fi
  if [[ -n "$slow_cache_restore_seconds" ]]; then
    echo "| Slow reason cache restore | ${slow_cache_restore_seconds}s |"
  fi
  if [[ -n "$slow_cache_save_export_seconds" ]]; then
    echo "| Slow reason cache save/export | ${slow_cache_save_export_seconds}s |"
  fi
  if [[ -n "$slow_post_cleanup_seconds" ]]; then
    echo "| Slow reason post cleanup | ${slow_post_cleanup_seconds}s |"
  fi
  if [[ -n "$slow_hit_rate" ]]; then
    echo "| Slow reason hit rate | ${slow_hit_rate}% |"
  fi
  echo "| Slow reason prior cache | ${slow_prior_cache_state} |"
  if [[ -n "$slow_new_blob_bytes" ]]; then
    echo "| Slow reason new blob bytes | ${slow_new_blob_bytes} |"
  fi
  slow_hypothesis_ids="$(jq -r 'map(.id) | join(", ")' <<< "$slow_hypotheses_payload")"
  if [[ -n "$slow_hypothesis_ids" ]]; then
    echo "| Slow reason hypotheses | ${slow_hypothesis_ids} |"
  fi

  if [[ "$cache_storage_bytes" != "0" ]]; then
    echo "| Cache storage | ${cache_storage_mib} MiB |"
    echo "| Storage source | ${cache_storage_source} |"
    if [[ -n "$cache_storage_note" ]]; then
      echo "| Storage note | ${cache_storage_note} |"
    fi
    if [[ "$storage_breakdown_payload" != "null" ]]; then
      remote_cas_bytes="$(jq -r '.summary.remote_cas_bytes // empty' <<< "$storage_breakdown_payload")"
      dependency_archive_bytes="$(jq -r '.summary.dependency_archive_bytes // empty' <<< "$storage_breakdown_payload")"
      tool_runtime_archive_bytes="$(jq -r '.summary.tool_runtime_archive_bytes // empty' <<< "$storage_breakdown_payload")"
      if [[ -n "$remote_cas_bytes" ]]; then
        remote_cas_mib="$(awk -v bytes="$remote_cas_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
        echo "| Remote CAS storage | ${remote_cas_mib} MiB |"
      fi
      if [[ -n "$dependency_archive_bytes" ]]; then
        dependency_archive_mib="$(awk -v bytes="$dependency_archive_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
        echo "| Dependency archive storage | ${dependency_archive_mib} MiB |"
      fi
      if [[ -n "$tool_runtime_archive_bytes" ]]; then
        tool_runtime_archive_mib="$(awk -v bytes="$tool_runtime_archive_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
        echo "| Tool runtime archive storage | ${tool_runtime_archive_mib} MiB |"
      fi
    fi
  fi

  if [[ "$tool_outcomes_payload" != "null" ]]; then
    gradle_warm_executed="$(jq -r '.gradle.warm1.executed_tasks // empty' <<< "$tool_outcomes_payload")"
    gradle_warm_from_cache="$(jq -r '.gradle.warm1.from_cache_tasks // empty' <<< "$tool_outcomes_payload")"
    gradle_warm_up_to_date="$(jq -r '.gradle.warm1.up_to_date_tasks // empty' <<< "$tool_outcomes_payload")"
    gradle_warnings="$(jq -r '(.warnings // []) | join("; ")' <<< "$tool_outcomes_payload")"
    if [[ -n "$gradle_warm_executed" ]]; then
      echo "| Gradle warm executed tasks | ${gradle_warm_executed} |"
    fi
    if [[ -n "$gradle_warm_from_cache" ]]; then
      echo "| Gradle warm from-cache tasks | ${gradle_warm_from_cache} |"
    fi
    if [[ -n "$gradle_warm_up_to_date" ]]; then
      echo "| Gradle warm up-to-date tasks | ${gradle_warm_up_to_date} |"
    fi
    if [[ -n "$gradle_warnings" ]]; then
      echo "| Tool outcome warnings | ${gradle_warnings} |"
    fi
  fi

  if [[ "$native_tool_payload" != "null" ]]; then
    native_tool_name="$(jq -r '.tool // empty' <<< "$native_tool_payload")"
    native_hit_rate="$(jq -r '.hit_rate // empty' <<< "$native_tool_payload")"
    native_hits="$(jq -r '.cache_hits // .hit_count // empty' <<< "$native_tool_payload")"
    native_misses="$(jq -r '.cache_misses // .miss_count // empty' <<< "$native_tool_payload")"
    native_non_cacheable="$(jq -r '.non_cacheable_calls // empty' <<< "$native_tool_payload")"
    if [[ -n "$native_tool_name" ]]; then
      echo "| Native tool | ${native_tool_name} |"
    fi
    if [[ -n "$native_hit_rate" ]]; then
      echo "| Native hit rate | ${native_hit_rate}% |"
    fi
    if [[ -n "$native_hits" ]]; then
      echo "| Native cache hits | ${native_hits} |"
    fi
    if [[ -n "$native_misses" ]]; then
      echo "| Native cache misses | ${native_misses} |"
    fi
    if [[ -n "$native_non_cacheable" ]]; then
      echo "| Native non-cacheable calls | ${native_non_cacheable} |"
    fi
  fi

  if [[ -n "$docker_cache_import_seconds" ]]; then
    echo "| Docker cache import | ${docker_cache_import_seconds}s |"
  fi
  if [[ -n "$docker_cache_export_seconds" ]]; then
    echo "| Docker cache export | ${docker_cache_export_seconds}s |"
  fi
  if [[ -n "$startup_prefetch_duration_ms" ]]; then
    echo "| Startup prefetch | ${startup_prefetch_duration_ms}ms |"
  fi
  if [[ -n "$startup_prefetch_concurrency" ]]; then
    echo "| Startup prefetch concurrency | ${startup_prefetch_max_observed_concurrency:-?}/${startup_prefetch_concurrency} |"
  fi
  if [[ -n "$startup_prefetch_concurrency_reason" ]]; then
    echo "| Startup prefetch reason | ${startup_prefetch_concurrency_reason} |"
  fi
  if [[ -n "$startup_prefetch_retries" ]]; then
    echo "| Startup prefetch retries | ${startup_prefetch_retries} |"
  fi
  if [[ -n "$startup_prefetch_failures" ]]; then
    echo "| Startup prefetch failures | ${startup_prefetch_failures} |"
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
        rolling_label="cache bootstrap"
      fi
    fi
    echo "| Rolling classification | ${rolling_label} |"
    echo "| Rolling classification reason | ${reseed_reason} |"
  fi
  if [[ -n "$reporting_note" ]]; then
    echo "| Reporting note | ${reporting_note} |"
  fi

  if [[ -n "$network_bytes_uploaded" ]]; then
    echo "| Network bytes uploaded | ${network_bytes_uploaded} |"
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
