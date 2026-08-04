#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assertion="$repo_root/scripts/assert-boringcache-mountcache-run.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/posthog-mountcache-evidence.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

write_summary() {
  local path="$1"
  local mountcache="$2"
  jq -cn --argjson mountcache "$mountcache" '{
    operation: "cache_session_summary",
    buildkit: {mountcache: $mountcache}
  }' > "$path"
}

passing_summary='{
  "schema_version": "buildkit_mountcache.v1",
  "configured": true,
  "plans": 1,
  "hydrate_requests": 1,
  "hydrate_hits": 1,
  "hydrate_misses": 0,
  "hydrate_miss_all": 0,
  "hydrate_skips": 0,
  "hydrate_errors": 0,
  "write_tracking_complete": 1,
  "write_tracking_unreliable": 0,
  "publish_marks": 1,
  "publish_skips": 0,
  "publish_skip_reason_counts": {},
  "publish_done": 1,
  "publish_errors": 0,
  "samples": []
}'

passing_path="$test_root/passing.jsonl"
write_summary "$passing_path" "$passing_summary"
"$assertion" "$passing_path" >/dev/null

no_writes_path="$test_root/no-writes.jsonl"
write_summary "$no_writes_path" "$(jq -c '
  .hydrate_hits = 0
  | .hydrate_misses = 1
  | .hydrate_miss_all = 1
  | .publish_marks = 0
  | .publish_done = 0
  | .publish_skips = 1
  | .publish_skip_reason_counts = {no_writes: 1}
' <<< "$passing_summary")"
"$assertion" "$no_writes_path" >/dev/null

empty_mount_path="$test_root/empty-mount.jsonl"
write_summary "$empty_mount_path" "$(jq -c '
  .publish_done = 0
  | .publish_skips = 1
  | .publish_skip_reason_counts = {empty: 1}
' <<< "$passing_summary")"
"$assertion" "$empty_mount_path" >/dev/null

non_empty_hydrate_path="$test_root/non-empty-hydrate.jsonl"
write_summary "$non_empty_hydrate_path" "$(jq -c '
  .hydrate_requests = 0
  | .hydrate_hits = 0
  | .hydrate_skips = 1
  | .samples = [{event: "mountcache_hydrate_skip", reason: "non_empty"}]
' <<< "$passing_summary")"
"$assertion" "$non_empty_hydrate_path" >/dev/null

assert_fails() {
  local name="$1"
  local summary="$2"
  local expected="$3"
  local path="$test_root/${name}.jsonl"
  local stderr="$test_root/${name}.stderr"
  write_summary "$path" "$summary"
  if "$assertion" "$path" > /dev/null 2> "$stderr"; then
    echo "Expected ${name} mountcache evidence to fail" >&2
    exit 1
  fi
  grep -Fq "$expected" "$stderr"
}

assert_fails hot-oci-graph "$(jq -c '
  .plans = 0
  | .hydrate_requests = 0
  | .hydrate_hits = 0
  | .write_tracking_complete = 0
  | .publish_marks = 0
  | .publish_done = 0
' <<< "$passing_summary")" "hot OCI graph"

assert_fails hydrate-error "$(jq -c '.hydrate_errors = 1' <<< "$passing_summary")" \
  "hydration recorded 1 error"

assert_fails incomplete-hydrate "$(jq -c '
  .hydrate_requests = 2
' <<< "$passing_summary")" "hydrate attempts do not reconcile"

assert_fails missing-plan-terminal "$(jq -c '
  .plans = 2
' <<< "$passing_summary")" "plans do not reconcile with terminal hydrate outcomes"

assert_fails unexplained-hydrate-skip "$(jq -c '
  .hydrate_requests = 0
  | .hydrate_hits = 0
  | .hydrate_skips = 1
' <<< "$passing_summary")" "explicit permitted non_empty reason"

assert_fails unreliable-write-tracking "$(jq -c '.write_tracking_unreliable = 1' <<< "$passing_summary")" \
  "write tracking was unreliable"

assert_fails incomplete-write-tracking "$(jq -c '
  .write_tracking_complete = 0
' <<< "$passing_summary")" "write-tracking observations do not cover every plan"

assert_fails unknown-publish-skip "$(jq -c '
  .publish_done = 0
  | .publish_skips = 1
  | .publish_skip_reason_counts = {not_publishable: 1}
' <<< "$passing_summary")" "unpermitted skip reason"

assert_fails unmatched-publish-mark "$(jq -c '
  .publish_marks = 2
' <<< "$passing_summary")" "publish marks do not reconcile"

assert_fails missing-publish-terminal "$(jq -c '
  .publish_marks = 0
  | .publish_done = 0
' <<< "$passing_summary")" "plans do not reconcile with terminal publish outcomes"

echo "Managed mountcache evidence contract is valid."
