#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

benchmark_id="${BENCHMARK_ID:?Set BENCHMARK_ID}"
benchmark_workspace="${BENCHMARK_WORKSPACE:?Set BENCHMARK_WORKSPACE}"
backend="${BUILDKIT_BACKEND:-registry}"
cache_scope="${CACHE_SCOPE:?Set CACHE_SCOPE}"
outputs_file="${BENCHMARK_OUTPUTS_PATH:-benchmark-results/${benchmark_id}-boringcache-rolling.outputs.env}"
project_repo="${BENCHMARK_PROJECT_REPO:-PostHog/posthog}"
project_ref="${BENCHMARK_PROJECT_REF:-}"
docker_tool_cache="${BORINGCACHE_DOCKER_TOOL_CACHE:-}"

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

tool_cache_tags_csv() {
  local requested="$1"
  local tool_cache_value tool tag
  local tags=()

  for tool_cache_value in ${requested//,/ }; do
    [[ -n "$tool_cache_value" ]] || continue
    tool="${tool_cache_value%%:*}"
    if [[ "$tool_cache_value" == *:* ]]; then
      tag="${tool_cache_value#*:}"
    else
      tag="${cache_scope}-${tool}"
    fi
    [[ -n "$tag" ]] && tags+=("$tag")
  done

  local IFS=,
  printf '%s\n' "${tags[*]}"
}

if [[ -z "$project_ref" ]]; then
  project_ref="$(git rev-parse HEAD:upstream 2>/dev/null || git -C upstream rev-parse HEAD 2>/dev/null || echo unknown)"
fi

mkdir -p benchmark-storage
tool_cache_tags="$(tool_cache_tags_csv "$docker_tool_cache")"
tags_csv="$cache_scope"
if [[ -n "$tool_cache_tags" ]]; then
  tags_csv="${tags_csv},${tool_cache_tags}"
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
  --adapter oci \
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
