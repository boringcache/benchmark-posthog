#!/usr/bin/env bash
set -euo pipefail

# Measures GitHub Actions cache storage for a benchmark project.
#
# For non-Docker benchmarks (e.g., zed-sccache or grpc-bazel), sums entries matching the key prefix.
# For Docker benchmarks, buildkit blobs are SHA-keyed and shared across all Docker
# projects in the repo — they CANNOT be attributed per-project. Instead, we report
# the total repo cache usage from the API (honest, verifiable).
#
# Usage:
#   sum-gha-cache-by-key.sh <prefix> [window_started_at] [window_ended_at]
#
# When prefix starts with "index-" or matches a Docker benchmark ID, the script
# fetches total repo cache usage. Otherwise it sums matching key entries.

benchmark_or_prefix="${1:-}"
window_started_at="${2:-}"
window_ended_at="${3:-}"
repo="${GITHUB_REPOSITORY:-}"

if [[ -z "$benchmark_or_prefix" || -z "$repo" ]]; then
  echo "0"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "0"
  exit 0
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "0"
  exit 0
fi

# Determine whether this benchmark uses Docker buildkit cache.
# Docker benchmarks have buildkit-blob-* entries that are shared and unattributable.
is_docker_benchmark() {
  local prefix="$1"
  # Docker benchmark IDs: posthog, mastodon-docker, hugo, immich
  # Non-docker: zed-sccache, grpc-bazel, etc.
  case "$prefix" in
    index-posthog*|posthog*) return 0 ;;
    index-mastodon*|mastodon*) return 0 ;;
    index-hugo*|hugo*) return 0 ;;
    index-immich*|immich*) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ "$benchmark_or_prefix" == index-* ]]; then
  index_prefix="$benchmark_or_prefix"
else
  index_prefix="index-${benchmark_or_prefix}"
fi

if [[ -z "$window_ended_at" ]]; then
  window_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# For Docker benchmarks: report total repo cache usage.
# This is the only honest number — buildkit blobs can't be split per project.
if is_docker_benchmark "$benchmark_or_prefix"; then
  repo_total="$(gh api "/repos/${repo}/actions/cache/usage" --jq '.active_caches_size_in_bytes' 2>/dev/null || echo "0")"
  if [[ -n "$repo_total" && "$repo_total" =~ ^[0-9]+$ ]]; then
    echo "$repo_total"
  else
    echo "0"
  fi
  exit 0
fi

# For non-Docker benchmarks: sum entries matching the key prefix (attributable).
sum_for_query() {
  local key_filter="$1"
  local jq_filter="$2"

  local total=0
  local page=1
  local key_encoded
  key_encoded="$(jq -nr --arg v "$key_filter" '$v|@uri')"

  while true; do
    local response
    response="$(gh api "/repos/${repo}/actions/caches?per_page=100&page=${page}&key=${key_encoded}" 2>/dev/null || true)"
    if [[ -z "$response" ]]; then
      break
    fi
    if ! jq -e '.actions_caches | type == "array"' <<<"$response" >/dev/null 2>&1; then
      break
    fi

    local page_sum
    page_sum="$(
      jq -r \
        --arg since "${window_started_at}" \
        --arg until "${window_ended_at}" \
        "$jq_filter" <<<"$response"
    )"

    if [[ -n "$page_sum" && "$page_sum" =~ ^[0-9]+$ ]]; then
      total=$((total + page_sum))
    fi

    local count
    count="$(jq '.actions_caches | length' <<<"$response")"
    if [[ "$count" -lt 100 ]]; then
      break
    fi
    page=$((page + 1))
  done

  echo "$total"
}

timestamp_filter='
  def parse_ts($v):
    if ($v // "") == "" then 0
    else (($v | sub("\\.[0-9]+Z$"; "Z")) | fromdateiso8601)
    end;
  def in_window($ts):
    if ($since // "") == "" then true
    else (parse_ts($ts) >= parse_ts($since))
    end and (parse_ts($ts) <= parse_ts($until));
'

# Sum entries matching the benchmark key prefix (e.g., zed-sccache-*)
prefix_sum="$(
  sum_for_query \
    "${benchmark_or_prefix}" \
    "${timestamp_filter}
    [
      .actions_caches[]
      | select(in_window(.last_accessed_at))
      | .size_in_bytes
    ] | add // 0
    "
)"

if [[ ! "$prefix_sum" =~ ^[0-9]+$ ]]; then
  prefix_sum=0
fi

echo "$prefix_sum"
