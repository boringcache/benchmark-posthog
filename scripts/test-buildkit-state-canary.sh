#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/scripts/run-buildkit-state-canary.sh"
preflight_runner="$repo_root/scripts/preflight-buildkit-state-canary.sh"
image_index_verifier="$repo_root/scripts/verify-buildkit-image-index.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/buildkit-state-canary-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

source_sha="$(printf '1%.0s' {1..40})"
image_digest="sha256:$(printf 'a%.0s' {1..64})"
cold_generation="sha256:$(printf 'b%.0s' {1..64})"
warm_generation="sha256:$(printf 'c%.0s' {1..64})"
rolling_parent="sha256:$(printf 'd%.0s' {1..64})"
rolling_generation="sha256:$(printf 'e%.0s' {1..64})"
repeat_generation="sha256:$(printf 'f%.0s' {1..64})"
mock_api_origin="https://api.example.test"
MOCK_CURRENT_SHA="$source_sha"

amd64_manifest="sha256:$(printf '8%.0s' {1..64})"
arm64_manifest="sha256:$(printf '9%.0s' {1..64})"
cat > "$test_root/image-index.json" <<JSON
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {"digest": "$amd64_manifest", "platform": {"os": "linux", "architecture": "amd64"}},
    {"digest": "$arm64_manifest", "platform": {"os": "linux", "architecture": "arm64"}}
  ]
}
JSON
[[ "$("$image_index_verifier" "$test_root/image-index.json" linux/amd64)" == "$amd64_manifest" ]]
[[ "$("$image_index_verifier" "$test_root/image-index.json" linux/arm64)" == "$arm64_manifest" ]]
if "$image_index_verifier" "$test_root/image-index.json" linux/s390x >/dev/null 2>&1; then
  echo "Expected a missing platform to fail the image-index gate" >&2
  exit 1
fi
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n' > "$test_root/single-manifest.json"
if "$image_index_verifier" "$test_root/single-manifest.json" linux/amd64 >/dev/null 2>&1; then
  echo "Expected a single-manifest document to fail the image-index gate" >&2
  exit 1
fi

git() {
  if [[ "$*" == *"cat-file -p "* ]]; then
    local commit commit_number previous_commit
    commit="${!#}"
    commit_number="$((10#${commit: -2}))"
    if ((commit_number > 1)); then
      printf -v previous_commit '%040d' "$((commit_number - 1))"
      printf 'tree %040d\nparent %s\n\nmock commit\n' 0 "$previous_commit"
    else
      printf 'tree %040d\n\nmock commit\n' 0
    fi
    return 0
  fi
  if [[ "$*" == *"checkout --detach "* ]]; then
    MOCK_CURRENT_SHA="${!#}"
    export MOCK_CURRENT_SHA
    return 0
  fi
  if [[ "$*" == *"rev-parse HEAD"* ]]; then
    printf '%s\n' "${MOCK_CURRENT_SHA:-$source_sha}"
  fi
  return 0
}

docker() {
  return 0
}

mock_warm_generation() {
  local index="$1"
  case "$index" in
    1) printf '%s\n' "$warm_generation" ;;
    2) printf '%s\n' "$repeat_generation" ;;
    *) printf 'sha256:%064x\n' "$((1000 + index))" ;;
  esac
}

