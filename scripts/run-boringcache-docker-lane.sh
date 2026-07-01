#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
mode="${1:-full}"
backend="${BUILDKIT_BACKEND:-registry}"
phase_start="${BENCHMARK_PHASE_STARTED_AT:-$(date +%s)}"
metrics_file="${BENCHMARK_METRICS_OUTPUT:-${RUNNER_TEMP:-/tmp}/rolling-build-metrics.env}"
diagnostics_file="${BENCHMARK_DIAGNOSTICS_OUTPUT:-benchmark-diagnostics/${BENCHMARK_ID:-posthog}-boringcache-rolling-commit.txt}"
outputs_file="${BENCHMARK_OUTPUTS_PATH:-benchmark-results/${BENCHMARK_ID:-posthog}-boringcache-rolling.outputs.env}"
observability_path="${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-${RUNNER_TEMP:-/tmp}/${BENCHMARK_ID:-posthog}-boringcache-commit-observability.jsonl}"

mkdir -p "$(dirname "$diagnostics_file")" "$(dirname "$outputs_file")"
rm -f "$metrics_file" "$diagnostics_file" "$outputs_file"
export BORINGCACHE_OBSERVABILITY_JSONL_PATH="$observability_path"

emit_output() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$value" >> "$outputs_file"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

append_outputs_file() {
  local path="$1"
  [[ -s "$path" ]] || return 0
  cat "$path" >> "$outputs_file"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    cat "$path" >> "$GITHUB_OUTPUT"
  fi
}

if [[ "$backend" != "native" ]]; then
  if [[ "${BORINGCACHE_CACHE_IMPORT_READY:-}" != "true" || ( -z "${CACHE_FROM:-}" && -z "${BORINGCACHE_CACHE_USED_FROM_REFS:-}" ) ]]; then
    echo "Rolling BoringCache Docker import was not ready; continuing as a bootstrap/update sample." >&2
    echo "import ready: ${BORINGCACHE_CACHE_IMPORT_READY:-}" >&2
    echo "requested refs: ${BORINGCACHE_CACHE_REQUESTED_FROM_REFS:-}" >&2
    echo "used refs: ${BORINGCACHE_CACHE_USED_FROM_REFS:-}" >&2
    echo "unreadable refs: ${BORINGCACHE_CACHE_UNREADABLE_FROM_REFS:-}" >&2
  fi
fi

start="$(date +%s)"
set +e
BENCHMARK_METRICS_OUTPUT="$metrics_file" BENCHMARK_DIAGNOSTICS_OUTPUT="$diagnostics_file" \
  "$repo_root/scripts/run-boringcache-buildkit-benchmark.sh" "$mode"
status="$?"
set -e
end="$(date +%s)"

if [[ -s "$diagnostics_file" ]]; then
  {
    echo "seed_phase_started_at=${phase_start}"
    echo "seed_build_started_at=${start}"
    echo "seed_build_finished_at=${end}"
    echo "seed_phase_wall_seconds=$((end - phase_start))"
    echo "seed_build_wall_seconds=$((end - start))"
  } >> "$diagnostics_file"
fi

if [[ -s "$observability_path" ]]; then
  observability_artifact="benchmark-diagnostics/${BENCHMARK_ID:-posthog}-boringcache-rolling-commit-observability.jsonl"
  cp "$observability_path" "$observability_artifact"
  mkdir -p benchmark-session-summary
  jq -c 'select(.operation == "cache_session_summary") | .summary // .details // .' "$observability_path" 2>/dev/null | tail -n 1 > benchmark-session-summary/benchmark-session-summary.json || true
  if [[ ! -s benchmark-session-summary/benchmark-session-summary.json ]]; then
    rm -f benchmark-session-summary/benchmark-session-summary.json
  fi
fi

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

emit_output seconds "$((end - phase_start))"
emit_output build_seconds "$((end - start))"
append_outputs_file "$metrics_file"
