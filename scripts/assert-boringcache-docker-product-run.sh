#!/usr/bin/env bash
#
# Runtime contract for a managed BoringCache Docker benchmark.
#
# BuildKit vertex spans are harvested from the managed daemon after the wrapped
# command exits. Their presence therefore proves that the benchmark crossed the
# CLI-owned `boringcache docker --backend boringcache -- ...` lifecycle instead
# of combining setup-only cache wiring with a raw Docker command.
#
set -euo pipefail

observability_path="${1:-${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}}"

fail() {
  echo "Managed Docker product-path contract failed: $1" >&2
  if [[ -n "${2:-}" ]]; then
    echo "$2" >&2
  fi
  exit 1
}

product_path_hint="Run the build through 'boringcache docker --backend boringcache -- ...'; setup-only plus raw Docker is not the managed product path."

[[ -n "$observability_path" ]] || fail "pass the observability JSONL path or set BORINGCACHE_OBSERVABILITY_JSONL_PATH"
[[ -s "$observability_path" ]] || fail "missing observability JSONL at ${observability_path}"
command -v jq >/dev/null 2>&1 || fail "jq is required to verify managed run evidence"

summary_limit_bytes=65536
summary_bytes=""
evidence=""
result="$(jq -sr '
  ([.[] | select(.operation == "cache_session_summary")] | last) as $record
  | ($record.summary // $record.details // $record) as $summary
  | ($summary.buildkit.vertex_spans // null) as $spans
  | select($spans.schema_version == "buildkit_vertex_spans.v1")
  | ($spans.total_spans | numbers) as $total
  | ($spans.executed_count | numbers) as $executed
  | ($spans.cached_count | numbers) as $cached
  | ($spans.error_count | numbers) as $errors
  | select($total > 0 and ($executed + $cached + $errors) > 0)
  | "\($summary | tojson | utf8bytelength)\tvertex_spans total=\($total) executed=\($executed) cached=\($cached) errors=\($errors)"
' "$observability_path")" || fail "invalid observability JSONL at ${observability_path}"
IFS=$'\t' read -r summary_bytes evidence <<< "$result"

[[ -n "$evidence" ]] || fail "cache_session_summary is missing buildkit.vertex_spans evidence" "$product_path_hint"
[[ "$summary_bytes" =~ ^[0-9]+$ ]] || fail "cache_session_summary size could not be measured"
(( summary_bytes <= summary_limit_bytes )) || fail \
  "run summary is ${summary_bytes} bytes; the BoringCache ingestion limit is ${summary_limit_bytes} bytes" \
  "Use a current BoringCache CLI; older clients can emit managed-build telemetry that exceeds this contract."
echo "Managed Docker product path verified: ${evidence} summary_bytes=${summary_bytes}"
