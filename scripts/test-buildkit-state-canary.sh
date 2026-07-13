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

  local phase restore_status restored_generation parent generation logical_blobs logical_bytes
  local bootstrap_delta steady_delta blob_delta required_blob_delta required_blobs warm_index warm_count summary_name
  local transport_blobs transport_bytes saw_cacheonly arg
  case "$BORINGCACHE_STATE_SUMMARY_PATH" in
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
      ;;
    *rolling.state-summary.json)
      phase=rolling
      restore_status=restored
      restored_generation="$rolling_parent"
      parent="$rolling_parent"
      generation="$rolling_generation"
      logical_blobs=120
      logical_bytes=120000
      required_blobs=2
      transport_blobs=4
      transport_bytes=4000
      ;;
    *replay-*.state-summary.json)
      phase="$(basename "$BORINGCACHE_STATE_SUMMARY_PATH" .state-summary.json)"
      replay_index="${phase#replay-}"
      replay_index="${replay_index%%-*}"
      replay_index="$((10#$replay_index))"
      printf -v generation 'sha256:%064x' "$((200 + replay_index))"
      logical_blobs="$((100 + replay_index))"
      logical_bytes="$((100000 + (replay_index * 1000)))"
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
      ;;
    *)
      echo "Unexpected mock summary path: $BORINGCACHE_STATE_SUMMARY_PATH" >&2
      return 1
      ;;
  esac

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
    --argjson include_logical_generation "$(if [[ "${MOCK_OMIT_LOGICAL_GENERATION:-0}" == 1 ]]; then echo false; else echo true; fi)" \
    --arg retention_policy "${MOCK_RETENTION_POLICY:-complete-main-cache-v1}" \
    --argjson content_gc_applied "$(if [[ "${MOCK_CONTENT_GC_APPLIED:-1}" == 1 ]]; then echo true; else echo false; fi)" \
    --argjson records_after_gc "${MOCK_RECORDS_AFTER_GC:-2}" \
    --argjson include_content_gc_seconds "$(if [[ "${MOCK_OMIT_CONTENT_GC_SECONDS:-0}" == 1 ]]; then echo false; else echo true; fi)" \
    --argjson mountcache_enabled "$(if [[ "${BORINGCACHE_STATE_CANARY_COMPOSITION_MODE:-off}" == fixture ]]; then echo true; else echo false; fi)" \
    --argjson mountcache_hydrate_errors "${MOCK_MOUNTCACHE_HYDRATE_ERRORS:-0}" \
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
        content_gc_applied: $content_gc_applied,
        content_gc_duration_ms: 100,
        records_before_gc: 2,
        records_after_gc: $records_after_gc,
        seconds: 0.2
      },
      quiesce_seconds: 0.1,
      save: {
        status: "uploaded",
        generation: $generation,
        parent: (if $parent == "" then null else $parent end),
        reused_blobs: $logical_blobs,
        reused_bytes: $logical_bytes,
        uploaded_blobs: $transport_blobs,
        uploaded_bytes: $transport_bytes,
        publish_status: "published"
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
        restored_blobs: (if $mountcache_enabled and $restore_status == "restored" then 1 else 0 end),
        restored_archives: (if $mountcache_enabled and $restore_status == "restored" then 1 else 0 end),
        restored_bytes: (if $mountcache_enabled and $restore_status == "restored" then 100 else 0 end),
        generation_archives: (if $mountcache_enabled then 1 else 0 end),
        generation_bytes: (if $mountcache_enabled then 100 else 0 end),
        selected_archives: (if $mountcache_enabled then 1 else 0 end),
        hydrate_hits: (
          if $mountcache_enabled and $restore_status == "restored" and ($composition_short_circuit | not)
          then 1 else 0 end
        ),
        hydrate_misses: 0,
        hydrate_errors: $mountcache_hydrate_errors,
        hydrate_skips: 0,
        hydrated_files: (
          if $mountcache_enabled and $restore_status == "restored" and ($composition_short_circuit | not)
          then 1 else 0 end
        ),
        hydrated_compressed_bytes: (
          if $mountcache_enabled and $restore_status == "restored" and ($composition_short_circuit | not)
          then 100 else 0 end
        ),
        hydrated_uncompressed_bytes: (
          if $mountcache_enabled and $restore_status == "restored" and ($composition_short_circuit | not)
          then 200 else 0 end
        ),
        hydrate_milliseconds: 1,
        published_archives: (if $mountcache_enabled then 1 else 0 end),
        publish_errors: 0,
        published_files: (if $mountcache_enabled then 1 else 0 end),
        published_compressed_bytes: (if $mountcache_enabled then 100 else 0 end),
        published_uncompressed_bytes: (if $mountcache_enabled then 200 else 0 end),
        publish_milliseconds: 1,
        runtime_status: (if $mountcache_enabled then "recorded" else "disabled" end)
      },
      total_state_overhead_seconds: 0.4
    }
    | if $include_content_gc_seconds then .content_gc_seconds = 0.1 else . end
    | if $include_logical_generation then
        .save.logical_generation_blobs = $logical_blobs
        | .save.logical_generation_bytes = $logical_bytes
      else . end' > "$BORINGCACHE_STATE_SUMMARY_PATH"

  saw_cacheonly=0
  saw_tool_cache=0
  for arg in "$@"; do
    [[ "$arg" == type=cacheonly ]] && saw_cacheonly=1
    [[ "$arg" == turbo:* ]] && saw_tool_cache=1
  done
  [[ "$saw_cacheonly" -eq 1 ]] || {
    echo "Mock canary command omitted its cache-only product output" >&2
    return 1
  }

  if [[ "${BORINGCACHE_STATE_CANARY_COMPOSITION_MODE:-off}" == fixture && "$saw_tool_cache" -ne 1 ]]; then
    echo "Mock composition command omitted its Turbo tool cache" >&2
    return 1
  fi

  printf 'mock daemon %s\n' "$phase" > "$BORINGCACHE_MANAGED_BUILDKIT_LOG_PATH"
  if [[ "${BORINGCACHE_STATE_CANARY_COMPOSITION_MODE:-off}" == fixture ]]; then
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
  if [[ "$phase" == cold || "$phase" == replay-001-* ]]; then
    echo '#1 DONE 1.0s'
  else
    echo '#1 CACHED'
    echo '#2 CACHED'
  fi
}

