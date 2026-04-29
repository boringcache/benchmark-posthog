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
#       reseed classification (rolling_reseed/steady_state_candidate),
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
#     by the aggregator.
#
set -euo pipefail

benchmark=""
strategy=""
lane="fresh"
project_repo=""
project_ref=""
cold_seconds=""
warm1_seconds=""
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
    --warm1-seconds)
      warm1_seconds="$2"
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

if [[ -n "$bytes_uploaded" ]] && ! [[ "$bytes_uploaded" =~ ^[0-9]+$ ]]; then
  bytes_uploaded=""
fi
if [[ -n "$bytes_downloaded" ]] && ! [[ "$bytes_downloaded" =~ ^[0-9]+$ ]]; then
  bytes_downloaded=""
fi
cache_import_status="$(sanitize_token "$cache_import_status")"

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

action_timings_payload="null"
if [[ -n "$action_timings_json" ]]; then
  if [[ ! -f "$action_timings_json" ]]; then
    echo "Missing action timings JSON: $action_timings_json" >&2
    exit 1
  fi
  action_timings_payload="$(jq -c '.' "$action_timings_json")"
fi

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
  if [[ -n "$oci_new_blob_count" ]]; then
    if (( oci_new_blob_count > reseed_new_blob_threshold )); then
      rolling_reseed="true"
      steady_state_candidate="false"
      if [[ "$cache_import_status" == "ok" && -n "$oci_new_blob_bytes" ]] \
        && (( oci_new_blob_count <= tiny_metadata_churn_max_blobs )) \
        && (( oci_new_blob_bytes <= tiny_metadata_churn_max_bytes )); then
        rolling_reseed_kind="tiny_metadata_churn"
        tiny_metadata_churn=true
        blob_word="blobs"
        if (( oci_new_blob_count == 1 )); then
          blob_word="blob"
        fi
        reseed_reason="${oci_new_blob_count} tiny OCI metadata ${blob_word} changed (${oci_new_blob_bytes} bytes)"
      else
        rolling_reseed_kind="blob_reseed"
        reseed_reason="${oci_new_blob_count} new OCI blobs exceeded threshold ${reseed_new_blob_threshold}"
        if [[ -n "$oci_new_blob_bytes" ]]; then
          reseed_reason+=" (${oci_new_blob_bytes} bytes)"
        fi
      fi
    else
      rolling_reseed="false"
      steady_state_candidate="true"
      rolling_reseed_kind="none"
      reseed_reason="new OCI blob count did not exceed threshold ${reseed_new_blob_threshold}"
    fi
  else
    reseed_reason="OCI upload diagnostics unavailable"
  fi
fi

if [[ "$strategy" == "boringcache" && "$lane" == "fresh" && -n "$warm1_seconds" && -n "$cache_import_status" && "$cache_import_status" != "ok" ]]; then
  warm_rerun_succeeded=false
  sample_valid=false
  reporting_mode="invalid"
  reporting_reason="fresh_warm_cache_import_not_ok"
  reporting_note="Fresh BoringCache warm reruns require a usable cache import; treat this run as invalid."
  validity_reason="fresh_warm_cache_import_not_ok"
elif [[ "$strategy" == "boringcache" && "$lane" == "rolling" && "$rolling_reseed" == "true" && "$rolling_reseed_kind" == "tiny_metadata_churn" ]]; then
  reporting_mode="investigation_only"
  reporting_reason="rolling_metadata_churn"
  reporting_note="Rolling Docker uploaded only tiny OCI metadata after a successful import; keep it separate from blob reseeds and do not treat it as steady-state parity."
elif [[ "$strategy" == "boringcache" && "$lane" == "rolling" && "$rolling_reseed" == "true" ]]; then
  reporting_mode="investigation_only"
  reporting_reason="rolling_reseed"
  reporting_note="Rolling Docker reseeds are first-build investigation samples, not steady-state parity."
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
  "generated_at": "$generated_at",
  "runs": {
    "cold_seconds": $(json_num_or_null "$cold_seconds"),
    "warm1_seconds": $(json_num_or_null "$warm1_seconds")
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
    rolling_label="steady-state candidate"
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
