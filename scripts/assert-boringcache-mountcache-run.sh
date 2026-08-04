#!/usr/bin/env bash
#
# Evidence contract for a benchmark lane that promises to exercise managed
# BuildKit cache-mount offload. Configuration alone is not coverage: a fully
# cached OCI graph can finish without touching a cache mount.
#
set -euo pipefail

observability_path="${1:-${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}}"

fail() {
  echo "Managed mountcache evidence contract failed: $1" >&2
  exit 1
}

[[ -n "$observability_path" ]] || fail "pass the observability JSONL path or set BORINGCACHE_OBSERVABILITY_JSONL_PATH"
[[ -s "$observability_path" ]] || fail "missing observability JSONL at ${observability_path}"
command -v jq >/dev/null 2>&1 || fail "jq is required to verify mountcache evidence"

mountcache="$(jq -sc '
  ([.[] | select(.operation == "cache_session_summary")] | last) as $record
  | ($record.summary // $record.details // $record) as $summary
  | $summary.buildkit.mountcache // null
' "$observability_path")" || fail "invalid observability JSONL at ${observability_path}"

[[ "$mountcache" != "null" ]] || fail "cache_session_summary is missing buildkit.mountcache evidence"
[[ "$(jq -r '.schema_version // empty' <<< "$mountcache")" == "buildkit_mountcache.v1" ]] ||
  fail "buildkit.mountcache has an unsupported or missing schema_version"
[[ "$(jq -r '.configured // false' <<< "$mountcache")" == "true" ]] ||
  fail "mountcache was not configured"

metric() {
  local name="$1"
  jq -er --arg name "$name" '
    .[$name]
    | select(type == "number" and . >= 0 and floor == .)
  ' <<< "$mountcache"
}

require_metric() {
  local name="$1"
  local value=""
  value="$(metric "$name")" || fail "buildkit.mountcache.${name} is missing or invalid"
  printf '%s\n' "$value"
}

plans="$(require_metric plans)"
hydrate_requests="$(require_metric hydrate_requests)"
hydrate_hits="$(require_metric hydrate_hits)"
hydrate_misses="$(require_metric hydrate_misses)"
hydrate_miss_all="$(require_metric hydrate_miss_all)"
hydrate_skips="$(require_metric hydrate_skips)"
hydrate_errors="$(require_metric hydrate_errors)"
write_tracking_complete="$(require_metric write_tracking_complete)"
write_tracking_unreliable="$(require_metric write_tracking_unreliable)"
publish_marks="$(require_metric publish_marks)"
publish_skips="$(require_metric publish_skips)"
publish_done="$(require_metric publish_done)"
publish_errors="$(require_metric publish_errors)"

(( plans > 0 )) || fail "no mountcache plans were recorded; a hot OCI graph does not prove mountcache behavior"
(( hydrate_requests > 0 || hydrate_skips > 0 )) ||
  fail "no mountcache hydrate request or explicit hydrate skip was recorded"
(( hydrate_errors == 0 )) || fail "mountcache hydration recorded ${hydrate_errors} error(s)"
(( hydrate_hits + hydrate_misses == hydrate_requests )) ||
  fail "mountcache hydrate attempts do not reconcile with hit/miss outcomes"
(( hydrate_hits + hydrate_miss_all + hydrate_skips == plans )) ||
  fail "mountcache plans do not reconcile with terminal hydrate outcomes"

permitted_hydrate_skips="$(jq -r '
  [(.samples // [])[]
    | select(.event == "mountcache_hydrate_skip" and .reason == "non_empty")]
  | length
' <<< "$mountcache")"
(( hydrate_skips == permitted_hydrate_skips )) ||
  fail "mountcache hydrate skips are missing the explicit permitted non_empty reason"

(( write_tracking_complete >= plans )) ||
  fail "completed mountcache write-tracking observations do not cover every plan"
(( write_tracking_unreliable == 0 )) ||
  fail "mountcache write tracking was unreliable for ${write_tracking_unreliable} observation(s)"
(( publish_errors == 0 )) || fail "mountcache publish recorded ${publish_errors} error(s)"

publish_skip_reasons="$(jq -c '.publish_skip_reason_counts // {}' <<< "$mountcache")"
[[ "$(jq -r 'type' <<< "$publish_skip_reasons")" == "object" ]] ||
  fail "buildkit.mountcache.publish_skip_reason_counts is invalid"

unknown_publish_skips="$(jq -r '
  to_entries
  | map(select(.value > 0 and (.key != "no_writes" and .key != "empty")))
  | map(.key)
  | join(",")
' <<< "$publish_skip_reasons")"
[[ -z "$unknown_publish_skips" ]] ||
  fail "mountcache publish used unpermitted skip reason(s): ${unknown_publish_skips}"

no_write_publish_skips="$(jq -r '.no_writes // 0' <<< "$publish_skip_reasons")"
empty_publish_skips="$(jq -r '.empty // 0' <<< "$publish_skip_reasons")"
[[ "$no_write_publish_skips" =~ ^[0-9]+$ && "$empty_publish_skips" =~ ^[0-9]+$ ]] ||
  fail "mountcache permitted publish skip counts are invalid"
permitted_publish_skips=$((no_write_publish_skips + empty_publish_skips))
(( publish_skips == permitted_publish_skips )) ||
  fail "mountcache publish skips are missing explicit permitted reasons"
(( publish_done + publish_skips == plans )) ||
  fail "mountcache plans do not reconcile with terminal publish outcomes"
(( publish_marks == publish_done + empty_publish_skips )) ||
  fail "mountcache publish marks do not reconcile with publish attempts"

echo "Managed mountcache path verified: plans=${plans} hydrate_requests=${hydrate_requests} hydrate_hits=${hydrate_hits} hydrate_misses=${hydrate_misses} hydrate_miss_all=${hydrate_miss_all} hydrate_skips=${hydrate_skips} write_tracking_complete=${write_tracking_complete} publish_marks=${publish_marks} publish_done=${publish_done} publish_skips=${publish_skips}"
