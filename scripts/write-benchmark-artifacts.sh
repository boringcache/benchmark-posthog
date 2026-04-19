#!/usr/bin/env bash
set -euo pipefail

benchmark=""
strategy=""
lane="fresh"
project_repo=""
project_ref=""
cold_seconds=""
warm1_seconds=""
warm2_seconds=""
cache_storage_bytes="0"
cache_storage_source=""
bytes_uploaded=""
bytes_downloaded=""
hit_behavior_note=""
layer_miss_seconds=""
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
stale_seconds=""
stale_seconds_explicit="0"
stale_low_seconds=""
stale_mid_seconds=""
stale_high_seconds=""
output_dir="benchmark-results"

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
    --warm2-seconds)
      warm2_seconds="$2"
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
    --layer-miss-seconds|--internal-only-warm-seconds)
      layer_miss_seconds="$2"
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
    --stale-seconds|--stale-docker-seconds)
      stale_seconds="$2"
      stale_seconds_explicit="1"
      shift 2
      ;;
    --stale-low-seconds)
      stale_low_seconds="$2"
      shift 2
      ;;
    --stale-mid-seconds)
      stale_mid_seconds="$2"
      shift 2
      ;;
    --stale-high-seconds)
      stale_high_seconds="$2"
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

if [[ -n "$bytes_uploaded" ]] && ! [[ "$bytes_uploaded" =~ ^[0-9]+$ ]]; then
  bytes_uploaded=""
fi
if [[ -n "$bytes_downloaded" ]] && ! [[ "$bytes_downloaded" =~ ^[0-9]+$ ]]; then
  bytes_downloaded=""
fi
if [[ -n "$layer_miss_seconds" ]] && ! [[ "$layer_miss_seconds" =~ ^[0-9]+$ ]]; then
  layer_miss_seconds=""
fi
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
if [[ -n "$stale_seconds" ]] && ! [[ "$stale_seconds" =~ ^[0-9]+$ ]]; then
  stale_seconds=""
fi
if [[ -n "$stale_low_seconds" ]] && ! [[ "$stale_low_seconds" =~ ^[0-9]+$ ]]; then
  stale_low_seconds=""
fi
if [[ -n "$stale_mid_seconds" ]] && ! [[ "$stale_mid_seconds" =~ ^[0-9]+$ ]]; then
  stale_mid_seconds=""
fi
if [[ -n "$stale_high_seconds" ]] && ! [[ "$stale_high_seconds" =~ ^[0-9]+$ ]]; then
  stale_high_seconds=""
fi

if [[ -z "$stale_seconds" ]]; then
  if [[ -n "$stale_mid_seconds" ]]; then
    stale_seconds="$stale_mid_seconds"
  elif [[ -n "$stale_low_seconds" ]]; then
    stale_seconds="$stale_low_seconds"
  elif [[ -n "$stale_high_seconds" ]]; then
    stale_seconds="$stale_high_seconds"
  fi
fi

warm_count=0
warm_total=0
if [[ -n "$warm1_seconds" ]]; then
  warm_count=$((warm_count + 1))
  warm_total=$((warm_total + warm1_seconds))
fi
if [[ -n "$warm2_seconds" ]]; then
  warm_count=$((warm_count + 1))
  warm_total=$((warm_total + warm2_seconds))
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

if [[ -n "$layer_miss_seconds" ]]; then
  layer_miss_improvement_pct=$(pct_vs_cold "$layer_miss_seconds")
else
  layer_miss_improvement_pct="null"
fi

if [[ -n "$stale_seconds" ]]; then
  stale_improvement_pct=$(pct_vs_cold "$stale_seconds")
else
  stale_improvement_pct="null"
fi

if [[ -n "$stale_low_seconds" ]]; then
  stale_low_improvement_pct=$(pct_vs_cold "$stale_low_seconds")
else
  stale_low_improvement_pct="null"
fi
if [[ -n "$stale_mid_seconds" ]]; then
  stale_mid_improvement_pct=$(pct_vs_cold "$stale_mid_seconds")
else
  stale_mid_improvement_pct="null"
fi
if [[ -n "$stale_high_seconds" ]]; then
  stale_high_improvement_pct=$(pct_vs_cold "$stale_high_seconds")
else
  stale_high_improvement_pct="null"
fi