boringcache() {
  if [[ "${1:-}" == "--version" ]]; then
    echo "boringcache mock-state-canary"
    return 0
  fi
  if [[ "${1:-}" == "inspect" ]]; then
    local backend_version_count="${MOCK_BACKEND_VERSION_COUNT:-1}"
    local backend_generation="${MOCK_BACKEND_GENERATION:-${BORINGCACHE_STATE_CANARY_EXPECTED_BACKEND_GENERATION:-}}"
    local backend_bytes="${BORINGCACHE_STATE_CANARY_EXPECTED_BACKEND_BYTES:-0}"
    local backend_current="${MOCK_BACKEND_CURRENT:-true}"
    command jq -n \
      --arg workspace "${2:-}" \
      --arg tag "${3:-}" \
      --arg generation "$backend_generation" \
      --argjson bytes "$backend_bytes" \
      --argjson current "$backend_current" \
      --argjson version_count "$backend_version_count" '
        {
          workspace: {name: "benchmark-posthog", slug: $workspace},
          identifier: {query: $tag, matched_by: "tag"},
          entry: {
            id: "00000000-0000-4000-8000-000000000001",
            primary_tag: $tag,
            status: "ready",
            manifest_root_digest: $generation,
            storage_mode: "cas",
            stored_size_bytes: $bytes,
            blob_count: 111,
            blob_total_size_bytes: $bytes,
            cas_layout: "buildkit-state-v1",
            hit_count: 0,
            created_at: "2026-07-14T00:00:00Z"
          },
          versions: {
            tag: $tag,
            version_count: $version_count,
            current: $current,
            total_storage_bytes: ($bytes * $version_count)
          }
        }
      '
    return 0
  fi

  local phase restore_status restored_generation parent generation logical_blobs logical_bytes
  local clean_start candidate_generation candidate_blobs candidate_bytes candidate_files
  local restore_blobs restore_helper_seconds window_baseline_bytes window_generation_count
  local window_max_restore_bytes window_max_generations window_rebase_reason
  local published_window_baseline_bytes published_window_generation_count invalid_clean_start
  local bootstrap_delta steady_delta blob_delta required_blob_delta required_blobs warm_index warm_count summary_name
  local transport_blobs transport_bytes saw_cacheonly saw_read_only saw_probe_target arg
  local is_probe save_status publish_status record_count record_flow_created record_flow_failure
  local replay_index retention_source retention_baseline prune_triggered prune_target_reason
  local pruned_records pruned_bytes records_before_prune records_after_prune
  local prune_cache_usage_before prune_cache_usage_after prune_disk_total
  local prune_disk_free_before prune_disk_free_after prune_disk_available_before prune_disk_available_after
  local prune_reserved_space prune_min_free_space prune_effective_keep prune_failure
  is_probe=0
  clean_start=0
  candidate_generation=""
  candidate_blobs=0
  candidate_bytes=0
  candidate_files=0
  restore_blobs=0
  restore_helper_seconds=0
  window_baseline_bytes=0
  window_generation_count=0
  window_max_restore_bytes=0
  window_max_generations=0
  window_rebase_reason=""
  published_window_baseline_bytes=0
  published_window_generation_count=0
  invalid_clean_start="${MOCK_CLEAN_START_INVALID_EVIDENCE:-}"
  save_status=uploaded
  publish_status=published
  record_count=5
  record_flow_created=4
  record_flow_failure="${MOCK_RECORD_FLOW_FAILURE:-}"
  retention_source=post-clean-measured
  retention_baseline=100000
  prune_triggered=1
  prune_target_reason=scaffold-clean
  pruned_records=3
  pruned_bytes=3000
  prune_cache_usage_before=103000
  prune_cache_usage_after="$retention_baseline"
  prune_disk_total=100000000000
  prune_disk_free_before=50000000000
  prune_disk_free_after=50000000000
  prune_disk_available_before=49000000000
  prune_disk_available_after=49000000000
  prune_reserved_space=0
  prune_min_free_space=0
  prune_effective_keep=0
  prune_failure="${MOCK_PRUNE_FAILURE:-}"
  case "$BORINGCACHE_STATE_SUMMARY_PATH" in
    *mount-probe.state-summary.json)
      phase=mount-probe
      is_probe=1
      restore_status=restored
      restored_generation="$BORINGCACHE_STATE_CANARY_PROBE_EXPECTED_GENERATION"
      parent=""
      generation=""
      logical_blobs=0
      logical_bytes=0
      required_blobs=0
      transport_blobs=0
      transport_bytes=0
      save_status=read_only
      publish_status=read_only
      ;;
    *cold.state-summary.json)
      phase=cold
      restore_status=miss
      restored_generation=""
      parent=""
      generation="$cold_generation"
      logical_blobs=100
      logical_bytes=100000
      required_blobs=2
      transport_blobs=100
      transport_bytes=100000
      ;;
    *same-ref-warm.state-summary.json|*same-ref-repeat.state-summary.json|*same-ref-repeat-[0-9][0-9][0-9].state-summary.json)
      summary_name="$(basename "$BORINGCACHE_STATE_SUMMARY_PATH" .state-summary.json)"
      phase="$summary_name"
      case "$summary_name" in
        same-ref-warm) warm_index=1 ;;
        same-ref-repeat) warm_index=2 ;;
        same-ref-repeat-*) warm_index="$((10#${summary_name##*-}))" ;;
      esac
      warm_count="${BORINGCACHE_STATE_CANARY_WARM_GENERATIONS:-2}"
      restore_status=restored
      if ((warm_index == 1)); then
        restored_generation="$cold_generation"
      else
        restored_generation="$(mock_warm_generation "$((warm_index - 1))")"
      fi
      parent="$restored_generation"
      generation="$(mock_warm_generation "$warm_index")"
      bootstrap_delta="${MOCK_BOOTSTRAP_DELTA_PERCENT:--5}"
      steady_delta=0
      blob_delta="${MOCK_BOOTSTRAP_BLOB_DELTA:-0}"
      required_blob_delta="${MOCK_BOOTSTRAP_REQUIRED_BLOB_DELTA:-0}"
      if ((warm_index > 1)); then
        steady_delta="${MOCK_STATE_GROWTH_PERCENT:-1}"
        blob_delta="${MOCK_STATE_BLOB_DELTA:-0}"
        required_blob_delta="${MOCK_STATE_REQUIRED_BLOB_DELTA:-0}"
      fi
      if ((warm_index == warm_count)) && [[ -n "${MOCK_FINAL_STATE_GROWTH_PERCENT:-}" ]]; then
        steady_delta="$MOCK_FINAL_STATE_GROWTH_PERCENT"
      elif ((warm_index == ${MOCK_INTERMEDIATE_SPIKE_WARM_INDEX:-0})); then
        steady_delta="${MOCK_INTERMEDIATE_STATE_GROWTH_PERCENT:-20}"
      fi
      if ((warm_index == warm_count)) && [[ -n "${MOCK_FINAL_STATE_BLOB_DELTA:-}" ]]; then
        blob_delta="$MOCK_FINAL_STATE_BLOB_DELTA"
      fi
      logical_blobs=$((100 + blob_delta))
      logical_bytes=$((100000 + (bootstrap_delta * 1000) + (steady_delta * 1000)))
      required_blobs=$((2 + required_blob_delta))
      if ((warm_index == warm_count)); then
        required_blobs=$((2 + ${MOCK_FINAL_REQUIRED_BLOB_DELTA:-$required_blob_delta}))
      fi
      transport_blobs=1
      transport_bytes=1000
      record_count="$((5 + ${MOCK_WARM_RECORD_DELTA:-0}))"
      record_flow_created="${MOCK_WARM_RECORD_FLOW_CREATED:-3}"
      if ((warm_index == ${MOCK_CLEAN_START_WARM_INDEX:-0})); then
        clean_start=1
        candidate_generation="$restored_generation"
        candidate_blobs=100
        candidate_bytes=100000
        candidate_files=100
      elif [[ "${MOCK_CLEAN_START_WRONG_FOLLOWUP:-0}" == 1 ]] && \
           ((warm_index == ${MOCK_CLEAN_START_WARM_INDEX:-0} + 1)); then
        restored_generation="sha256:$(printf '9%.0s' {1..64})"
        parent="$restored_generation"
      fi
      ;;
    *rolling.state-summary.json)
      phase=rolling
      record_count=7
      restore_status=restored
      restored_generation="$rolling_parent"
      parent="$rolling_parent"
      generation="$rolling_generation"
      logical_blobs=120
      logical_bytes=120000
      required_blobs=2
      transport_blobs=4
      transport_bytes=4000
      if [[ "${MOCK_CLEAN_START_ROLLING:-0}" == 1 ]]; then
        clean_start=1
        candidate_generation="$restored_generation"
        candidate_blobs=120
        candidate_bytes=120000
        candidate_files=120
      fi
      ;;
    *replay-*.state-summary.json)
      phase="$(basename "$BORINGCACHE_STATE_SUMMARY_PATH" .state-summary.json)"
      replay_index="${phase#replay-}"
      replay_index="${replay_index%%-*}"
      replay_index="$((10#$replay_index))"
      printf -v generation 'sha256:%064x' "$((200 + replay_index))"
      logical_blobs="$((100 + replay_index))"
      logical_bytes="$((100000 + (replay_index * 1000)))"
      if ((replay_index == ${MOCK_OVERSIZED_REPLAY_INDEX:-0})); then
        logical_bytes="${MOCK_OVERSIZED_REPLAY_BYTES:-17179869185}"
      fi
      required_blobs="$((2 + replay_index))"
      transport_blobs=1
      transport_bytes=1000
      if ((replay_index == 1)); then
        restore_status=miss
        restored_generation=""
        parent=""
        transport_blobs="$logical_blobs"
        transport_bytes="$logical_bytes"
      else
        restore_status=restored
        printf -v restored_generation 'sha256:%064x' "$((199 + replay_index))"
        parent="$restored_generation"
      fi
      if ((replay_index == 6)) && [[ "${MOCK_DISABLE_REPLAY_SCAFFOLD_PRUNE:-0}" == 1 ]]; then
        prune_triggered=0
        pruned_records=0
        pruned_bytes=0
        prune_cache_usage_before="$retention_baseline"
      fi
      if ((replay_index == ${MOCK_CLEAN_START_REPLAY_INDEX:-0})); then
        clean_start=1
        candidate_generation="$restored_generation"
        candidate_blobs="$((99 + replay_index))"
        candidate_bytes="$((99000 + (replay_index * 1000)))"
        candidate_files="$candidate_blobs"
      fi
      ;;
    *)
      echo "Unexpected mock summary path: $BORINGCACHE_STATE_SUMMARY_PATH" >&2
      return 1
      ;;
  esac

  if [[ -n "${replay_index:-}" ]] && \
     ((replay_index == ${MOCK_CHANGED_REPLAY_BASELINE_INDEX:-0})); then
    retention_baseline=100001
    prune_cache_usage_before=103001
    prune_cache_usage_after="$retention_baseline"
  fi

  if [[ "$clean_start" == 1 ]]; then
    restore_status=clean_start
    restored_generation=""
    parent=""
    window_baseline_bytes=100000
    window_generation_count=64
    window_max_restore_bytes=17179869184
    window_max_generations=64
    case "${MOCK_CLEAN_START_REASON:-generation_count}" in
      generation_count) window_rebase_reason=generation_count ;;
      restore_bytes)
        window_rebase_reason=restore_bytes
        candidate_bytes=21474836480
        window_baseline_bytes=8589934592
        window_generation_count=2
        window_max_restore_bytes=17179869184
        ;;
      *)
        echo "Unknown mocked clean-start reason: ${MOCK_CLEAN_START_REASON}" >&2
        return 1
        ;;
    esac
    published_window_baseline_bytes="$logical_bytes"
    published_window_generation_count=1
    case "$invalid_clean_start" in
      "") ;;
      missing-candidate) candidate_generation="" ;;
      restored-body)
        restore_blobs=1
        restore_helper_seconds=0.1
        ;;
      parented-root)
        parent="$candidate_generation"
        published_window_generation_count=2
        ;;
      below-window-limit) window_generation_count=63 ;;
      below-restore-limit) candidate_bytes="$window_max_restore_bytes" ;;
      same-generation) generation="$candidate_generation" ;;
      omitted-zero|omitted-restore-generation|omitted-save-parent) ;;
      *)
        echo "Unknown mocked clean-start evidence failure: ${invalid_clean_start}" >&2
        return 1
        ;;
    esac
  fi

  records_after_prune="$record_count"
  records_before_prune="$((record_count + pruned_records))"
  if [[ "$clean_start" != 1 ]]; then
    published_window_baseline_bytes=100000
    published_window_generation_count=1
  fi

  command jq -n \
    --arg restore_status "$restore_status" \
    --arg restored_generation "$restored_generation" \
    --arg parent "$parent" \
    --arg generation "$generation" \
    --arg image_digest "$image_digest" \
    --argjson logical_blobs "$logical_blobs" \
    --argjson logical_bytes "$logical_bytes" \
    --argjson required_blobs "$required_blobs" \
    --argjson transport_blobs "$transport_blobs" \
    --argjson transport_bytes "$transport_bytes" \
    --argjson clean_start "$clean_start" \
    --arg candidate_generation "$candidate_generation" \
    --argjson candidate_blobs "$candidate_blobs" \
    --argjson candidate_bytes "$candidate_bytes" \
    --argjson candidate_files "$candidate_files" \
    --argjson restore_blobs "$restore_blobs" \
    --argjson restore_helper_seconds "$restore_helper_seconds" \
    --argjson window_baseline_bytes "$window_baseline_bytes" \
    --argjson window_generation_count "$window_generation_count" \
    --argjson window_max_restore_bytes "$window_max_restore_bytes" \
    --argjson window_max_generations "$window_max_generations" \
    --arg window_rebase_reason "$window_rebase_reason" \
    --argjson published_window_baseline_bytes "$published_window_baseline_bytes" \
    --argjson published_window_generation_count "$published_window_generation_count" \
    --arg invalid_clean_start "$invalid_clean_start" \
    --argjson include_logical_generation "$(if [[ "${MOCK_OMIT_LOGICAL_GENERATION:-0}" == 1 ]]; then echo false; else echo true; fi)" \
    --arg retention_policy "${MOCK_RETENTION_POLICY:-state-window-scaffold-clean-v1}" \
    --arg retention_source "$retention_source" \
    --argjson retention_baseline "$retention_baseline" \
    --argjson prune_applied "$(if [[ "${MOCK_PRUNE_APPLIED:-1}" == 1 ]]; then echo true; else echo false; fi)" \
    --argjson prune_triggered "$(if [[ "$prune_triggered" == 1 ]]; then echo true; else echo false; fi)" \
    --arg prune_target_reason "$prune_target_reason" \
    --argjson pruned_records "$pruned_records" \
    --argjson pruned_bytes "$pruned_bytes" \
    --argjson records_before_prune "$records_before_prune" \
    --argjson records_after_prune "$records_after_prune" \
    --argjson prune_cache_usage_before "$prune_cache_usage_before" \
    --argjson prune_cache_usage_after "$prune_cache_usage_after" \
    --argjson prune_disk_total "$prune_disk_total" \
    --argjson prune_disk_free_before "$prune_disk_free_before" \
    --argjson prune_disk_free_after "$prune_disk_free_after" \
    --argjson prune_disk_available_before "$prune_disk_available_before" \
    --argjson prune_disk_available_after "$prune_disk_available_after" \
    --argjson prune_reserved_space "$prune_reserved_space" \
    --argjson prune_min_free_space "$prune_min_free_space" \
    --argjson prune_effective_keep "$prune_effective_keep" \
    --arg prune_failure "$prune_failure" \
    --argjson content_gc_applied "$(if [[ "${MOCK_CONTENT_GC_APPLIED:-1}" == 1 ]]; then echo true; else echo false; fi)" \
    --arg save_status "$save_status" \
    --arg publish_status "$publish_status" \
    --argjson record_count "$record_count" \
    --argjson record_flow_created "$record_flow_created" \
    --arg record_flow_failure "$record_flow_failure" \
    --argjson records_after_gc "${MOCK_RECORDS_AFTER_GC:-$records_after_prune}" \
    --argjson include_content_gc_seconds "$(if [[ "${MOCK_OMIT_CONTENT_GC_SECONDS:-0}" == 1 ]]; then echo false; else echo true; fi)" \
    --argjson mountcache_enabled "$(if [[ "${BORINGCACHE_STATE_CANARY_COMPOSITION_MODE:-off}" == fixture ]]; then echo true; else echo false; fi)" \
    --argjson is_probe "$(if [[ "$is_probe" == 1 ]]; then echo true; else echo false; fi)" \
    --argjson mountcache_hydrate_errors "$(if [[ "$is_probe" == 1 ]]; then echo "${MOCK_MOUNTCACHE_PROBE_HYDRATE_ERRORS:-0}"; else echo "${MOCK_MOUNTCACHE_HYDRATE_ERRORS:-0}"; fi)" \
    --argjson composition_short_circuit "$(if [[ "${MOCK_COMPOSITION_SHORT_CIRCUIT:-0}" == 1 ]]; then echo true; else echo false; fi)" \
    '{
      schema_version: "buildkit-state-summary.v2",
      restore: {
        status: $restore_status,
        generation: (if $restored_generation == "" then null else $restored_generation end),
        bytes: (if $restore_status == "restored" then $logical_bytes else 0 end),
        files: (if $restore_status == "restored" then $logical_blobs else 0 end)
      },
      daemon_ready_seconds: 0.1,
      finalize: {
        eligible: 2,
        already_ready: 1,
        materialized: 1,
        failed: 0,
        required_blobs: $required_blobs,
        report_digest: $image_digest,
        retention_policy: $retention_policy,
        retention_source: $retention_source,
        retention_disk_usage_baseline_bytes: $retention_baseline,
        prune_applied: $prune_applied,
        prune_triggered: $prune_triggered,
        prune_target_satisfied: true,
        prune_target_reason: $prune_target_reason,
        prune_all: true,
        prune_filter_count: 2,
        prune_max_used_space_bytes: 0,
        pruned_records: $pruned_records,
        pruned_bytes: $pruned_bytes,
        prune_duration_ms: 50,
        records_before_prune: $records_before_prune,
        records_after_prune: $records_after_prune,
        prune_keep_duration_ms: 0,
        prune_cutoff_unix_nano: 0,
        prune_cache_usage_before_bytes: $prune_cache_usage_before,
        prune_cache_usage_after_bytes: $prune_cache_usage_after,
        prune_disk_total_bytes: $prune_disk_total,
        prune_disk_free_before_bytes: $prune_disk_free_before,
        prune_disk_free_after_bytes: $prune_disk_free_after,
        prune_disk_available_before_bytes: $prune_disk_available_before,
        prune_disk_available_after_bytes: $prune_disk_available_after,
        prune_reserved_space_bytes: $prune_reserved_space,
        prune_min_free_space_bytes: $prune_min_free_space,
        prune_effective_keep_bytes: $prune_effective_keep,
        content_gc_applied: $content_gc_applied,
        content_gc_duration_ms: 100,
        records_before_gc: $records_after_prune,
        records_after_gc: $records_after_gc,
        seconds: 0.2
      },
      state_record_flow: {
        status: "recorded",
        total_records: $records_before_prune,
        eligible_records: 2,
        created_during_build: $record_flow_created,
        local_source_records: 3,
        local_sources_created_during_build: 3,
        local_source_groups: [
          {
            description: "mock local source alpha",
            total: 2,
            created_during_build: 2
          },
          {
            description: "mock local source beta",
            total: 1,
            created_during_build: 1
          }
        ],
        created_local_sources: [
          {
            record_id: "opaque-local-source-1",
            description: "mock local source alpha",
            created_at_unix_nano: 1,
            active_references: 1,
            retained: true
          },
          {
            record_id: "opaque-local-source-2",
            description: "mock local source alpha",
            created_at_unix_nano: 2,
            active_references: 0,
            retained: false
          },
          {
            record_id: "opaque-local-source-3",
            description: "mock local source beta",
            created_at_unix_nano: 3,
            active_references: 2,
            retained: true
          }
        ]
      },
      quiesce_seconds: 0.1,
      save: {
        status: $save_status,
        generation: (if $generation == "" then null else $generation end),
        parent: (if $parent == "" then null else $parent end),
        reused_blobs: $logical_blobs,
        reused_bytes: $logical_bytes,
        uploaded_blobs: $transport_blobs,
        uploaded_bytes: $transport_bytes,
        publish_status: $publish_status
      },
      compatibility: {
        image_digest: $image_digest,
        state_format: "buildkit-state-v1",
        platform: "linux/amd64",
        rootless: false
      },
      mount_cache: {
        enabled: $mountcache_enabled,
        available_archives: (if $mountcache_enabled and $restore_status == "restored" then 1 else 0 end),
        available_bytes: (if $mountcache_enabled and $restore_status == "restored" then 100 else 0 end),
        restored_blobs: 0,
        restored_archives: 0,
        restored_bytes: 0,
        generation_archives: (if $mountcache_enabled and ($is_probe | not) then 1 else 0 end),
        generation_bytes: (if $mountcache_enabled and ($is_probe | not) then 100 else 0 end),
        staged_archives: (
          if $mountcache_enabled and ($is_probe | not)
             and (($composition_short_circuit and $restore_status == "restored") | not)
          then 1 else 0 end
        ),
        released_archives: (
          if $mountcache_enabled and ($is_probe | not)
             and (($composition_short_circuit and $restore_status == "restored") | not)
          then 1 else 0 end
        ),
        aborted_archives: 0,
        selected_archives: (if $mountcache_enabled then 1 else 0 end),
        hydrate_hits: (
          if $mountcache_enabled and $restore_status == "restored"
             and ($is_probe or ($composition_short_circuit | not))
          then 1 else 0 end
        ),
        hydrate_misses: 0,
        hydrate_errors: $mountcache_hydrate_errors,
        hydrate_skips: 0,
        hydrated_files: (
          if $mountcache_enabled and $restore_status == "restored"
             and ($is_probe or ($composition_short_circuit | not))
          then 1 else 0 end
        ),
        hydrated_compressed_bytes: (
          if $mountcache_enabled and $restore_status == "restored"
             and ($is_probe or ($composition_short_circuit | not))
          then 100 else 0 end
        ),
        hydrated_uncompressed_bytes: (
          if $mountcache_enabled and $restore_status == "restored"
             and ($is_probe or ($composition_short_circuit | not))
          then 200 else 0 end
        ),
        hydrate_milliseconds: 1,
        published_archives: (
          if $mountcache_enabled and ($is_probe | not)
             and (($composition_short_circuit and $restore_status == "restored") | not)
          then 1 else 0 end
        ),
        publish_errors: 0,
        published_files: (
          if $mountcache_enabled and ($is_probe | not)
             and (($composition_short_circuit and $restore_status == "restored") | not)
          then 1 else 0 end
        ),
        published_compressed_bytes: (
          if $mountcache_enabled and ($is_probe | not)
             and (($composition_short_circuit and $restore_status == "restored") | not)
          then 100 else 0 end
        ),
        published_uncompressed_bytes: (
          if $mountcache_enabled and ($is_probe | not)
             and (($composition_short_circuit and $restore_status == "restored") | not)
          then 200 else 0 end
        ),
        publish_milliseconds: 1,
        runtime_status: (if $mountcache_enabled then "recorded" else "disabled" end)
      },
      total_state_overhead_seconds: 0.4
    }
    | if $clean_start == 1 then
        .restore += {
          candidate_generation: (if $candidate_generation == "" then null else $candidate_generation end),
          candidate_blobs: $candidate_blobs,
          candidate_bytes: $candidate_bytes,
          candidate_files: $candidate_files,
          state_window_baseline_bytes: $window_baseline_bytes,
          state_window_generation_count: $window_generation_count,
          state_window_max_restore_bytes: $window_max_restore_bytes,
          state_window_max_generations: $window_max_generations,
          state_window_rebase_reason: $window_rebase_reason,
          blobs: $restore_blobs,
          core_blobs: 0,
          core_bytes: 0,
          core_files: 0,
          mount_cache_blobs: 0,
          mount_cache_bytes: 0,
          mount_cache_files: 0,
          download_sequential_blobs: 0,
          download_parallel_blobs: 0,
          download_range_parts: 0,
          download_request_retries: 0,
          download_origin_fallbacks: 0,
          resolve_seconds: 0.1,
          manifest_seconds: 0.1,
          verify_seconds: 0.1,
          url_plan_seconds: 0,
          helper_seconds: $restore_helper_seconds,
          seconds: 0.3
        }
        | .save.state_window_baseline_bytes = $published_window_baseline_bytes
        | .save.state_window_generation_count = $published_window_generation_count
      else . end
    | if $clean_start == 1 and $invalid_clean_start == "omitted-zero" then
        del(.restore.download_range_parts)
      elif $clean_start == 1 and $invalid_clean_start == "omitted-restore-generation" then
        del(.restore.generation)
      elif $clean_start == 1 and $invalid_clean_start == "omitted-save-parent" then
        del(.save.parent)
      else . end
    | if $record_flow_failure == "unavailable" then
        .state_record_flow = {status: "unavailable"}
      elif $record_flow_failure == "created-count" then
        .state_record_flow.created_during_build = 2
      elif $record_flow_failure == "group-total" then
        .state_record_flow.local_source_groups[0].total = 1
      elif $record_flow_failure == "group-created" then
        .state_record_flow.local_source_groups[0].created_during_build = 1
      elif $record_flow_failure == "duplicate-id" then
        .state_record_flow.created_local_sources[2].record_id = "opaque-local-source-1"
      elif $record_flow_failure == "empty-description" then
        .state_record_flow.created_local_sources[2].description = ""
      elif $record_flow_failure == "zero-timestamp" then
        .state_record_flow.created_local_sources[2].created_at_unix_nano = 0
      elif $record_flow_failure == "" then .
      else error("unknown mocked record-flow failure")
      end
    | if $prune_failure == "not-applied" then
        .finalize.prune_applied = false
      elif $prune_failure == "wrong-source" then
        .finalize.retention_source = "restored-marker"
      elif $prune_failure == "changed-baseline" then
        .finalize.retention_disk_usage_baseline_bytes += 1
      elif $prune_failure == "unsafe-scope" then
        .finalize.prune_all = false
      elif $prune_failure == "filtered" then
        .finalize.prune_filter_count = 1
      elif $prune_failure == "aged" then
        .finalize.prune_keep_duration_ms = 1
      elif $prune_failure == "cutoff" then
        .finalize.prune_cutoff_unix_nano = 1
      elif $prune_failure == "unsatisfied" then
        .finalize.prune_target_satisfied = false
        | .finalize.prune_target_reason = "foreign-policy"
      elif $prune_failure == "record-delta" then
        .finalize.records_before_prune += 1
      elif $prune_failure == "gc-link" then
        .finalize.records_before_gc += 1
      elif $prune_failure == "disk" then
        .finalize.prune_disk_available_before_bytes = (.finalize.prune_disk_free_before_bytes + 1)
      elif $prune_failure == "min-free" then
        .finalize.prune_min_free_space_bytes += 1
      elif $prune_failure == "effective-keep" then
        .finalize.prune_effective_keep_bytes -= 1
      elif $prune_failure == "triggered-mismatch" then
        .finalize.prune_triggered = false
      elif $prune_failure == "" then .
      else error("unknown mocked prune failure")
      end
    | if $include_content_gc_seconds then .content_gc_seconds = 0.1 else . end
    | if $include_logical_generation then
        .save.logical_generation_blobs = $logical_blobs
        | .save.logical_generation_bytes = $logical_bytes
      else . end' > "$BORINGCACHE_STATE_SUMMARY_PATH"

  saw_cacheonly=0
  saw_tool_cache=0
  saw_read_only=0
  saw_probe_target=0
  for arg in "$@"; do
    [[ "$arg" == type=cacheonly ]] && saw_cacheonly=1
    [[ "$arg" == turbo:* ]] && saw_tool_cache=1
    [[ "$arg" == --read-only ]] && saw_read_only=1
    [[ "$arg" == boringcache-state-mount-probe ]] && saw_probe_target=1
  done
  [[ "$saw_cacheonly" -eq 1 ]] || {
    echo "Mock canary command omitted its cache-only product output" >&2
    return 1
  }

  if [[ "${BORINGCACHE_STATE_CANARY_COMPOSITION_MODE:-off}" == fixture && "$saw_tool_cache" -ne 1 ]]; then
    echo "Mock composition command omitted its Turbo tool cache" >&2
    return 1
  fi

  if [[ "$is_probe" -eq 1 && ("$saw_read_only" -ne 1 || "$saw_probe_target" -ne 1) ]]; then
    echo "Mock terminal mount probe was not read-only or did not select its fixture target" >&2
    return 1
  fi

  printf 'mock daemon %s\n' "$phase" > "$BORINGCACHE_MANAGED_BUILDKIT_LOG_PATH"
  if [[ "${BORINGCACHE_STATE_CANARY_COMPOSITION_MODE:-off}" == fixture && "$is_probe" -eq 0 ]]; then
    local tool_hits tool_misses tool_writes
    tool_hits=1
    tool_misses=0
    tool_writes=1
    if [[ "${MOCK_COMPOSITION_SHORT_CIRCUIT:-0}" == 1 ]]; then
      if [[ "$restore_status" == miss ]]; then
        tool_hits=0
        tool_misses=1
        tool_writes=1
      else
        tool_hits=0
        tool_misses=0
        tool_writes=0
      fi
    fi
    command jq -cn \
      --arg phase "$phase" \
      --argjson hits "$tool_hits" \
      --argjson misses "$tool_misses" \
      --argjson writes "$tool_writes" \
      '{
      phase: $phase,
      operation: "cache_session_summary",
      adapter: "turborepo",
      duration_ms: 10,
      classification: {
        cache_temperature: {hits: $hits, misses: $misses, writes: $writes, errors: 0}
      },
      backend_api: {total_error_count: 0, total_retry_count: 0}
    }' > "$BORINGCACHE_OBSERVABILITY_JSONL_PATH"
  else
    printf '{"phase":"%s"}\n' "$phase" > "$BORINGCACHE_OBSERVABILITY_JSONL_PATH"
  fi
  echo '#1 [mock] build'
  if [[ "$phase" == cold || "$phase" == replay-001-* || "$restore_status" == clean_start ]]; then
    echo '#1 DONE 1.0s'
  elif [[ "$phase" == replay-* ]]; then
    local cached_count cached_index
    cached_count=68
    if ((replay_index == ${MOCK_REPLAY_CACHED_REGRESSION_INDEX:-0})); then
      cached_count=67
    fi
    for ((cached_index = 1; cached_index <= cached_count; cached_index++)); do
      printf '#%d CACHED\n' "$cached_index"
    done
  else
    echo '#1 CACHED'
    echo '#2 CACHED'
  fi
}

