#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

benchmark_id="${BENCHMARK_ID:?Set BENCHMARK_ID}"
benchmark_workspace="${BENCHMARK_WORKSPACE:?Set BENCHMARK_WORKSPACE}"
cache_scope="${CACHE_SCOPE:?Set CACHE_SCOPE}"
outputs_file="${BENCHMARK_OUTPUTS_PATH:-benchmark-results/${benchmark_id}-boringcache-rolling.outputs.env}"
project_repo="${BENCHMARK_PROJECT_REPO:-PostHog/posthog}"
project_ref="${BENCHMARK_PROJECT_REF:-}"

read_output() {
  local key="$1"
  [[ -s "$outputs_file" ]] || return 0
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
    }
    END {
      if (value != "") {
        print value
      }
    }
  ' "$outputs_file"
}

if [[ -z "$project_ref" ]]; then
  project_ref="$(git rev-parse HEAD:upstream 2>/dev/null || git -C upstream rev-parse HEAD 2>/dev/null || echo unknown)"
fi

mkdir -p benchmark-storage
tags_csv="$cache_scope"
docker_tool_cache="${BORINGCACHE_DOCKER_TOOL_CACHE:-}"
if [[ -n "$docker_tool_cache" ]]; then
  tool_tags=()
  for tool_cache_value in ${docker_tool_cache//,/ }; do
    [[ -n "$tool_cache_value" ]] || continue
    if [[ "$tool_cache_value" == *:* ]]; then
      tool_tags+=("${tool_cache_value#*:}")
    else
      tool_tags+=("${cache_scope}-${tool_cache_value%%:*}")
    fi
  done
  if ((${#tool_tags[@]} > 0)); then
    tool_tags_csv="$(IFS=,; printf '%s' "${tool_tags[*]}")"
    tags_csv="${tags_csv},${tool_tags_csv}"
  fi
fi

storage_breakdown_path="benchmark-storage/${benchmark_id}-boringcache-storage-breakdown.json"
bytes="$(BORINGCACHE_STORAGE_BREAKDOWN_PATH="$storage_breakdown_path" BORINGCACHE_EXACT_TAGS="$tags_csv" \
  "$repo_root/scripts/sum-boringcache-check-sizes.sh" "$benchmark_workspace" "$tags_csv")"

cache_summary_args=()
if [[ -s benchmark-session-summary/benchmark-session-summary.json ]]; then
  cache_summary_args=(--cache-session-summary-json benchmark-session-summary/benchmark-session-summary.json)
fi


"$repo_root/scripts/write-benchmark-artifacts.sh" \
  --benchmark "$benchmark_id" \
  --strategy boringcache \
  --lane rolling \
  --mode docker \
  --adapter buildkit \
  --project-repo "$project_repo" \
  --project-ref "$project_ref" \
  --cold-seconds "$(read_output seconds)" \
  --cold-build-seconds "$(read_output build_seconds)" \
  --warm1-seconds "" \
  --warm1-build-seconds "" \
  --cache-import-status "$(read_output cache_import_status)" \
  --docker-cache-import-seconds "$(read_output docker_cache_import_seconds)" \
  --docker-cache-export-seconds "$(read_output docker_cache_export_seconds)" \
  --buildkit-cached-steps "$(read_output buildkit_cached_steps)" \
  --buildkit-cache-prewarm-seconds "$(read_output buildkit_cache_prewarm_seconds)" \
  --buildkit-cache-prepare-seconds "$(read_output buildkit_cache_prepare_seconds)" \
  --buildkit-cache-send-seconds "$(read_output buildkit_cache_send_seconds)" \
  --buildkit-cache-prewarm-queued "$(read_output buildkit_cache_prewarm_queued)" \
  --buildkit-cache-prewarm-dropped "$(read_output buildkit_cache_prewarm_dropped)" \
  --buildkit-cache-prewarm-canceled "$(read_output buildkit_cache_prewarm_canceled)" \
  --buildkit-cache-prewarm-retried "$(read_output buildkit_cache_prewarm_retried)" \
  --buildkit-cache-prewarm-deferred "$(read_output buildkit_cache_prewarm_deferred)" \
  --buildkit-cache-prewarm-prepared "$(read_output buildkit_cache_prewarm_prepared)" \
  --buildkit-cache-prewarm-body-prepared "$(read_output buildkit_cache_prewarm_body_prepared)" \
  --buildkit-cache-prewarm-committed-bodies "$(read_output buildkit_cache_prewarm_committed_bodies)" \
  --buildkit-cache-prewarm-delegated-bodies "$(read_output buildkit_cache_prewarm_delegated_bodies)" \
  --buildkit-cache-prewarm-owned-bodies "$(read_output buildkit_cache_prewarm_owned_bodies)" \
  --buildkit-cache-prewarm-owned-body-bytes "$(read_output buildkit_cache_prewarm_owned_body_bytes)" \
  --buildkit-cache-prewarm-owned-body-max "$(read_output buildkit_cache_prewarm_owned_body_max)" \
  --buildkit-cache-prewarm-resolved "$(read_output buildkit_cache_prewarm_resolved)" \
  --buildkit-cache-prewarm-reused "$(read_output buildkit_cache_prewarm_reused)" \
  --buildkit-cache-prewarm-uploaded "$(read_output buildkit_cache_prewarm_uploaded)" \
  --buildkit-cache-prewarm-failed "$(read_output buildkit_cache_prewarm_failed)" \
  --buildkit-cache-prewarm-recursive "$(read_output buildkit_cache_prewarm_recursive)" \
  --buildkit-cache-prewarm-direct "$(read_output buildkit_cache_prewarm_direct)" \
  --buildkit-cache-prewarm-missed "$(read_output buildkit_cache_prewarm_missed)" \
  --buildkit-cache-prewarm-body-time-seconds "$(read_output buildkit_cache_prewarm_body_time_seconds)" \
  --buildkit-cache-prewarm-body-max-seconds "$(read_output buildkit_cache_prewarm_body_max_seconds)" \
  --buildkit-cache-prewarm-resolve-time-seconds "$(read_output buildkit_cache_prewarm_resolve_time_seconds)" \
  --buildkit-cache-prewarm-resolve-max-seconds "$(read_output buildkit_cache_prewarm_resolve_max_seconds)" \
  --buildkit-cache-prewarm-upload-time-seconds "$(read_output buildkit_cache_prewarm_upload_time_seconds)" \
  --buildkit-cache-prewarm-upload-max-seconds "$(read_output buildkit_cache_prewarm_upload_max_seconds)" \
  --buildkit-cache-prewarm-queue-depth "$(read_output buildkit_cache_prewarm_queue_depth)" \
  --buildkit-cache-prewarm-max-queue-depth "$(read_output buildkit_cache_prewarm_max_queue_depth)" \
  --buildkit-cache-prewarm-body-slot-limit "$(read_output buildkit_cache_prewarm_body_slot_limit)" \
  --buildkit-cache-prewarm-body-slot-max "$(read_output buildkit_cache_prewarm_body_slot_max)" \
  --buildkit-cache-prewarm-body-active "$(read_output buildkit_cache_prewarm_body_active)" \
  --buildkit-cache-prewarm-body-active-max "$(read_output buildkit_cache_prewarm_body_active_max)" \
  --buildkit-cache-prewarm-body-scaleups "$(read_output buildkit_cache_prewarm_body_scaleups)" \
  --buildkit-cache-prewarm-body-downshifts "$(read_output buildkit_cache_prewarm_body_downshifts)" \
  --buildkit-cache-prewarm-body-backlog-reliefs "$(read_output buildkit_cache_prewarm_body_backlog_reliefs)" \
  --buildkit-cache-prewarm-cpu-pressure-seconds "$(read_output buildkit_cache_prewarm_cpu_pressure_seconds)" \
  --buildkit-cache-prewarm-io-pressure-seconds "$(read_output buildkit_cache_prewarm_io_pressure_seconds)" \
  --buildkit-cache-prewarm-body-phase "$(read_output buildkit_cache_prewarm_body_phase)" \
  --buildkit-cache-prewarm-image-output-overlap-seconds "$(read_output buildkit_cache_prewarm_image_output_overlap_seconds)" \
  --buildkit-cache-prewarm-cache-only-transitions "$(read_output buildkit_cache_prewarm_cache_only_transitions)" \
  --buildkit-cache-prewarm-slot-limit-min "$(read_output buildkit_cache_prewarm_slot_limit_min)" \
  --buildkit-cache-prewarm-slot-limit-max "$(read_output buildkit_cache_prewarm_slot_limit_max)" \
  --buildkit-cache-prewarm-body-wait-seconds "$(read_output buildkit_cache_prewarm_body_wait_seconds)" \
  --buildkit-cache-prewarm-body-wait-max-seconds "$(read_output buildkit_cache_prewarm_body_wait_max_seconds)" \
  --buildkit-cache-prewarm-workers-current "$(read_output buildkit_cache_prewarm_workers_current)" \
  --buildkit-cache-prewarm-workers-max "$(read_output buildkit_cache_prewarm_workers_max)" \
  --cache-storage-bytes "$bytes" \
  --cache-storage-source boringcache-check \
  --storage-breakdown-json "$storage_breakdown_path" \
  --bytes-uploaded "$bytes" \
  --oci-hydration-policy "$(read_output oci_hydration_policy)" \
  --oci-body-local-hits "$(read_output oci_body_local_hits)" \
  --oci-body-remote-fetches "$(read_output oci_body_remote_fetches)" \
  --oci-body-local-bytes "$(read_output oci_body_local_bytes)" \
  --oci-body-remote-bytes "$(read_output oci_body_remote_bytes)" \
  --oci-body-local-duration-ms "$(read_output oci_body_local_duration_ms)" \
  --oci-body-remote-duration-ms "$(read_output oci_body_remote_duration_ms)" \
  --startup-oci-body-inserted "$(read_output startup_oci_body_inserted)" \
  --startup-oci-body-failures "$(read_output startup_oci_body_failures)" \
  --startup-oci-body-cold-blobs "$(read_output startup_oci_body_cold_blobs)" \
  --startup-oci-body-duration-ms "$(read_output startup_oci_body_duration_ms)" \
  --oci-new-blob-count "$(read_output oci_new_blob_count)" \
  --oci-new-blob-bytes "$(read_output oci_new_blob_bytes)" \
  --oci-upload-requested-blobs "$(read_output oci_upload_requested_blobs)" \
  --oci-upload-already-present "$(read_output oci_upload_already_present)" \
  --oci-upload-batch-seconds "$(read_output oci_upload_batch_seconds)" \
  --reseed-new-blob-threshold "0" \
  --hit-behavior-note "Rolling lane: one continuous-commit build imports the prior branch/default Docker cache, exports the updated cache, and records that commit build only." \
  "${cache_summary_args[@]}" \
