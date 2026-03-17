#!/usr/bin/env bash
set -euo pipefail

benchmark=""
strategy=""
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

if [[ -n "$bytes_uploaded" ]] && ! [[ "$bytes_uploaded" =~ ^[0-9]+$ ]]; then
  bytes_uploaded=""
fi
if [[ -n "$bytes_downloaded" ]] && ! [[ "$bytes_downloaded" =~ ^[0-9]+$ ]]; then
  bytes_downloaded=""
fi
if [[ -n "$layer_miss_seconds" ]] && ! [[ "$layer_miss_seconds" =~ ^[0-9]+$ ]]; then
  layer_miss_seconds=""
fi
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

mkdir -p "$output_dir"
json_path="$output_dir/${benchmark}-${strategy}.json"
md_path="$output_dir/${benchmark}-${strategy}.md"
generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$json_path" <<JSON
{
  "benchmark": "$benchmark",
  "strategy": "$strategy",
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
  "transfer": {
    "bytes_uploaded": $(json_num_or_null "$bytes_uploaded"),
    "bytes_downloaded": $(json_num_or_null "$bytes_downloaded")
  },
  "hit_behavior": {
    "two_consecutive_warm_runs_succeeded": $([[ -n "$warm1_seconds" && -n "$warm2_seconds" ]] && echo true || echo false),
    "note": "$hit_behavior_note"
  }
}
JSON

{
  echo "## ${benchmark} (${strategy})"
  echo ""
  echo "| Phase | Time | vs Cold |"
  echo "|-------|------|---------|"
  echo "| Cold (no cache) | ${cold_seconds}s | — |"

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
  echo "| Project | \`${project_repo}\` |"
  echo "| Commit | \`${project_ref}\` |"

  if [[ "$warm_avg" != "null" ]]; then
    echo "| Warm avg | ${warm_avg}s (${warm_improvement_pct}% faster) |"
  fi

  if [[ "$cache_storage_bytes" != "0" ]]; then
    echo "| Cache storage | ${cache_storage_mib} MiB |"
    echo "| Storage source | ${cache_storage_source} |"
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