export -f git docker mock_warm_generation boringcache
sleep() {
  return 0
}
export -f sleep
export source_sha image_digest cold_generation warm_generation rolling_parent rolling_generation repeat_generation

write_mock_preflight() {
  local artifact_dir="$1"
  mkdir -p "$artifact_dir"
  command jq -n \
    --arg api_origin "$mock_api_origin" '
      {
        schema_version: "buildkit-state-canary-preflight.v1",
        api_origin: $api_origin,
        state_contract: {
          required_layout: "buildkit-state-v1",
          required_capability: "buildkit_state_current_set_v1"
        },
        checks: {
          expected_tag_head_v1: true,
          buildkit_state_current_set_v1: true
        },
        all_passed: true
      }
    ' > "$artifact_dir/preflight-backend.json"
  command jq -n \
    --arg api_origin "$mock_api_origin" '
      {
        schema_version: "buildkit-state-canary-preflight-complete.v1",
        api_origin: $api_origin,
        state_contract: {required_layout: "buildkit-state-v1"},
        checks: {
          backend_capabilities: true,
          backend_user_agent_exact: true,
          cli_asset_exact: true,
          buildkit_image_exact: true,
          source_target_exact: true,
          runner_disk_capacity: true,
          replay_plan_exact: true
        },
        all_passed: true
      }
    ' > "$artifact_dir/preflight-checklist.json"
}