export -f git docker mock_warm_generation boringcache
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
  and .phases[0].state.finalize.retention_policy == "complete-main-cache-v1"
  and .phases[0].state.finalize.content_gc_applied == true
  and .phases[0].state.finalize.content_gc_duration_ms == 100
  and .phases[0].state.finalize.records_before_gc == 2
  and .phases[0].state.finalize.records_after_gc == 2
  and .phases[0].state.finalize.records_after_gc >= .phases[0].state.finalize.eligible
  and .phases[0].state.content_gc_seconds == 0.1
' "$rolling_dir/canary-result.json" >/dev/null

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
  and .current_set.replay.all_successors_within_tolerance == true
  and (.current_set.replay.generations | length) == 11
  and .current_set.replay.generations[0].continuity == true
  and .current_set.replay.generations[1].logical_set.blob_delta_from_previous == 1
  and .current_set.replay.generations[1].transport_delta.blobs == 1
' "$replay_full_dir/canary-result.json" >/dev/null

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

composition_dir="$test_root/composition-fixture"
run_mock replay-full "$composition_dir" 2 fixture >/dev/null
command jq -e '
  .success == true
  and .inputs.composition_mode == "fixture"
  and .inputs.mountcache_enabled == true
  and .inputs.tool_env_delivery == "static-secret-fixture"
  and .composition.valid == true
  and .composition.mountcache_published == true
  and .composition.mountcache_restored == true
  and .composition.mountcache_hydrated == true
  and .composition.toolcache_exercised == true
  and .composition.toolcache_hits == true
  and all(.phases[]; .checks.tool_cache_valid == true)
' "$composition_dir/canary-result.json" >/dev/null

composition_short_circuit_dir="$test_root/composition-short-circuit"
MOCK_COMPOSITION_SHORT_CIRCUIT=1 run_mock fresh "$composition_short_circuit_dir" 2 fixture >/dev/null
command jq -e '
  . as $result
  | .success == true
  and .composition.valid == true
  and .composition.mountcache_published == true
  and .composition.mountcache_restored == true
  and .composition.mountcache_hydrated == false
  and .composition.toolcache_exercised == true
  and .composition.toolcache_hits == false
  and .composition.fully_state_cached_short_circuit == true
  and all(.phases[1:][];
    .cached_steps > $result.phases[0].cached_steps
    and .state.mount_cache.hydrate_hits == 0
    and .tool_cache.hits == 0
    and .tool_cache.misses == 0
    and .tool_cache.writes == 0
  )
' "$composition_short_circuit_dir/canary-result.json" >/dev/null

composition_mount_error_dir="$test_root/composition-mount-error"
if MOCK_MOUNTCACHE_HYDRATE_ERRORS=1 run_mock fresh "$composition_mount_error_dir" 2 fixture >/dev/null 2>&1; then
  echo "Expected mount-cache hydration errors to fail the composition canary" >&2
  exit 1
fi
command jq -e '
  .success == false
  and (.phases | length) == 1
  and .phases[0].checks.summary_valid == true
  and .phases[0].checks.mount_cache_valid == false
  and .phases[0].state.logical_generation_blobs > 0
  and .phases[0].state.logical_generation_bytes > 0
  and .phases[0].state.mount_cache.hydrate_errors == 1
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

echo "BuildKit state canary mocked lifecycle is valid."