cache_storage_mib=$(awk -v bytes="$cache_storage_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')

rolling_reseed="null"
steady_state_candidate="null"
reseed_reason=""
if [[ "$lane" == "rolling" && "$strategy" == "boringcache" ]]; then
  if [[ -n "$oci_new_blob_count" ]]; then
    if (( oci_new_blob_count > reseed_new_blob_threshold )); then
      rolling_reseed="true"
      steady_state_candidate="false"
      reseed_reason="${oci_new_blob_count} new OCI blobs exceeded threshold ${reseed_new_blob_threshold}"
      if [[ -n "$oci_new_blob_bytes" ]]; then
        reseed_reason+=" (${oci_new_blob_bytes} bytes)"
      fi
    else
      rolling_reseed="false"
      steady_state_candidate="true"
      reseed_reason="new OCI blob count did not exceed threshold ${reseed_new_blob_threshold}"
    fi
  else
    reseed_reason="OCI upload diagnostics unavailable"
  fi
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
  "generated_at": "$generated_at",
  "runs": {
    "cold_seconds": $(json_num_or_null "$cold_seconds"),
    "warm1_seconds": $(json_num_or_null "$warm1_seconds"),
    "warm2_seconds": $(json_num_or_null "$warm2_seconds"),
    "stale_seconds": $(json_num_or_null "$stale_seconds"),
    "stale_low_seconds": $(json_num_or_null "$stale_low_seconds"),
    "stale_mid_seconds": $(json_num_or_null "$stale_mid_seconds"),
    "stale_high_seconds": $(json_num_or_null "$stale_high_seconds"),
    "layer_miss_seconds": $(json_num_or_null "$layer_miss_seconds")
  },
  "speed": {
    "warm_average_seconds": $warm_avg,
    "warm_vs_cold_improvement_pct": $warm_improvement_pct
  },
  "stale": {
    "seconds": $(json_num_or_null "$stale_seconds"),
    "vs_cold_improvement_pct": $stale_improvement_pct,
    "low_seconds": $(json_num_or_null "$stale_low_seconds"),
    "low_vs_cold_improvement_pct": $stale_low_improvement_pct,
    "mid_seconds": $(json_num_or_null "$stale_mid_seconds"),
    "mid_vs_cold_improvement_pct": $stale_mid_improvement_pct,
    "high_seconds": $(json_num_or_null "$stale_high_seconds"),
    "high_vs_cold_improvement_pct": $stale_high_improvement_pct
  },
  "layer_miss": {
    "seconds": $(json_num_or_null "$layer_miss_seconds"),
    "vs_cold_improvement_pct": $layer_miss_improvement_pct
  },
  "cache": {
    "storage_bytes": $cache_storage_bytes,
    "storage_mib": $cache_storage_mib,
    "storage_source": "$cache_storage_source"
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
    "rolling_reseed": $rolling_reseed,
    "steady_state_candidate": $steady_state_candidate,
    "reseed_new_blob_threshold": $reseed_new_blob_threshold,
    "reseed_reason": $(json_string_or_null "$reseed_reason")
  },
  "transfer": {
    "bytes_uploaded": $(json_num_or_null "$bytes_uploaded"),
    "bytes_downloaded": $(json_num_or_null "$bytes_downloaded")
  },
  "hit_behavior": {
    "two_consecutive_warm_runs_succeeded": $([[ -n "$warm1_seconds" && -n "$warm2_seconds" ]] && echo true || echo false),
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
  if [[ -n "$warm2_seconds" ]]; then
    echo "| Warm #2 | ${warm2_seconds}s | -$(pct_vs_cold "$warm2_seconds")% |"
  fi
  if [[ -n "$stale_seconds" && "$stale_seconds_explicit" == "1" ]]; then
    echo "| Stale (code changed) | ${stale_seconds}s | -${stale_improvement_pct}% |"
  fi
  if [[ -n "$stale_low_seconds" ]]; then
    echo "| Stale — low | ${stale_low_seconds}s | -${stale_low_improvement_pct}% |"
  fi
  if [[ -n "$stale_mid_seconds" ]]; then
    echo "| Stale — mid | ${stale_mid_seconds}s | -${stale_mid_improvement_pct}% |"
  fi
  if [[ -n "$stale_high_seconds" ]]; then
    echo "| Stale — high | ${stale_high_seconds}s | -${stale_high_improvement_pct}% |"
  fi
  if [[ -n "$layer_miss_seconds" ]]; then
    echo "| Layer miss (no layer cache) | ${layer_miss_seconds}s | -${layer_miss_improvement_pct}% |"
  fi

  echo ""
  echo "| Metric | Value |"
  echo "|--------|-------|"
  echo "| Lane | ${lane_label_value} |"
  echo "| Project | \`${project_repo}\` |"
  echo "| Commit | \`${project_ref}\` |"

  if [[ "$warm_avg" != "null" ]]; then
    echo "| Warm avg | ${warm_avg}s (${warm_improvement_pct}% faster) |"
  fi

  if [[ "$cache_storage_bytes" != "0" ]]; then
    echo "| Cache storage | ${cache_storage_mib} MiB |"
    echo "| Storage source | ${cache_storage_source} |"
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
    echo "| Rolling classification | $([[ "$rolling_reseed" == "true" ]] && echo "reseed" || echo "steady-state candidate") |"
    echo "| Rolling classification reason | ${reseed_reason} |"
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

  echo "| Two warm runs | $([[ -n "$warm1_seconds" && -n "$warm2_seconds" ]] && echo "yes" || echo "no") |"
} > "$md_path"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "json_path=$json_path" >> "$GITHUB_OUTPUT"
  echo "md_path=$md_path" >> "$GITHUB_OUTPUT"
fi