write_mock_replay_plan() {
  local lane="$1"
  local artifact_dir="$2"
  local commits=()
  local index commit all_json selected_json
  for index in $(seq 1 11); do
    printf -v commit '%040d' "$index"
    commits+=("$commit")
  done
  all_json="$(printf '%s\n' "${commits[@]}" | command jq -Rsc 'split("\n") | map(select(length > 0))')"
  if [[ "$lane" == replay-full ]]; then
    selected_json="$all_json"
  else
    selected_json="$(printf '%s\n' "${commits[0]}" "${commits[10]}" | command jq -Rsc 'split("\n") | map(select(length > 0))')"
  fi
  command jq -n \
    --arg mode "$lane" \
    --arg base_sha "${commits[0]}" \
    --arg target_sha "${commits[10]}" \
    --argjson all_commits "$all_json" \
    --argjson selected_commits "$selected_json" '
      {
        schema_version: "buildkit-state-canary-replay-plan.v1",
        mode: $mode,
        base_sha: $base_sha,
        target_sha: $target_sha,
        all_commits: $all_commits,
        selected_commits: $selected_commits
      }
    ' > "$artifact_dir/replay-plan.json"
}

run_mock() {
  local lane="$1"
  local artifact_dir="$2"
  local requested_warm_generations="${3:-2}"
  local composition_mode="${4:-off}"
  local mountcache_offloader=0
  local tool_cache_tag=""
  if [[ "$composition_mode" == fixture ]]; then
    mountcache_offloader=1
    tool_cache_tag="mock-${lane}-turbo"
  fi
  write_mock_preflight "$artifact_dir"
  if [[ "$lane" == replay-full || "$lane" == replay-endpoints ]]; then
    write_mock_replay_plan "$lane" "$artifact_dir"
  fi
  MOCK_CURRENT_SHA="$source_sha"
  BORINGCACHE_STATE_CANARY_LANE="$lane" \
    BORINGCACHE_STATE_CANARY_WORKSPACE=boringcache/benchmark-posthog \
    BORINGCACHE_STATE_CANARY_TAG="mock-${lane}" \
    BORINGCACHE_STATE_CANARY_COMPOSITION_MODE="$composition_mode" \
    BORINGCACHE_STATE_CANARY_TOOL_CACHE_TAG="$tool_cache_tag" \
    BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE="ghcr.io/boringcache/buildkit@${image_digest}" \
    BORINGCACHE_STATE_CANARY_ARTIFACT_DIR="$artifact_dir" \
    BORINGCACHE_STATE_CANARY_REPLAY_PLAN="$artifact_dir/replay-plan.json" \
    BORINGCACHE_STATE_CANARY_PLATFORM=linux/amd64 \
    BORINGCACHE_STATE_CANARY_PLATEAU_TOLERANCE_PERCENT=2 \
    BORINGCACHE_STATE_CANARY_BACKEND_AUDIT_MAX_ATTEMPTS=1 \
    BORINGCACHE_STATE_CANARY_WARM_GENERATIONS="$requested_warm_generations" \
    BORINGCACHE_API_URL="$mock_api_origin" \
    BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER="$mountcache_offloader" \
    "$runner"
}

fresh_dir="$test_root/fresh"
run_mock fresh "$fresh_dir" >/dev/null
if ! command jq -e '
  .schema_version == "buildkit-state-canary-result.v2"
  and .success == true
  and all(.phases[]; .schema_version == "buildkit-state-canary-phase.v2")
  and .current_set.current_set_replacement == true
  and .current_set.same_ref_plateau == true
  and .current_set.same_ref_solver_reuse == true
  and .current_set.same_ref_first_warm_solver_reuse == true
  and .current_set.same_ref_repeat_solver_reuse == true
  and .current_set.all_warm_record_counts_stable == true
  and .current_set.same_ref_record_growth_observed == false
  and .current_set.same_ref_replacement_uploads_observed == true
  and .current_set.same_ref_replacement_uploaded_blobs == 2
  and .current_set.same_ref_replacement_uploaded_bytes == 2000
  and .current_set.same_ref_count_plateau == true
  and .inputs.warm_generations == 2
  and .current_set.warm_generations_planned == 2
  and .current_set.warm_generations_measured == 2
  and (.current_set.transitions | length) == 2
  and .current_set.transitions[0].kind == "bootstrap"
  and .current_set.transitions[1].kind == "same-ref"
  and .current_set.transitions[1].final_convergence_pair == true
  and .current_set.transitions[1].lineage.valid == true
  and .current_set.transitions[1].current_head_only == true
  and .current_set.transitions[1].solver_reuse == true
  and .current_set.transitions[1].record_set.eligible_delta == 0
  and .current_set.transitions[1].record_set.records_after_gc_delta == 0
  and .current_set.transitions[1].replacement_transport.uploaded_blobs == 1
  and .current_set.transitions[1].replacement_transport.uploaded_bytes == 1000
  and .current_set.growth.bootstrap_logical_blob_delta == 0
  and .current_set.growth.bootstrap_required_blob_delta == 0
  and .current_set.growth.bootstrap_blob_growth_within_tolerance == true
  and .current_set.growth.logical_blob_delta == 0
  and .current_set.growth.required_blob_delta == 0
  and .current_set.growth.required_blob_count_stable == true
  and .current_set.all_warm_content_counts_stable == true
  and .current_set.growth.all_warm_content_counts_stable == true
  and (.phases | length) == 3
  and all(.phases[];
    .checks.state_record_flow_valid == true
    and .state.state_record_flow.status == "recorded"
    and .state.state_record_flow.local_sources_created_during_build == 3
    and (.state.state_record_flow.created_local_sources | length) == 3
  )
  and .phases[0].state.state_record_flow.created_during_build > 3
  and all(.phases[1:][]; .state.state_record_flow.created_during_build == 3)
  and (.phases[0].state.logical_generation_blobs > 0)
  and (.phases[1].state.parent_generation == .phases[0].state.generation)
  and (.phases[1].state.head_generations_fetched == 1)
  and (.phases[2].state.parent_generation == .phases[1].state.generation)
  and (.phases[2].state.head_generations_fetched == 1)
' "$fresh_dir/canary-result.json" >/dev/null; then
  echo "Fresh convergence contract failed:" >&2
  command jq . "$fresh_dir/canary-result.json" >&2
  exit 1
fi

fresh_four_dir="$test_root/fresh-four"
run_mock fresh "$fresh_four_dir" 4 >/dev/null
command jq -e '
  .success == true
  and .inputs.warm_generations == 4
  and .current_set.warm_generations_planned == 4
  and .current_set.warm_generations_measured == 4
  and (.phases | map(.phase)) == [
    "cold",
    "same-ref-warm",
    "same-ref-repeat",
    "same-ref-repeat-003",
    "same-ref-repeat-004"
  ]
  and (.current_set.transitions | length) == 4
  and all(.current_set.transitions[]; .lineage.valid and .current_head_only and .solver_reuse)
  and .current_set.transitions[-1].final_convergence_pair == true
  and .current_set.transitions[-1].logical_set.within_tolerance == true
  and .current_set.growth.logical_blob_delta == 0
' "$fresh_four_dir/canary-result.json" >/dev/null

fresh_clean_start_dir="$test_root/fresh-clean-start"
MOCK_CLEAN_START_WARM_INDEX=2 run_mock fresh "$fresh_clean_start_dir" 4 >/dev/null
command jq -e '
  .success == true
  and .current_set.current_set_replacement == true
  and .current_set.clean_start_boundaries == 1
  and .current_set.clean_start_followup_proven == true
  and .current_set.plateau_window_start_transition == 3
  and .current_set.plateau_transitions_measured == 2
  and .current_set.transitions[1].kind == "clean-start"
  and .current_set.transitions[1].logical_set.blob_delta == null
  and .current_set.transitions[1].logical_set.byte_delta == null
  and .current_set.transitions[1].next_phase_restores_root == true
  and .phases[2].checks.clean_start_valid == true
  and .phases[2].state.restore.candidate_generation == .phases[1].state.generation
  and .phases[2].state.generation != .phases[2].state.restore.candidate_generation
  and .phases[2].state.parent_generation == null
  and .phases[2].state.state_window.published_generation_count == 1
  and .phases[3].state.restored_generation == .phases[2].state.generation
  and .phases[3].state.parent_generation == .phases[2].state.generation
' "$fresh_clean_start_dir/canary-result.json" >/dev/null

terminal_clean_start_dir="$test_root/fresh-terminal-clean-start"
if MOCK_CLEAN_START_WARM_INDEX=4 \
  run_mock fresh "$terminal_clean_start_dir" 4 >/dev/null 2>&1; then
  echo "Expected a terminal clean-start without a restoring product phase to remain pending" >&2
  exit 1
fi
command jq -e '
  .success == false
  and all(.phases[]; .success == true)
  and .current_set.current_set_replacement == false
  and .current_set.clean_start_boundaries == 1
  and .current_set.clean_start_followup_proven == false
  and .current_set.transitions[-1].kind == "clean-start"
  and .current_set.transitions[-1].next_phase_restores_root == false
' "$terminal_clean_start_dir/canary-result.json" >/dev/null

wrong_clean_start_followup_dir="$test_root/fresh-clean-start-wrong-followup"
if MOCK_CLEAN_START_WARM_INDEX=2 \
  MOCK_CLEAN_START_WRONG_FOLLOWUP=1 \
  run_mock fresh "$wrong_clean_start_followup_dir" 4 >/dev/null 2>&1; then
  echo "Expected a clean-start followed by the wrong generation to fail continuity" >&2
  exit 1
fi
command jq -e '
  .success == false
  and all(.phases[]; .success == true)
  and .current_set.current_set_replacement == false
  and .current_set.clean_start_followup_proven == false
  and .current_set.transitions[1].next_phase_restores_root == false
  and .current_set.transitions[2].lineage.valid == false
' "$wrong_clean_start_followup_dir/canary-result.json" >/dev/null

fresh_eight_dir="$test_root/fresh-eight"
run_mock fresh "$fresh_eight_dir" 8 >/dev/null
command jq -e '
  .success == true
  and .inputs.warm_generations == 8
  and .current_set.warm_generations_measured == 8
  and (.phases | length) == 9
  and .phases[-1].phase == "same-ref-repeat-008"
  and (.current_set.transitions | length) == 8
  and .current_set.transitions[-1].final_convergence_pair == true
' "$fresh_eight_dir/canary-result.json" >/dev/null

intermediate_growth_dir="$test_root/intermediate-growth"
MOCK_INTERMEDIATE_SPIKE_WARM_INDEX=2 \
  MOCK_INTERMEDIATE_STATE_GROWTH_PERCENT=20 \
  run_mock fresh "$intermediate_growth_dir" 4 >/dev/null
command jq -e '
  .success == true
  and .current_set.transitions[1].logical_set.within_tolerance == false
  and .current_set.transitions[2].logical_set.within_tolerance == false
  and .current_set.transitions[-1].logical_set.within_tolerance == true
  and .current_set.same_ref_plateau == true
' "$intermediate_growth_dir/canary-result.json" >/dev/null

intermediate_blob_growth_dir="$test_root/intermediate-blob-growth-failure"
if MOCK_STATE_BLOB_DELTA=1 run_mock fresh "$intermediate_blob_growth_dir" 4 >/dev/null 2>&1; then
  echo "Expected one new logical blob on an intermediate warm generation to fail the canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.current_set_replacement == false
  and .current_set.all_warm_content_counts_stable == false
  and .current_set.growth.all_warm_content_counts_stable == false
  and .current_set.transitions[1].logical_set.blob_delta == 1
  and .current_set.transitions[-1].logical_set.blob_delta == 0
  and .current_set.same_ref_plateau == false
' "$intermediate_blob_growth_dir/canary-result.json" >/dev/null

intermediate_required_blob_growth_dir="$test_root/intermediate-required-blob-growth-failure"
if MOCK_STATE_REQUIRED_BLOB_DELTA=1 run_mock fresh "$intermediate_required_blob_growth_dir" 4 >/dev/null 2>&1; then
  echo "Expected one new required BuildKit body on an intermediate warm generation to fail the canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.current_set_replacement == false
  and .current_set.all_warm_content_counts_stable == false
  and .current_set.growth.all_warm_content_counts_stable == false
  and .current_set.transitions[1].logical_set.required_blob_delta == 1
  and .current_set.transitions[-1].logical_set.required_blob_delta == 0
  and .current_set.same_ref_plateau == false
' "$intermediate_required_blob_growth_dir/canary-result.json" >/dev/null

final_growth_dir="$test_root/final-growth-failure"
if MOCK_FINAL_STATE_GROWTH_PERCENT=20 run_mock fresh "$final_growth_dir" 4 >/dev/null 2>&1; then
  echo "Expected final warm-to-warm growth to fail the canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.transitions[-1].final_convergence_pair == true
  and .current_set.transitions[-1].logical_set.within_tolerance == false
  and .current_set.same_ref_plateau == false
' "$final_growth_dir/canary-result.json" >/dev/null

final_blob_growth_dir="$test_root/final-blob-growth-failure"
if MOCK_FINAL_STATE_BLOB_DELTA=1 run_mock fresh "$final_blob_growth_dir" 4 >/dev/null 2>&1; then
  echo "Expected one new logical blob on the final warm generation to fail the canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.growth.logical_blob_delta == 1
  and .current_set.growth.blob_count_within_tolerance == false
  and .current_set.same_ref_plateau == false
' "$final_blob_growth_dir/canary-result.json" >/dev/null

final_required_blob_growth_dir="$test_root/final-required-blob-growth-failure"
if MOCK_FINAL_REQUIRED_BLOB_DELTA=1 run_mock fresh "$final_required_blob_growth_dir" 4 >/dev/null 2>&1; then
  echo "Expected one new required BuildKit body on the final warm generation to fail the canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.growth.required_blob_delta == 1
  and .current_set.growth.required_blob_count_stable == false
  and .current_set.same_ref_plateau == false
' "$final_required_blob_growth_dir/canary-result.json" >/dev/null

invalid_warm_dir="$test_root/invalid-warm-generations"
if run_mock fresh "$invalid_warm_dir" 3 >/dev/null 2>&1; then
  echo "Expected unsupported warm generation count to fail the canary" >&2
  exit 1
fi

rolling_dir="$test_root/rolling"
run_mock rolling "$rolling_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.current_set_replacement == true
  and .current_set.only_current_head_fetched == true
  and (.phases[0].state.transport_delta_blobs == 4)
  and .phases[0].state.finalize.retention_policy == "state-window-scaffold-clean-v1"
  and .phases[0].state.finalize.retention_source == "post-clean-measured"
  and .phases[0].state.finalize.retention_disk_usage_baseline_bytes == 100000
  and .phases[0].state.finalize.prune_applied == true
  and .phases[0].state.finalize.prune_triggered == true
  and .phases[0].state.finalize.prune_target_satisfied == true
  and .phases[0].state.finalize.prune_target_reason == "scaffold-clean"
  and .phases[0].state.finalize.prune_all == true
  and .phases[0].state.finalize.prune_filter_count == 2
  and .phases[0].state.finalize.prune_max_used_space_bytes == 0
  and .phases[0].state.finalize.pruned_records == 3
  and .phases[0].state.finalize.records_before_prune == 10
  and .phases[0].state.finalize.records_after_prune == 7
  and .phases[0].state.finalize.prune_cache_usage_before_bytes == 103000
  and .phases[0].state.finalize.prune_cache_usage_after_bytes == 100000
  and .phases[0].state.finalize.prune_disk_total_bytes == 100000000000
  and .phases[0].state.finalize.prune_min_free_space_bytes == 0
  and .phases[0].state.finalize.prune_reserved_space_bytes == 0
  and .phases[0].state.finalize.prune_effective_keep_bytes == 0
  and .phases[0].state.finalize.content_gc_applied == true
  and .phases[0].state.finalize.content_gc_duration_ms == 100
  and .phases[0].state.finalize.records_before_gc == 7
  and .phases[0].state.finalize.records_after_gc == 7
  and .phases[0].state.finalize.records_after_gc >= .phases[0].state.finalize.eligible
  and .phases[0].checks.state_record_flow_valid == true
  and .phases[0].state.state_record_flow.status == "recorded"
  and .phases[0].state.state_record_flow.total_records == 10
  and .phases[0].state.state_record_flow.created_during_build > 3
  and .phases[0].state.state_record_flow.local_sources_created_during_build == 3
  and (.phases[0].state.state_record_flow.created_local_sources | length) == 3
  and .phases[0].state.content_gc_seconds == 0.1
' "$rolling_dir/canary-result.json" >/dev/null

rolling_clean_start_dir="$test_root/rolling-clean-start-pending"
if MOCK_CLEAN_START_ROLLING=1 run_mock rolling "$rolling_clean_start_dir" >/dev/null 2>&1; then
  echo "Expected a single rolling clean-start to remain pending until a later product restore" >&2
  exit 1
fi
command jq -e '
  .success == false
  and (.phases | length) == 1
  and .phases[0].success == true
  and .phases[0].checks.clean_start_valid == true
  and .phases[0].state.restore_status == "clean_start"
  and .phases[0].state.generation != .phases[0].state.restore.candidate_generation
  and .current_set.current_set_replacement == false
  and .current_set.clean_start_boundaries == 1
  and .current_set.clean_start_followup_proven == false
  and .current_set.clean_start_followup_pending == true
  and .current_set.ready_for_graduation == false
' "$rolling_clean_start_dir/canary-result.json" >/dev/null

replay_full_dir="$test_root/replay-full"
run_mock replay-full "$replay_full_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.current_set_replacement == true
  and .current_set.only_current_head_fetched == true
  and .current_set.exact_source_sequence == true
  and .current_set.replay.mode == "replay-full"
  and .current_set.replay.planned_generations == 11
  and .current_set.replay.measured_generations == 11
  and .current_set.replay.clean_start_free == true
  and .current_set.replay.post_clean_baselines_valid == true
  and .current_set.replay.retention_sources_valid == true
  and .current_set.replay.all_prune_contracts_valid == true
  and .current_set.replay.scaffold_prune_generations == 11
  and .current_set.replay.scaffold_prune_observed == true
  and .current_set.replay.minimum_cached_steps == 68
  and .current_set.replay.restored_successors_measured == 10
  and .current_set.replay.all_restored_successors_hit_contract == true
  and .current_set.replay.minimum_observed_successor_cached_steps == 68
  and .current_set.replay.ready_for_graduation == true
  and .current_set.replay.growth_observation.first_logical_core_bytes == 101000
  and .current_set.replay.growth_observation.final_logical_core_bytes == 111000
  and .current_set.replay.growth_observation.delta_bytes == 10000
  and .current_set.replay.all_successors_within_tolerance == true
  and (.current_set.replay.generations | length) == 11
  and .current_set.replay.generations[0].continuity == true
  and .current_set.replay.generations[0].prune.retention_source == "post-clean-measured"
  and .current_set.replay.generations[0].prune.triggered == true
  and .current_set.replay.generations[0].prune.pruned_records == 3
  and .current_set.replay.generations[5].prune.retention_source == "post-clean-measured"
  and .current_set.replay.generations[5].prune.triggered == true
  and .current_set.replay.generations[5].prune.target_reason == "scaffold-clean"
  and .current_set.replay.generations[5].prune.pruned_records == 3
  and .current_set.replay.generations[5].prune.records_before == 8
  and .current_set.replay.generations[5].prune.records_after == 5
  and .current_set.replay.generations[1].logical_set.blob_delta_from_previous == 1
  and .current_set.replay.generations[1].transport_delta.blobs == 1
  and .current_set.replay.generations[1].build.cached_steps == 68
  and .current_set.replay.generations[1].build.hit_contract_satisfied == true
  and .current_set.backend_current_version_set == true
  and .current_set.backend_current_head_set == true
  and .backend_current_set.all_phases_valid == true
  and .backend_current_set.all_phases_retention_converged == true
  and .backend_current_set.max_active_versions == 1
  and (.backend_current_set.phases | length) == 11
  and all(.backend_current_set.phases[];
    .active_versions == 1
    and .active_storage_bytes == .current_entry_bytes
    and .observed_generation == .expected_generation
    and .head_valid == true
    and .retention_converged == true
    and .valid == true
  )
  and .backend_current_set.valid == true
' "$replay_full_dir/canary-result.json" >/dev/null

cache_hit_regression_dir="$test_root/replay-cache-hit-regression"
if MOCK_REPLAY_CACHED_REGRESSION_INDEX=7 \
  run_mock replay-full "$cache_hit_regression_dir" >/dev/null 2>&1; then
  echo "Expected a replay successor below the PostHog cache-hit floor to fail graduation" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.current_set_replacement == false
  and .current_set.replay.minimum_cached_steps == 68
  and .current_set.replay.restored_successors_measured == 10
  and .current_set.replay.all_restored_successors_hit_contract == false
  and .current_set.replay.minimum_observed_successor_cached_steps == 67
  and .current_set.replay.ready_for_graduation == false
  and .current_set.replay.generations[6].build.cached_steps == 67
  and .current_set.replay.generations[6].build.hit_contract_satisfied == false
' "$cache_hit_regression_dir/canary-result.json" >/dev/null

backend_tail_dir="$test_root/replay-backend-version-tail"
MOCK_BACKEND_VERSION_COUNT=2 \
  run_mock replay-full "$backend_tail_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.backend_current_head_set == true
  and .current_set.backend_current_version_set == false
  and .current_set.replay.backend_retention_converged == false
  and .current_set.replay.ready_for_graduation == true
  and .backend_current_set.all_phases_valid == true
  and .backend_current_set.all_phases_retention_converged == false
  and .backend_current_set.max_active_versions == 2
  and (.backend_current_set.phases | length) == 11
  and all(.backend_current_set.phases[];
    .active_storage_bytes > .current_entry_bytes
    and .observed_generation == .expected_generation
    and .head_valid == true
    and .retention_converged == false
    and .valid == true
  )
  and .backend_current_set.valid == true
  and .backend_current_set.retention_converged == false
' "$backend_tail_dir/canary-result.json" >/dev/null

backend_wrong_head_dir="$test_root/replay-backend-wrong-head"
if MOCK_BACKEND_CURRENT=false \
  run_mock replay-full "$backend_wrong_head_dir" >/dev/null 2>&1; then
  echo "Expected a replay whose exact backend head is not current to fail" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.backend_current_head_set == false
  and .backend_current_set.all_phases_valid == false
  and (.backend_current_set.phases | length) == 1
  and .backend_current_set.phases[0].head_valid == false
  and .backend_current_set.phases[0].valid == false
  and .backend_current_set.valid == false
' "$backend_wrong_head_dir/canary-result.json" >/dev/null

missing_scaffold_prune_dir="$test_root/replay-missing-scaffold-prune"
if MOCK_DISABLE_REPLAY_SCAFFOLD_PRUNE=1 \
  run_mock replay-full "$missing_scaffold_prune_dir" >/dev/null 2>&1; then
  echo "Expected a replay without per-build scaffold cleanup to fail graduation" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.replay.clean_start_free == true
  and .current_set.replay.post_clean_baselines_valid == true
  and .current_set.replay.all_prune_contracts_valid == true
  and .current_set.replay.scaffold_prune_generations == 10
  and .current_set.replay.scaffold_prune_observed == true
  and .current_set.replay.ready_for_graduation == false
' "$missing_scaffold_prune_dir/canary-result.json" >/dev/null

changed_baseline_dir="$test_root/replay-changed-post-clean-baseline"
MOCK_CHANGED_REPLAY_BASELINE_INDEX=8 \
  run_mock replay-full "$changed_baseline_dir" >/dev/null
command jq -e '
  .success == true
  and all(.phases[]; .checks.summary_valid == true and .success == true)
  and .current_set.replay.clean_start_free == true
  and .current_set.replay.retention_sources_valid == true
  and .current_set.replay.post_clean_baselines_valid == true
  and .current_set.replay.scaffold_prune_observed == true
  and .current_set.replay.generations[7].prune.baseline_bytes == 100001
  and .current_set.replay.ready_for_graduation == true
' "$changed_baseline_dir/canary-result.json" >/dev/null

oversized_replay_dir="$test_root/replay-oversized-logical-core"
MOCK_OVERSIZED_REPLAY_INDEX=7 \
  run_mock replay-full "$oversized_replay_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.replay.clean_start_free == true
  and .current_set.replay.scaffold_prune_observed == true
  and .current_set.replay.ready_for_graduation == true
  and .current_set.replay.generations[6].logical_set.bytes == 17179869185
' "$oversized_replay_dir/canary-result.json" >/dev/null

clean_start_dir="$test_root/replay-clean-start"
MOCK_CLEAN_START_REPLAY_INDEX=6 run_mock replay-full "$clean_start_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.current_set_replacement == true
  and .current_set.clean_start_boundaries == 1
  and .current_set.clean_start_followup_proven == true
  and .current_set.replay.clean_start_free == false
  and .current_set.replay.ready_for_graduation == true
  and .current_set.replay.plateau_window_start_sequence == 6
  and .current_set.replay.active_successors_measured == 5
  and .current_set.replay.all_successors_within_tolerance == true
  and .current_set.replay.generations[5].clean_start_boundary == true
  and .current_set.replay.generations[5].next_phase_restores_root == true
  and .current_set.replay.generations[5].logical_set.blob_delta_from_previous == null
  and .current_set.replay.generations[5].logical_set.byte_delta_from_previous == null
  and .current_set.replay.generations[5].logical_set.within_previous_tolerance == null
  and .current_set.replay.generations[6].logical_set.blob_delta_from_previous == 1
  and .phases[5].state.restore_status == "clean_start"
  and .phases[5].state.restore.candidate_generation == .phases[4].state.generation
  and .phases[5].state.restore.candidate_blobs > 0
  and .phases[5].state.restore.candidate_bytes > 0
  and .phases[5].state.restore.candidate_files > 0
  and .phases[5].state.restore.restored_blobs == 0
  and .phases[5].state.restore.restored_bytes == 0
  and .phases[5].state.restore.restored_files == 0
  and .phases[5].state.restore.helper_seconds == 0
  and .phases[5].state.restored_generation == null
  and .phases[5].state.parent_generation == null
  and .phases[5].state.state_window.rebase_reason == "generation_count"
  and .phases[5].state.state_window.candidate_generation_count
      >= .phases[5].state.state_window.max_generations
  and .phases[5].state.state_window.published_generation_count == 1
  and .phases[5].state.state_window.published_baseline_bytes
      == .phases[5].state.logical_generation_bytes
  and .phases[5].checks.clean_start_valid == true
  and .phases[6].state.restore_status == "restored"
  and .phases[6].state.restored_generation == .phases[5].state.generation
  and .phases[6].state.parent_generation == .phases[5].state.generation
' "$clean_start_dir/canary-result.json" >/dev/null

restore_bytes_clean_start_dir="$test_root/replay-clean-start-restore-bytes"
MOCK_CLEAN_START_REPLAY_INDEX=6 \
  MOCK_CLEAN_START_REASON=restore_bytes \
  run_mock replay-full "$restore_bytes_clean_start_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.clean_start_boundaries == 1
  and .current_set.clean_start_followup_proven == true
  and .current_set.replay.clean_start_free == false
  and .current_set.replay.ready_for_graduation == true
  and .phases[5].state.state_window.rebase_reason == "restore_bytes"
  and .phases[5].state.restore.candidate_bytes == 21474836480
  and .phases[5].state.state_window.max_restore_bytes == 17179869184
  and .phases[5].state.restore.candidate_bytes
      > .phases[5].state.state_window.max_restore_bytes
  and .phases[6].state.restored_generation == .phases[5].state.generation
' "$restore_bytes_clean_start_dir/canary-result.json" >/dev/null

for invalid_clean_start in \
  missing-candidate \
  restored-body \
  parented-root \
  below-window-limit \
  same-generation \
  omitted-zero \
  omitted-restore-generation \
  omitted-save-parent; do
  invalid_clean_start_dir="$test_root/fresh-clean-start-${invalid_clean_start}"
  if MOCK_CLEAN_START_WARM_INDEX=1 \
    MOCK_CLEAN_START_INVALID_EVIDENCE="$invalid_clean_start" \
    run_mock fresh "$invalid_clean_start_dir" >/dev/null 2>&1; then
    echo "Expected invalid clean-start evidence (${invalid_clean_start}) to fail closed" >&2
    exit 1
  fi
  command jq -e '
    .success == false
    and .phases[-1].state.restore_status == "clean_start"
    and .phases[-1].checks.clean_start_valid == false
    and .phases[-1].success == false
  ' "$invalid_clean_start_dir/canary-result.json" >/dev/null
done

invalid_restore_bytes_dir="$test_root/fresh-clean-start-below-restore-limit"
if MOCK_CLEAN_START_WARM_INDEX=1 \
  MOCK_CLEAN_START_REASON=restore_bytes \
  MOCK_CLEAN_START_INVALID_EVIDENCE=below-restore-limit \
  run_mock fresh "$invalid_restore_bytes_dir" >/dev/null 2>&1; then
  echo "Expected invalid clean-start evidence (below-restore-limit) to fail closed" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .phases[-1].state.restore_status == "clean_start"
  and .phases[-1].checks.clean_start_valid == false
' "$invalid_restore_bytes_dir/canary-result.json" >/dev/null

replay_endpoints_dir="$test_root/replay-endpoints"
run_mock replay-endpoints "$replay_endpoints_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.current_set_replacement == true
  and .current_set.exact_source_sequence == true
  and .current_set.replay.mode == "replay-endpoints"
  and .current_set.replay.planned_generations == 11
  and .current_set.replay.measured_generations == 2
  and (.current_set.replay.generations | length) == 2
' "$replay_endpoints_dir/canary-result.json" >/dev/null

growth_dir="$test_root/growth-failure"
if MOCK_STATE_GROWTH_PERCENT=20 run_mock fresh "$growth_dir" >/dev/null 2>&1; then
  echo "Expected excessive same-ref growth to fail the canary" >&2
  exit 1
fi
command jq -e '.success == false and .current_set.same_ref_plateau == false' "$growth_dir/canary-result.json" >/dev/null

bootstrap_growth_dir="$test_root/bootstrap-byte-growth-failure"
if MOCK_BOOTSTRAP_DELTA_PERCENT=20 run_mock fresh "$bootstrap_growth_dir" >/dev/null 2>&1; then
  echo "Expected excessive cold-to-first-warm byte growth to fail the canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.growth.bootstrap_blob_growth_within_tolerance == true
  and .current_set.growth.bootstrap_bytes_growth_within_tolerance == false
' "$bootstrap_growth_dir/canary-result.json" >/dev/null

schema_dir="$test_root/schema-failure"
if MOCK_OMIT_LOGICAL_GENERATION=1 run_mock fresh "$schema_dir" >/dev/null 2>&1; then
  echo "Expected missing logical-generation summary fields to fail closed" >&2
  exit 1
fi
command jq -e '
  .schema_version == "buildkit-state-canary-result.v2"
  and .success == false
  and (.phases | length) == 1
  and .phases[0].phase == "cold"
  and .phases[0].success == false
  and .current_set.current_set_replacement == false
  and .current_set.same_ref_plateau == false
  and .current_set.same_ref_solver_reuse == false
  and .current_set.growth.bootstrap_blob_growth_within_tolerance == false
  and .current_set.growth.bootstrap_bytes_growth_within_tolerance == false
  and .current_set.growth.blob_count_within_tolerance == false
  and .current_set.growth.bytes_within_tolerance == false
' "$schema_dir/canary-result.json" >/dev/null

retention_dir="$test_root/retention-failure"
if MOCK_RETENTION_POLICY=pruned-main-cache run_mock rolling "$retention_dir" >/dev/null 2>&1; then
  echo "Expected unsupported main-cache retention policy to fail closed" >&2
  exit 1
fi
command jq -e '.success == false and .phases[0].checks.summary_valid == false' "$retention_dir/canary-result.json" >/dev/null

for prune_failure in \
  not-applied \
  wrong-source \
  changed-baseline \
  unsafe-scope \
  filtered \
  aged \
  cutoff \
  unsatisfied \
  record-delta \
  gc-link \
  disk \
  min-free \
  effective-keep \
  triggered-mismatch; do
  prune_failure_dir="$test_root/retention-${prune_failure}"
  if MOCK_PRUNE_FAILURE="$prune_failure" \
    run_mock fresh "$prune_failure_dir" >/dev/null 2>&1; then
    echo "Expected an unsafe scaffold-clean retention report to fail closed (${prune_failure})" >&2
    exit 1
  fi
  command jq -e '
    .success == false
    and .phases[0].checks.summary_valid == false
    and .phases[0].success == false
  ' "$prune_failure_dir/canary-result.json" >/dev/null
done

content_gc_dir="$test_root/content-gc-failure"
if MOCK_CONTENT_GC_APPLIED=0 run_mock rolling "$content_gc_dir" >/dev/null 2>&1; then
  echo "Expected absent terminal content GC to fail closed" >&2
  exit 1
fi
command jq -e '.success == false and .phases[0].checks.summary_valid == false' "$content_gc_dir/canary-result.json" >/dev/null

content_gc_records_dir="$test_root/content-gc-records-failure"
if MOCK_RECORDS_AFTER_GC=1 run_mock rolling "$content_gc_records_dir" >/dev/null 2>&1; then
  echo "Expected content GC record-set mutation to fail closed" >&2
  exit 1
fi
command jq -e '.success == false and .phases[0].checks.summary_valid == false' "$content_gc_records_dir/canary-result.json" >/dev/null

content_gc_seconds_dir="$test_root/content-gc-seconds-failure"
if MOCK_OMIT_CONTENT_GC_SECONDS=1 run_mock rolling "$content_gc_seconds_dir" >/dev/null 2>&1; then
  echo "Expected missing content GC timing to fail closed" >&2
  exit 1
fi
command jq -e '.success == false and .phases[0].checks.summary_valid == false' "$content_gc_seconds_dir/canary-result.json" >/dev/null

for record_flow_failure in \
  unavailable \
  created-count \
  group-total \
  group-created \
  duplicate-id \
  empty-description \
  zero-timestamp; do
  record_flow_dir="$test_root/record-flow-${record_flow_failure}"
  if MOCK_RECORD_FLOW_FAILURE="$record_flow_failure" \
    run_mock rolling "$record_flow_dir" >/dev/null 2>&1; then
    echo "Expected invalid BuildKit state record flow (${record_flow_failure}) to fail closed" >&2
    exit 1
  fi
  command jq -e '
    .success == false
    and .phases[0].checks.summary_valid == true
    and .phases[0].checks.state_record_flow_valid == false
    and .phases[0].success == false
  ' "$record_flow_dir/canary-result.json" >/dev/null
done

same_ref_extra_record_dir="$test_root/record-flow-same-ref-extra-created"
if MOCK_WARM_RECORD_FLOW_CREATED=4 \
  run_mock fresh "$same_ref_extra_record_dir" >/dev/null 2>&1; then
  echo "Expected extra same-ref records created during the user build to fail closed" >&2
  exit 1
fi
command jq -e '
  .success == false
  and (.phases | length) == 2
  and .phases[0].checks.state_record_flow_valid == true
  and .phases[0].state.state_record_flow.created_during_build > 3
  and .phases[1].checks.state_record_flow_valid == false
  and .phases[1].state.state_record_flow.created_during_build == 4
' "$same_ref_extra_record_dir/canary-result.json" >/dev/null

record_growth_dir="$test_root/record-growth-failure"
if MOCK_WARM_RECORD_DELTA=3 run_mock fresh "$record_growth_dir" 2 fixture >/dev/null 2>&1; then
  echo "Expected same-ref BuildKit record growth to block graduation" >&2
  exit 1
fi
command jq -e '
  .success == false
  and .current_set.current_set_replacement == false
  and .current_set.all_warm_record_counts_stable == false
  and .current_set.same_ref_record_growth_observed == true
  and .current_set.same_ref_count_plateau == false
  and .current_set.transitions[0].record_set.eligible_delta == 0
  and .current_set.transitions[0].record_set.records_after_gc_delta == 3
  and .composition.valid == true
  and .terminal_mount_probe.attempted == true
  and .terminal_mount_probe.valid == true
' "$record_growth_dir/canary-result.json" >/dev/null

composition_dir="$test_root/composition-fixture"
run_mock replay-full "$composition_dir" 2 fixture >/dev/null
command jq -e '
  .success == true
  and .inputs.composition_mode == "fixture"
  and .inputs.mountcache_enabled == true
  and .inputs.tool_env_delivery == "static-secret-fixture"
  and .composition.valid == true
  and .composition.mountcache_published == true
  and .composition.signed_refs_available == true
  and .composition.zero_eager_mount_restore == true
  and .composition.generation_refs_bounded == true
  and .composition.deferred_publish_lifecycle == true
  and .composition.mountcache_hydrated == true
  and .composition.toolcache_exercised == true
  and .composition.toolcache_hits == true
  and .terminal_mount_probe.enabled == true
  and .terminal_mount_probe.attempted == true
  and .terminal_mount_probe.read_only == true
  and .terminal_mount_probe.timing_included_in_product_phases == false
  and .terminal_mount_probe.expected_generation == .terminal_mount_probe.restored_generation
  and .terminal_mount_probe.signed_ref_archives == 1
  and .terminal_mount_probe.selected_archives == 1
  and .terminal_mount_probe.eager_restored_blobs == 0
  and .terminal_mount_probe.eager_restored_archives == 0
  and .terminal_mount_probe.eager_restored_bytes == 0
  and .terminal_mount_probe.hydrate_hits == 1
  and .terminal_mount_probe.hydrate_misses == 0
  and .terminal_mount_probe.hydrate_errors == 0
  and .terminal_mount_probe.hydrate_skips == 0
  and .terminal_mount_probe.staged_archives == 0
  and .terminal_mount_probe.released_archives == 0
  and .terminal_mount_probe.aborted_archives == 0
  and .terminal_mount_probe.published_archives == 0
  and .terminal_mount_probe.valid == true
  and all(.phases[];
    .state.mount_cache.restored_blobs == 0
    and .state.mount_cache.restored_archives == 0
    and .state.mount_cache.restored_bytes == 0
    and .state.mount_cache.staged_archives == .state.mount_cache.released_archives
    and .state.mount_cache.aborted_archives == 0
  )
  and all(.phases[]; .checks.tool_cache_valid == true)
' "$composition_dir/canary-result.json" >/dev/null

composition_short_circuit_dir="$test_root/composition-short-circuit"
MOCK_COMPOSITION_SHORT_CIRCUIT=1 run_mock fresh "$composition_short_circuit_dir" 2 fixture >/dev/null
command jq -e '
  . as $result
  | .success == true
  and .composition.valid == true
  and .composition.mountcache_published == true
  and .composition.signed_refs_available == true
  and .composition.zero_eager_mount_restore == true
  and .composition.deferred_publish_lifecycle == true
  and .composition.mountcache_hydrated == true
  and .composition.toolcache_exercised == true
  and .composition.toolcache_hits == false
  and .composition.fully_state_cached_short_circuit == true
  and .terminal_mount_probe.hydrate_hits == 1
  and .terminal_mount_probe.valid == true
  and all(.phases[1:][];
    .cached_steps > $result.phases[0].cached_steps
    and .state.mount_cache.hydrate_hits == 0
    and .tool_cache.hits == 0
    and .tool_cache.misses == 0
    and .tool_cache.writes == 0
  )
' "$composition_short_circuit_dir/canary-result.json" >/dev/null

composition_mount_error_dir="$test_root/composition-mount-error"
if MOCK_MOUNTCACHE_PROBE_HYDRATE_ERRORS=1 run_mock fresh "$composition_mount_error_dir" 2 fixture >/dev/null 2>&1; then
  echo "Expected terminal mount-cache hydration errors to fail the composition canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and (.phases | length) == 3
  and all(.phases[]; .success == true)
  and .terminal_mount_probe.enabled == true
  and .terminal_mount_probe.attempted == true
  and .terminal_mount_probe.hydrate_errors == 1
  and .terminal_mount_probe.valid == false
' "$composition_mount_error_dir/canary-result.json" >/dev/null

mountcache_dir="$test_root/mountcache-failure"
write_mock_preflight "$mountcache_dir"
if BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER=1 \
  BORINGCACHE_STATE_CANARY_LANE=fresh \
  BORINGCACHE_STATE_CANARY_WORKSPACE=boringcache/benchmark-posthog \
  BORINGCACHE_STATE_CANARY_TAG=mock-mountcache \
  BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE="ghcr.io/boringcache/buildkit@${image_digest}" \
  BORINGCACHE_STATE_CANARY_ARTIFACT_DIR="$mountcache_dir" \
  BORINGCACHE_API_URL="$mock_api_origin" \
  "$runner" >/dev/null 2>&1; then
  echo "Expected mountcache-enabled core canary to fail" >&2
  exit 1
fi

curl() {
  local output=""
  local user_agent=""
  local user_agent_count=0
  while (($# > 0)); do
    case "$1" in
      --output)
        output="$2"
        shift 2
        ;;
      --header)
        case "$2" in
          User-Agent:*)
            user_agent="$2"
            user_agent_count=$((user_agent_count + 1))
            ;;
        esac
        shift 2
        ;;
      --write-out|--connect-timeout|--max-time)
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  [[ "$user_agent_count" -eq 1 && "$user_agent" == "User-Agent: BoringCache-CLI/${BORINGCACHE_STATE_CANARY_CLI_VERSION}" ]] || {
    echo "Capability preflight did not send the pinned CLI User-Agent" >&2
    return 64
  }
  command cp "$MOCK_CAPABILITIES_FILE" "$output"
  printf '%s' "${MOCK_HTTP_STATUS:-200}"
}
export -f curl

capabilities_good="$test_root/capabilities-good.json"
command jq -n '
  {
    api_version: "v2",
    features: {
      entry_create_v2: true,
      blob_stage_v2: true,
      tag_publish_v2: true,
      upload_sessions_v2: true,
      upload_receipts_v2: true,
      expected_tag_head_v1: true,
      buildkit_state_current_set_v1: true,
      cas_publish_bootstrap_if_match: "0"
    }
  }
' > "$capabilities_good"
preflight_good_dir="$test_root/preflight-good"
MOCK_CAPABILITIES_FILE="$capabilities_good" \
BORINGCACHE_STATE_CANARY_API_ORIGIN="$mock_api_origin" \
BORINGCACHE_STATE_CANARY_LANE=fresh \
BORINGCACHE_STATE_CANARY_CLI_RELEASE_TAG=v9.9.9-state-canary \
BORINGCACHE_STATE_CANARY_CLI_VERSION=9.9.9 \
BORINGCACHE_STATE_CANARY_CLI_ASSET_SHA256="$(printf 'f%.0s' {1..64})" \
BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE="ghcr.io/boringcache/buildkit@${image_digest}" \
BORINGCACHE_STATE_CANARY_POSTHOG_SOURCE="$source_sha" \
BORINGCACHE_STATE_CANARY_ARTIFACT_DIR="$preflight_good_dir" \
BORINGCACHE_RESTORE_TOKEN=mock-restore-token \
  "$preflight_runner" >/dev/null
command jq -e '
  .all_passed == true
  and .checks.expected_tag_head_v1 == true
  and .checks.buildkit_state_current_set_v1 == true
  and .backend_probe.user_agent == "BoringCache-CLI/9.9.9"
' "$preflight_good_dir/preflight-backend.json" >/dev/null

capabilities_bad="$test_root/capabilities-bad.json"
command jq '.features.buildkit_state_current_set_v1 = false' "$capabilities_good" > "$capabilities_bad"
preflight_bad_dir="$test_root/preflight-bad"
if MOCK_CAPABILITIES_FILE="$capabilities_bad" \
  BORINGCACHE_STATE_CANARY_API_ORIGIN="$mock_api_origin" \
  BORINGCACHE_STATE_CANARY_LANE=fresh \
  BORINGCACHE_STATE_CANARY_CLI_RELEASE_TAG=v9.9.9-state-canary \
  BORINGCACHE_STATE_CANARY_CLI_VERSION=9.9.9 \
  BORINGCACHE_STATE_CANARY_CLI_ASSET_SHA256="$(printf 'f%.0s' {1..64})" \
  BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE="ghcr.io/boringcache/buildkit@${image_digest}" \
  BORINGCACHE_STATE_CANARY_POSTHOG_SOURCE="$source_sha" \
  BORINGCACHE_STATE_CANARY_ARTIFACT_DIR="$preflight_bad_dir" \
  BORINGCACHE_RESTORE_TOKEN=mock-restore-token \
    "$preflight_runner" >/dev/null 2>&1; then
  echo "Expected missing BuildKit current-set capability to fail preflight" >&2
  exit 1
fi
command jq -e '.all_passed == false and .checks.buildkit_state_current_set_v1 == false' \
  "$preflight_bad_dir/preflight-backend.json" >/dev/null

record_flow_summary_renderer="$repo_root/scripts/render-buildkit-state-record-flow-summary.sh"
record_flow_summary_fixture="$test_root/record-flow-summary-malformed.json"
command jq -n '
  {
    phases: [
      {
        phase: "scalar-flow",
        checks: {state_record_flow_valid: false},
        state: {state_record_flow: "malformed"}
      },
      {
        phase: "malformed-details",
        checks: {state_record_flow_valid: false},
        state: {
          state_record_flow: {
            total_records: 5,
            eligible_records: 4,
            created_during_build: 3,
            local_source_records: 3,
            local_sources_created_during_build: 3,
            local_source_groups: [7, {description: null, total: "bad", created_during_build: 1}],
            created_local_sources: [false, {description: "context|line\nbreak"}]
          }
        }
      }
    ]
  }
' > "$record_flow_summary_fixture"
record_flow_summary_output="$(bash "$record_flow_summary_renderer" "$record_flow_summary_fixture")"
grep -F '| scalar-flow | no | n/a / n/a / n/a | n/a / n/a |  |  |' <<<"$record_flow_summary_output" >/dev/null
grep -F '| malformed-details | no | 5 / 4 / 3 | 3 / 3 | <invalid group>; <invalid>: bad/1 | <invalid record>; context / line break |' <<<"$record_flow_summary_output" >/dev/null

echo "BuildKit state canary mocked lifecycle is valid."
