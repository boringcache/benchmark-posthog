#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 2
  fi
}

for name in \
  BORINGCACHE_STATE_CANARY_LANE \
  BORINGCACHE_STATE_CANARY_WORKSPACE \
  BORINGCACHE_STATE_CANARY_TAG \
  BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE \
  BORINGCACHE_STATE_CANARY_ARTIFACT_DIR \
  BORINGCACHE_API_URL; do
  require_env "$name"
done

lane="$BORINGCACHE_STATE_CANARY_LANE"
workspace="$BORINGCACHE_STATE_CANARY_WORKSPACE"
cache_tag="$BORINGCACHE_STATE_CANARY_TAG"
composition_mode="${BORINGCACHE_STATE_CANARY_COMPOSITION_MODE:-off}"
tool_cache_tag="${BORINGCACHE_STATE_CANARY_TOOL_CACHE_TAG:-}"
buildkit_image="$BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE"
artifact_dir="$BORINGCACHE_STATE_CANARY_ARTIFACT_DIR"
api_origin="$BORINGCACHE_API_URL"
dockerfile_path="${BORINGCACHE_STATE_CANARY_DOCKERFILE:-upstream/Dockerfile}"
docker_context="${BORINGCACHE_STATE_CANARY_CONTEXT:-upstream}"
docker_platform="${BORINGCACHE_STATE_CANARY_PLATFORM:-linux/amd64}"
plateau_tolerance_percent="${BORINGCACHE_STATE_CANARY_PLATEAU_TOLERANCE_PERCENT:-2}"
warm_generations="${BORINGCACHE_STATE_CANARY_WARM_GENERATIONS:-2}"
replay_plan_path="${BORINGCACHE_STATE_CANARY_REPLAY_PLAN:-}"
replay_min_cached_steps=68

if [[ "$composition_mode" == fixture && -z "${BORINGCACHE_STATE_CANARY_DOCKERFILE:-}" ]]; then
  dockerfile_path="$artifact_dir/posthog-toolcache.Dockerfile"
fi

case "$composition_mode" in
  off)
    if [[ "${BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER:-0}" =~ ^(1|true|yes|on)$ ]]; then
      echo "BuildKit mountcache offload is not part of the core state canary" >&2
      exit 2
    fi
    export BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER=0
    ;;
  fixture)
    [[ -n "$tool_cache_tag" && ! "$tool_cache_tag" =~ [[:space:]] ]] || {
      echo "Fixture composition requires one whitespace-free BORINGCACHE_STATE_CANARY_TOOL_CACHE_TAG" >&2
      exit 2
    }
    [[ "$tool_cache_tag" != "$cache_tag" ]] || {
      echo "State and Turbo composition tags must be distinct" >&2
      exit 2
    }
    [[ "${BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER:-0}" =~ ^(1|true|yes|on)$ ]] || {
      echo "Fixture composition requires BuildKit mountcache offload" >&2
      exit 2
    }
    export BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER=1
    ;;
  *)
    echo "BORINGCACHE_STATE_CANARY_COMPOSITION_MODE must be off or fixture" >&2
    exit 2
    ;;
esac

case "$lane" in
  fresh|rolling|replay-full|replay-endpoints) ;;
  *)
    echo "BORINGCACHE_STATE_CANARY_LANE must be fresh, rolling, replay-full, or replay-endpoints" >&2
    exit 2
    ;;
esac

if [[ ! "$buildkit_image" =~ ^ghcr\.io/boringcache/buildkit@sha256:[0-9a-f]{64}$ ]]; then
  echo "BuildKit image must be an exact ghcr.io/boringcache/buildkit@sha256 digest" >&2
  exit 2
fi
if [[ ! "$api_origin" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
  echo "BORINGCACHE_API_URL must be an exact HTTPS origin without a path or trailing slash" >&2
  exit 2
fi
if [[ ! "$plateau_tolerance_percent" =~ ^[0-9]+$ ]] || ((plateau_tolerance_percent > 100)); then
  echo "BuildKit state plateau tolerance must be an integer from 0 through 100" >&2
  exit 2
fi
case "$warm_generations" in
  2|4|8) ;;
  *)
    echo "BuildKit state warm generations must be 2, 4, or 8" >&2
    exit 2
    ;;
esac
for tool in boringcache docker git jq tee; do
  command -v "$tool" >/dev/null || {
    echo "Required command is unavailable: ${tool}" >&2
    exit 2
  }
done

mkdir -p "$artifact_dir"
preflight_checklist="$artifact_dir/preflight-checklist.json"
backend_preflight="$artifact_dir/preflight-backend.json"
jq -e \
  --arg api_origin "$api_origin" \
  '.all_passed == true
    and .api_origin == $api_origin
    and .state_contract.required_layout == "buildkit-state-v1"
    and .checks.backend_capabilities == true
    and .checks.backend_user_agent_exact == true
    and .checks.cli_asset_exact == true
    and .checks.buildkit_image_exact == true
    and .checks.source_target_exact == true
    and .checks.runner_disk_capacity == true
    and .checks.replay_plan_exact == true' \
  "$preflight_checklist" >/dev/null 2>&1 || {
  echo "Complete machine preflight checklist is missing or did not pass" >&2
  exit 2
}
jq -e \
  --arg api_origin "$api_origin" \
  '.all_passed == true
    and .api_origin == $api_origin
    and .state_contract.required_capability == "buildkit_state_current_set_v1"
    and .checks.expected_tag_head_v1 == true
    and .checks.buildkit_state_current_set_v1 == true' \
  "$backend_preflight" >/dev/null 2>&1 || {
  echo "Backend state capability preflight is missing or did not pass" >&2
  exit 2
}
source_sha="$(git -C "$repo_root/upstream" rev-parse HEAD)"
source_base_sha="$source_sha"
replay_all_commits='[]'
replay_selected_commits='[]'
if [[ "$lane" == replay-full || "$lane" == replay-endpoints ]]; then
  [[ -n "$replay_plan_path" && -s "$replay_plan_path" ]] || {
    echo "Replay lane requires BORINGCACHE_STATE_CANARY_REPLAY_PLAN" >&2
    exit 2
  }
  jq -e \
    --arg mode "$lane" \
    '.schema_version == "buildkit-state-canary-replay-plan.v1"
      and .mode == $mode
      and (.base_sha | test("^[0-9a-f]{40}$"))
      and (.target_sha | test("^[0-9a-f]{40}$"))
      and (.all_commits | type == "array" and length == 11)
      and all(.all_commits[]; test("^[0-9a-f]{40}$"))
      and (.all_commits[0] == .base_sha)
      and (.all_commits[-1] == .target_sha)
      and (.selected_commits | type == "array")
      and all(.selected_commits[]; test("^[0-9a-f]{40}$"))
      and (if $mode == "replay-full" then
             .selected_commits == .all_commits
           else
             (.selected_commits | length) == 2
             and .selected_commits[0] == .base_sha
             and .selected_commits[1] == .target_sha
           end)' "$replay_plan_path" >/dev/null || {
    echo "Replay plan does not match the exact 11-generation contract" >&2
    exit 2
  }
  previous_commit=""
  seen_commits=","
  while IFS= read -r commit; do
    case "$seen_commits" in
      *",${commit},"*) echo "Replay plan contains duplicate commit ${commit}" >&2; exit 2 ;;
    esac
    seen_commits+="${commit},"
    git -C "$repo_root/upstream" cat-file -e "${commit}^{commit}"
    if [[ -n "$previous_commit" ]]; then
      commit_object="$(git -C "$repo_root/upstream" cat-file -p "$commit")"
      first_parent=""
      while read -r object_field object_value _; do
        if [[ "$object_field" == parent ]]; then
          first_parent="$object_value"
          break
        fi
      done <<< "$commit_object"
      [[ "$first_parent" == "$previous_commit" ]] || {
        echo "Replay plan is not first-parent ordered at ${commit}" >&2
        exit 2
      }
    fi
    previous_commit="$commit"
  done < <(jq -r '.all_commits[]' "$replay_plan_path")
  source_base_sha="$(jq -r '.base_sha' "$replay_plan_path")"
  source_sha="$(jq -r '.target_sha' "$replay_plan_path")"
  replay_all_commits="$(jq -c '.all_commits' "$replay_plan_path")"
  replay_selected_commits="$(jq -c '.selected_commits' "$replay_plan_path")"
fi
buildkit_digest="${buildkit_image##*@}"
cli_version="$(boringcache --version 2>&1 | head -n1)"

jq -n \
  --arg schema_version "buildkit-state-canary-inputs.v1" \
  --arg lane "$lane" \
  --arg workspace "$workspace" \
  --arg cache_tag "$cache_tag" \
  --arg composition_mode "$composition_mode" \
  --arg tool_cache_tag "$tool_cache_tag" \
  --arg source_sha "$source_sha" \
  --arg source_base_sha "$source_base_sha" \
  --arg buildkit_image "$buildkit_image" \
  --arg buildkit_digest "$buildkit_digest" \
  --arg docker_platform "$docker_platform" \
  --arg dockerfile "$dockerfile_path" \
  --arg context "$docker_context" \
  --arg cli_version "$cli_version" \
  --argjson replay_all_commits "$replay_all_commits" \
  --argjson replay_selected_commits "$replay_selected_commits" \
  --argjson plateau_tolerance_percent "$plateau_tolerance_percent" \
  --argjson warm_generations "$warm_generations" \
  --argjson replay_min_cached_steps "$replay_min_cached_steps" \
  '{
    schema_version: $schema_version,
    lane: $lane,
    workspace: $workspace,
    cache_tag: $cache_tag,
    composition_mode: $composition_mode,
    tool_cache_tag: (if $tool_cache_tag == "" then null else $tool_cache_tag end),
    tool_env_delivery: (if $composition_mode == "fixture" then "static-secret-fixture" else "none" end),
    source_sha: $source_sha,
    source_base_sha: $source_base_sha,
    buildkit_image: $buildkit_image,
    buildkit_digest: $buildkit_digest,
    docker_platform: $docker_platform,
    dockerfile: $dockerfile,
    context: $context,
    cli_version: $cli_version,
    replay: (if ($replay_all_commits | length) == 0 then null else {
      all_commits: $replay_all_commits,
      selected_commits: $replay_selected_commits
    } end),
    plateau_tolerance_percent: $plateau_tolerance_percent,
    warm_generations: $warm_generations,
    replay_min_cached_steps: $replay_min_cached_steps,
    mountcache_enabled: ($composition_mode == "fixture")
  }' > "$artifact_dir/inputs.json"

mount_probe_result_path="$artifact_dir/mount-probe.result.json"
jq -n \
  --argjson enabled "$(if [[ "$composition_mode" == fixture ]]; then echo true; else echo false; fi)" \
  '{
    schema_version: "buildkit-state-mount-probe.v1",
    enabled: $enabled,
    attempted: false,
    timing_included_in_product_phases: false,
    valid: ($enabled | not)
  }' > "$mount_probe_result_path"

snapshot_managed_resources() {
  {
    docker ps -a --format 'container {{.Names}}' 2>/dev/null || true
    docker network ls --format 'network {{.Name}}' 2>/dev/null || true
    docker volume ls --format 'volume {{.Name}}' 2>/dev/null || true
    docker buildx ls --format 'builder {{.Name}}' 2>/dev/null || true
  } | awk '
    $2 ~ /^boringcache-buildkit-/ || $2 ~ /^boringcache-state-helper-/ || $2 ~ /^buildx_buildkit_boringcache-buildkit-/ { print }
  ' | LC_ALL=C sort -u
}

baseline_resources="$artifact_dir/managed-resources.before.txt"
snapshot_managed_resources > "$baseline_resources"

fresh_warm_phase_name() {
  local index="$1"
  case "$index" in
    1) printf '%s\n' same-ref-warm ;;
    2) printf '%s\n' same-ref-repeat ;;
    *) printf 'same-ref-repeat-%03d\n' "$index" ;;
  esac
}

write_combined_result() {
  local result="$artifact_dir/canary-result.json"
  local phase_files=()
  local path index phase
  if [[ "$lane" == "fresh" ]]; then
    path="$artifact_dir/cold.phase.json"
    [[ -f "$path" ]] && phase_files+=("$path")
    for ((index = 1; index <= warm_generations; index++)); do
      phase="$(fresh_warm_phase_name "$index")"
      path="$artifact_dir/${phase}.phase.json"
      [[ -f "$path" ]] && phase_files+=("$path")
    done
  else
    while IFS= read -r path; do
      phase_files+=("$path")
    done < <(find "$artifact_dir" -maxdepth 1 -name '*.phase.json' -type f | LC_ALL=C sort)
  fi

  if ((${#phase_files[@]} == 0)); then
    jq -n \
      --slurpfile inputs "$artifact_dir/inputs.json" \
      '{schema_version: "buildkit-state-canary-result.v2", inputs: $inputs[0], success: false, phases: []}' \
      > "$result"
    return
  fi

  jq -s \
    --slurpfile inputs "$artifact_dir/inputs.json" \
    --slurpfile mount_probe "$mount_probe_result_path" \
    --arg lane "$lane" \
    --argjson tolerance "$plateau_tolerance_percent" \
    --argjson warm_generations "$warm_generations" \
    --argjson replay_min_cached_steps "$replay_min_cached_steps" \
    'def absolute_delta_within_tolerance($delta; $limit):
       if (($delta | type) == "number" and ($limit | type) == "number") then
         (($delta | if . < 0 then -. else . end) <= $limit)
       else
         false
       end;
     def replay_prune_contract:
       .prune.applied == true
       and .prune.target_satisfied == true
       and .prune.target_reason == "scaffold-clean"
       and .prune.all == true
       and .prune.filter_count == 2
       and .prune.max_used_space_bytes == 0
       and .prune.keep_duration_ms == 0
       and .prune.cutoff_unix_nano == 0
       and .prune.reserved_space_bytes == 0
       and .prune.min_free_space_bytes == 0
       and .prune.effective_keep_bytes == 0
       and (.prune.records_before - .prune.records_after) == .prune.pruned_records;
    {
      phases: .,
      all_phases_valid: (length > 0 and all(.[]; .success == true))
    }
    | . as $base
    | (if $lane == "fresh" then
        ($base.phases[0] // null) as $cold
        | ($base.phases[1:] // []) as $warm_phases
        | [range(1; ($base.phases | length)) as $index
          | $base.phases[$index - 1] as $previous
          | $base.phases[$index] as $current
          | ($current.state.restore_status == "clean_start") as $clean_start_boundary
          | (if $clean_start_boundary then null else
               ($current.state.logical_generation_blobs - $previous.state.logical_generation_blobs)
             end) as $blob_delta
          | (if $clean_start_boundary then null else
               ($current.state.logical_generation_bytes - $previous.state.logical_generation_bytes)
             end) as $byte_delta
          | (if $clean_start_boundary then null else
               ($current.state.finalize.required_blobs - $previous.state.finalize.required_blobs)
             end) as $required_blob_delta
          | (($previous.state.logical_generation_blobs * $tolerance / 100) | ceil) as $blob_tolerance
          | (($previous.state.logical_generation_bytes * $tolerance / 100) | ceil) as $byte_tolerance
          | {
              transition_index: $index,
              from_phase: $previous.phase,
              to_phase: $current.phase,
              kind: (
                if $clean_start_boundary then "clean-start"
                elif $index == 1 then "bootstrap"
                else "same-ref"
                end
              ),
              clean_start_boundary: $clean_start_boundary,
              next_phase_restores_root: (
                if ($clean_start_boundary | not) then null
                elif $index >= (($base.phases | length) - 1) then false
                else
                  $base.phases[$index + 1].state.restore_status == "restored"
                  and $base.phases[$index + 1].state.restored_generation == $current.state.generation
                  and $base.phases[$index + 1].state.parent_generation == $current.state.generation
                end
              ),
              final_convergence_pair: (
                ($clean_start_boundary | not)
                and $index == (($base.phases | length) - 1)
                and $index > 1
              ),
              lineage: {
                previous_generation: $previous.state.generation,
                candidate_generation: $current.state.restore.candidate_generation,
                restored_generation: $current.state.restored_generation,
                parent_generation: $current.state.parent_generation,
                current_generation: $current.state.generation,
                valid: (
                  if $clean_start_boundary then
                    $current.checks.clean_start_valid
                    and $current.state.restore.candidate_generation == $previous.state.generation
                    and $current.state.restored_generation == null
                    and $current.state.parent_generation == null
                    and $current.state.state_window.published_generation_count == 1
                  else
                    $current.state.restore_status == "restored"
                    and $current.state.restored_generation == $previous.state.generation
                    and $current.state.parent_generation == $previous.state.generation
                  end
                )
              },
              current_head_only: (
                $current.state.head_generations_fetched == 1
                and $current.checks.current_head_only
              ),
              solver_reuse: (
                if $clean_start_boundary then null else
                  $current.cached_steps > $cold.cached_steps
                  and $current.executed_steps < $cold.executed_steps
                end
              ),
              record_set: {
                previous_eligible: $previous.state.finalize.eligible,
                current_eligible: $current.state.finalize.eligible,
                eligible_delta: (
                  if $clean_start_boundary then null else
                    ($current.state.finalize.eligible - $previous.state.finalize.eligible)
                  end
                ),
                previous_records_after_gc: $previous.state.finalize.records_after_gc,
                current_records_after_gc: $current.state.finalize.records_after_gc,
                records_after_gc_delta: (
                  if $clean_start_boundary then null else
                    $current.state.finalize.records_after_gc
                    - $previous.state.finalize.records_after_gc
                  end
                )
              },
              replacement_transport: {
                uploaded_blobs: $current.state.transport_delta_blobs,
                uploaded_bytes: $current.state.transport_delta_bytes,
                materialized_records: $current.state.finalize.materialized,
                observed: ($current.state.transport_delta_blobs > 0)
              },
              logical_set: {
                previous_blobs: $previous.state.logical_generation_blobs,
                previous_bytes: $previous.state.logical_generation_bytes,
                current_blobs: $current.state.logical_generation_blobs,
                current_bytes: $current.state.logical_generation_bytes,
                previous_required_blobs: $previous.state.finalize.required_blobs,
                current_required_blobs: $current.state.finalize.required_blobs,
                blob_delta: $blob_delta,
                byte_delta: $byte_delta,
                required_blob_delta: $required_blob_delta,
                blob_delta_percent: (
                  if $clean_start_boundary or $previous.state.logical_generation_blobs == 0 then null
                  else (($blob_delta * 10000 / $previous.state.logical_generation_blobs) | round) / 100
                  end
                ),
                byte_delta_percent: (
                  if $clean_start_boundary or $previous.state.logical_generation_bytes == 0 then null
                  else (($byte_delta * 10000 / $previous.state.logical_generation_bytes) | round) / 100
                  end
                ),
                blob_tolerance: $blob_tolerance,
                byte_tolerance: $byte_tolerance,
                within_tolerance: (
                  if $clean_start_boundary then null else
                    $blob_delta == 0
                    and $required_blob_delta == 0
                    and absolute_delta_within_tolerance($byte_delta; $byte_tolerance)
                  end
                ),
                positive_growth_within_tolerance: (
                  if $clean_start_boundary then null else
                    $blob_delta == 0
                    and $required_blob_delta == 0
                    and $byte_delta <= $byte_tolerance
                  end
                )
              }
            }
        ] as $transitions
        | ($transitions[0] // null) as $bootstrap
        | ($transitions[-1] // null) as $final_transition
        | ([$transitions[] | select(.clean_start_boundary) | .transition_index] | max // 0) as $last_clean_start_index
        | ([$last_clean_start_index, 1] | max) as $plateau_floor_index
        | [$transitions[] | select(.clean_start_boundary)] as $clean_start_transitions
        | [$transitions[]
            | select(.transition_index > $plateau_floor_index)
            | select(.clean_start_boundary | not)
          ] as $plateau_transitions
        | [$transitions[] | select(.clean_start_boundary | not)] as $solver_transitions
        | (all($clean_start_transitions[];
            .lineage.valid and .next_phase_restores_root == true
          )) as $clean_start_followup_proven
        | ($warm_phases[0] // null) as $warm
        | ($warm_phases[1] // null) as $repeat
        | ((($warm_phases | length) == $warm_generations)
            and ($solver_transitions | length) > 0
            and all($solver_transitions[]; .solver_reuse == true)
          ) as $all_warm_solver_reuse
        | (all($plateau_transitions[];
            .logical_set.blob_delta == 0
            and .logical_set.required_blob_delta == 0
          )) as $all_warm_content_counts_stable
        | (all($plateau_transitions[];
            .record_set.eligible_delta == 0
            and .record_set.records_after_gc_delta == 0
          )) as $all_warm_record_counts_stable
        | (if ($bootstrap.clean_start_boundary // false) then true else
            (($bootstrap.record_set.eligible_delta | type) == "number")
            and $bootstrap.record_set.eligible_delta == 0
            and (($bootstrap.record_set.records_after_gc_delta | type) == "number")
            and $bootstrap.record_set.records_after_gc_delta <= 0
          end) as $bootstrap_record_count_non_growing
        | ([
            $transitions[].replacement_transport.uploaded_blobs
          ] | add // 0) as $warm_uploaded_blobs
        | ([
            $transitions[].replacement_transport.uploaded_bytes
          ] | add // 0) as $warm_uploaded_bytes
        | {
            current_set_replacement: (
              $cold != null
              and $warm != null
              and $repeat != null
              and ($base.phases | length) == ($warm_generations + 1)
              and $cold.state.logical_generation_blobs > 0
              and $cold.state.logical_generation_bytes > 0
              and all($transitions[];
                .lineage.valid
                and .current_head_only
                and .logical_set.current_blobs > 0
                and .logical_set.current_bytes > 0
              )
              and $clean_start_followup_proven
              and ($plateau_transitions | length) > 0
              and (
                ($clean_start_transitions | length) > 0
                or $bootstrap.logical_set.positive_growth_within_tolerance
              )
              and $all_warm_content_counts_stable
              and $bootstrap_record_count_non_growing
              and $all_warm_record_counts_stable
              and $final_transition.final_convergence_pair
              and $final_transition.logical_set.within_tolerance
            ),
            only_current_head_fetched: (
              ($warm_phases | length) == $warm_generations
              and all($warm_phases[];
                .state.head_generations_fetched == 1
                and .checks.current_head_only
              )
            ),
            warm_generations_planned: $warm_generations,
            warm_generations_measured: ($warm_phases | length),
            clean_start_boundaries: ($clean_start_transitions | length),
            clean_start_followup_proven: $clean_start_followup_proven,
            plateau_window_start_transition: ($plateau_floor_index + 1),
            plateau_transitions_measured: ($plateau_transitions | length),
            bootstrap_record_count_non_growing: $bootstrap_record_count_non_growing,
            bootstrap_records_after_gc_delta: $bootstrap.record_set.records_after_gc_delta,
            all_warm_content_counts_stable: $all_warm_content_counts_stable,
            all_warm_record_counts_stable: $all_warm_record_counts_stable,
            same_ref_record_growth_observed: ($all_warm_record_counts_stable | not),
            same_ref_replacement_uploads_observed: ($warm_uploaded_blobs > 0),
            same_ref_replacement_uploaded_blobs: $warm_uploaded_blobs,
            same_ref_replacement_uploaded_bytes: $warm_uploaded_bytes,
            same_ref_count_plateau: (
              $clean_start_followup_proven
              and ($plateau_transitions | length) > 0
              and
              $all_warm_content_counts_stable
              and $all_warm_record_counts_stable
              and ($final_transition.logical_set.within_tolerance // false)
            ),
            same_ref_plateau: (
              $clean_start_followup_proven
              and ($plateau_transitions | length) > 0
              and
              $all_warm_content_counts_stable
              and $all_warm_record_counts_stable
              and ($final_transition.logical_set.within_tolerance // false)
            ),
            same_ref_solver_reuse: $all_warm_solver_reuse,
            same_ref_first_warm_solver_reuse: ($transitions[0].solver_reuse // false),
            same_ref_repeat_solver_reuse: ($transitions[1].solver_reuse // false),
            transitions: $transitions,
            growth: {
              tolerance_percent: $tolerance,
              bootstrap_reset_by_clean_start: ($bootstrap.clean_start_boundary // false),
              bootstrap_logical_blob_delta: $bootstrap.logical_set.blob_delta,
              bootstrap_logical_byte_delta: $bootstrap.logical_set.byte_delta,
              bootstrap_required_blob_delta: $bootstrap.logical_set.required_blob_delta,
              bootstrap_records_after_gc_delta: $bootstrap.record_set.records_after_gc_delta,
              bootstrap_record_count_non_growing: $bootstrap_record_count_non_growing,
              bootstrap_blob_growth_within_tolerance: (
                if ($bootstrap.clean_start_boundary // false) then true else
                  (($bootstrap.logical_set.blob_delta | type) == "number")
                  and ($bootstrap.logical_set.blob_delta == 0)
                  and (($bootstrap.logical_set.required_blob_delta | type) == "number")
                  and ($bootstrap.logical_set.required_blob_delta == 0)
                end
              ),
              bootstrap_bytes_growth_within_tolerance: (
                if ($bootstrap.clean_start_boundary // false) then true else
                  (($bootstrap.logical_set.byte_delta | type) == "number")
                  and (($bootstrap.logical_set.byte_tolerance | type) == "number")
                  and ($bootstrap.logical_set.byte_delta <= $bootstrap.logical_set.byte_tolerance)
                end
              ),
              logical_blob_delta: $final_transition.logical_set.blob_delta,
              logical_byte_delta: $final_transition.logical_set.byte_delta,
              required_blob_delta: $final_transition.logical_set.required_blob_delta,
              blob_count_within_tolerance: ($final_transition.logical_set.blob_delta == 0),
              required_blob_count_stable: ($final_transition.logical_set.required_blob_delta == 0),
              all_warm_content_counts_stable: $all_warm_content_counts_stable,
              bytes_within_tolerance: absolute_delta_within_tolerance(
                $final_transition.logical_set.byte_delta;
                $final_transition.logical_set.byte_tolerance
              )
            }
          }
      elif $lane == "rolling" then
        ($base.phases | map(select(.phase == "rolling"))[0]) as $rolling
        | {
            current_set_replacement: (
              $rolling != null
              and $rolling.state.logical_generation_blobs > 0
              and $rolling.state.logical_generation_bytes > 0
              and $rolling.checks.current_head_only
              and $rolling.state.restore_status != "clean_start"
              and (
                ($rolling.state.restore_status == "miss" and $rolling.state.parent_generation == null)
                or (
                  $rolling.state.restore_status == "restored"
                  and $rolling.state.parent_generation == $rolling.state.restored_generation
                )
              )
            ),
            only_current_head_fetched: ($rolling.checks.current_head_only),
            clean_start_boundaries: (if $rolling.state.restore_status == "clean_start" then 1 else 0 end),
            clean_start_followup_proven: (if $rolling.state.restore_status == "clean_start" then false else null end),
            clean_start_followup_pending: ($rolling.state.restore_status == "clean_start"),
            ready_for_graduation: ($rolling.state.restore_status != "clean_start"),
            same_ref_plateau: null,
            same_ref_solver_reuse: null,
            growth: null
          }
      else
        ($base.phases) as $phases
        | [range(0; ($phases | length)) as $index
          | $phases[$index] as $phase
          | (if $index == 0 then null else $phases[$index - 1] end) as $previous
          | ($phase.state.restore_status == "clean_start") as $clean_start_boundary
          | (if $previous == null or $clean_start_boundary then null else
               ($phase.state.logical_generation_blobs - $previous.state.logical_generation_blobs)
             end) as $blob_delta
          | (if $previous == null or $clean_start_boundary then null else
               ($phase.state.logical_generation_bytes - $previous.state.logical_generation_bytes)
             end) as $byte_delta
          | (if $previous == null or $clean_start_boundary then null else
               ($phase.state.finalize.required_blobs - $previous.state.finalize.required_blobs)
             end) as $required_blob_delta
          | (if $previous == null or $clean_start_boundary then null else
               ($phase.state.finalize.eligible - $previous.state.finalize.eligible)
             end) as $eligible_delta
          | (if $previous == null or $clean_start_boundary then null else
               ($phase.state.finalize.records_after_gc - $previous.state.finalize.records_after_gc)
             end) as $records_after_gc_delta
          | (if $previous == null or $clean_start_boundary then null else
               (($blob_delta | if . < 0 then -. else . end) <=
                 ((($previous.state.logical_generation_blobs * $tolerance / 100)) | ceil))
             end) as $blob_plateau
          | (if $previous == null or $clean_start_boundary then null else
               (($byte_delta | if . < 0 then -. else . end) <=
                 ((($previous.state.logical_generation_bytes * $tolerance / 100)) | ceil))
             end) as $byte_plateau
          | {
              sequence_index: ($index + 1),
              phase: $phase.phase,
              source_sha: $phase.source_sha,
              generation: $phase.state.generation,
              restored_generation: $phase.state.restored_generation,
              parent_generation: $phase.state.parent_generation,
              clean_start_boundary: $clean_start_boundary,
              next_phase_restores_root: (
                if ($clean_start_boundary | not) then null
                elif $index >= (($phases | length) - 1) then false
                else
                  $phases[$index + 1].state.restore_status == "restored"
                  and $phases[$index + 1].state.restored_generation == $phase.state.generation
                  and $phases[$index + 1].state.parent_generation == $phase.state.generation
                end
              ),
              current_head_only: $phase.checks.current_head_only,
              build: {
                cached_steps: $phase.cached_steps,
                executed_steps: $phase.executed_steps,
                minimum_cached_steps: $replay_min_cached_steps,
                hit_contract_satisfied: (
                  if $index == 0 or $clean_start_boundary then null
                  else $phase.cached_steps >= $replay_min_cached_steps
                  end
                )
              },
              continuity: (
                if $clean_start_boundary then
                  $phase.checks.clean_start_valid
                  and $phase.state.restored_generation == null
                  and $phase.state.parent_generation == null
                  and $phase.state.state_window.published_generation_count == 1
                  and (
                    $previous == null
                    or $phase.state.restore.candidate_generation == $previous.state.generation
                  )
                elif $previous == null then
                  $phase.state.restore_status == "miss"
                  and $phase.state.parent_generation == null
                  and $phase.state.head_generations_fetched == 0
                else
                  $phase.state.restore_status == "restored"
                  and $phase.state.head_generations_fetched == 1
                  and $phase.state.restored_generation == $previous.state.generation
                  and $phase.state.parent_generation == $previous.state.generation
                end
              ),
              logical_set: {
                blobs: $phase.state.logical_generation_blobs,
                bytes: $phase.state.logical_generation_bytes,
                required_blobs: $phase.state.finalize.required_blobs,
                blob_delta_from_previous: $blob_delta,
                byte_delta_from_previous: $byte_delta,
                required_blob_delta_from_previous: $required_blob_delta,
                blob_delta_percent: (
                  if $previous == null or $clean_start_boundary or $previous.state.logical_generation_blobs == 0 then null
                  else (($blob_delta * 10000 / $previous.state.logical_generation_blobs) | round) / 100
                  end
                ),
                byte_delta_percent: (
                  if $previous == null or $clean_start_boundary or $previous.state.logical_generation_bytes == 0 then null
                  else (($byte_delta * 10000 / $previous.state.logical_generation_bytes) | round) / 100
                  end
                ),
                within_previous_tolerance: (
                  if $previous == null or $clean_start_boundary then null else ($blob_plateau and $byte_plateau) end
                )
              },
              record_set: {
                eligible: $phase.state.finalize.eligible,
                records_after_gc: $phase.state.finalize.records_after_gc,
                eligible_delta_from_previous: $eligible_delta,
                records_after_gc_delta_from_previous: $records_after_gc_delta
              },
              transport_delta: {
                blobs: $phase.state.transport_delta_blobs,
                bytes: $phase.state.transport_delta_bytes
              },
              prune: {
                retention_source: $phase.state.finalize.retention_source,
                baseline_bytes: $phase.state.finalize.retention_disk_usage_baseline_bytes,
                applied: $phase.state.finalize.prune_applied,
                triggered: $phase.state.finalize.prune_triggered,
                target_satisfied: $phase.state.finalize.prune_target_satisfied,
                target_reason: $phase.state.finalize.prune_target_reason,
                all: $phase.state.finalize.prune_all,
                filter_count: $phase.state.finalize.prune_filter_count,
                max_used_space_bytes: $phase.state.finalize.prune_max_used_space_bytes,
                duration_ms: $phase.state.finalize.prune_duration_ms,
                pruned_records: $phase.state.finalize.pruned_records,
                pruned_bytes: $phase.state.finalize.pruned_bytes,
                records_before: $phase.state.finalize.records_before_prune,
                records_after: $phase.state.finalize.records_after_prune,
                keep_duration_ms: $phase.state.finalize.prune_keep_duration_ms,
                cutoff_unix_nano: $phase.state.finalize.prune_cutoff_unix_nano,
                cache_usage_before_bytes: $phase.state.finalize.prune_cache_usage_before_bytes,
                cache_usage_after_bytes: $phase.state.finalize.prune_cache_usage_after_bytes,
                disk_total_bytes: $phase.state.finalize.prune_disk_total_bytes,
                disk_free_before_bytes: $phase.state.finalize.prune_disk_free_before_bytes,
                disk_free_after_bytes: $phase.state.finalize.prune_disk_free_after_bytes,
                disk_available_before_bytes: $phase.state.finalize.prune_disk_available_before_bytes,
                disk_available_after_bytes: $phase.state.finalize.prune_disk_available_after_bytes,
                reserved_space_bytes: $phase.state.finalize.prune_reserved_space_bytes,
                min_free_space_bytes: $phase.state.finalize.prune_min_free_space_bytes,
                effective_keep_bytes: $phase.state.finalize.prune_effective_keep_bytes
              }
            }
        ] as $observations
        | ($inputs[0].replay.selected_commits | length) as $selected_count
        | ($observations[0:$selected_count]) as $generations
        | ($observations[$selected_count] // null) as $repeat
        | (($observations | length) == ($selected_count + 1)
            and ($generations | length) == $selected_count
          ) as $sequence_shape_valid
        | (($generations | map(.source_sha)) == $inputs[0].replay.selected_commits) as $exact_source_sequence
        | ($repeat != null
            and $repeat.source_sha == $generations[-1].source_sha
          ) as $repeat_same_source
        | ($repeat != null
            and ($repeat.clean_start_boundary | not)
            and $repeat.continuity
            and $repeat.current_head_only
            and $repeat.logical_set.blobs > 0
            and $repeat.logical_set.bytes > 0
            and $repeat.logical_set.blob_delta_from_previous == 0
            and $repeat.logical_set.required_blob_delta_from_previous == 0
            and $repeat.logical_set.within_previous_tolerance == true
            and $repeat.record_set.eligible_delta_from_previous == 0
            and $repeat.record_set.records_after_gc_delta_from_previous == 0
            and ($repeat | replay_prune_contract)
          ) as $repeat_state_contract
        | ($repeat != null
            and $repeat.build.hit_contract_satisfied == true
          ) as $repeat_solver_reuse
        | ([$generations[] | select(.clean_start_boundary) | .sequence_index] | max // 1) as $replay_window_start
        | [$observations[] | select(.clean_start_boundary)] as $clean_start_generations
        | [$generations[]
            | select(.sequence_index > $replay_window_start)
            | select(.clean_start_boundary | not)
          ] as $active_successors
        | [$generations[]
            | select(.sequence_index > 1)
            | select(.clean_start_boundary | not)
          ] as $restored_successors
        | (all($clean_start_generations[];
            .continuity and .next_phase_restores_root == true
          )) as $clean_start_followup_proven
        | ($generations[-1].logical_set.bytes // 0) as $final_logical_core_bytes
        | ($generations[0].logical_set.bytes // 0) as $first_logical_core_bytes
        | (all($observations[];
            .prune.baseline_bytes == ([.prune.cache_usage_after_bytes, 1] | max)
          )) as $post_clean_baselines_valid
        | (all($observations[];
            .prune.retention_source == "post-clean-measured"
          )) as $retention_sources_valid
        | ([$generations[]
            | select(.prune.triggered and .prune.pruned_records > 0)
          ]) as $scaffold_prune_generations
        | ([$observations[]
            | select(.prune.triggered and .prune.pruned_records > 0)
          ]) as $scaffold_prune_phases
        | (all($observations[]; replay_prune_contract)) as $all_prune_contracts_valid
        | (($restored_successors | length) > 0
            and all($restored_successors[]; .build.hit_contract_satisfied == true)
          ) as $all_restored_successors_hit_contract
        | ($sequence_shape_valid
            and $exact_source_sequence
            and $repeat_same_source
            and $repeat_state_contract
            and $clean_start_followup_proven
            and $post_clean_baselines_valid
            and $retention_sources_valid
            and $all_prune_contracts_valid
            and ($scaffold_prune_phases | length) == ($observations | length)
            and all($observations[];
              .continuity
              and .current_head_only
              and .logical_set.blobs > 0
              and .logical_set.bytes > 0)
          ) as $state_correctness_valid
        | {
            current_set_replacement: $state_correctness_valid,
            only_current_head_fetched: all($observations[]; .current_head_only),
            exact_source_sequence: $exact_source_sequence,
            clean_start_boundaries: ($clean_start_generations | length),
            clean_start_followup_proven: $clean_start_followup_proven,
            same_ref_plateau: null,
            same_ref_solver_reuse: null,
            growth: null,
            replay: {
              mode: $lane,
              planned_generations: ($inputs[0].replay.all_commits | length),
              measured_generations: ($generations | length),
              tolerance_percent: $tolerance,
              plateau_window_start_sequence: $replay_window_start,
              active_successors_measured: ($active_successors | length),
              clean_start_free: (($clean_start_generations | length) == 0),
              post_clean_baselines_valid: $post_clean_baselines_valid,
              retention_sources_valid: $retention_sources_valid,
              all_prune_contracts_valid: $all_prune_contracts_valid,
              scaffold_prune_generations: ($scaffold_prune_generations | length),
              scaffold_prune_phases: ($scaffold_prune_phases | length),
              scaffold_prune_observed: (($scaffold_prune_phases | length) > 0),
              minimum_cached_steps: $replay_min_cached_steps,
              restored_successors_measured: ($restored_successors | length),
              all_restored_successors_hit_contract: $all_restored_successors_hit_contract,
              minimum_observed_successor_cached_steps: (
                [$restored_successors[].build.cached_steps] | min // 0
              ),
              changed_source_telemetry: {
                correctness_gate: false,
                restored_successors_measured: ($restored_successors | length),
                all_hit_floor_satisfied: $all_restored_successors_hit_contract,
                minimum_observed_cached_steps: (
                  [$restored_successors[].build.cached_steps] | min // 0
                ),
                all_logical_sets_within_tolerance: all(
                  $active_successors[];
                  .logical_set.within_previous_tolerance == true
                )
              },
              growth_observation: {
                first_logical_core_bytes: $first_logical_core_bytes,
                final_logical_core_bytes: $final_logical_core_bytes,
                delta_bytes: ($final_logical_core_bytes - $first_logical_core_bytes)
              },
              repeat: (
                if $repeat == null then
                  {
                    measured: false,
                    same_source: false,
                    state_contract_satisfied: false,
                    solver_reuse_proven: false,
                    contract_satisfied: false
                  }
                else
                  $repeat + {
                    measured: true,
                    same_source: $repeat_same_source,
                    state_contract_satisfied: $repeat_state_contract,
                    solver_reuse_proven: $repeat_solver_reuse,
                    contract_satisfied: ($repeat_state_contract and $repeat_solver_reuse)
                  }
                end
              ),
              ready_for_graduation: (
                if $lane == "replay-full" then
                  $state_correctness_valid and $repeat_solver_reuse
                else
                  null
                end
              ),
              all_successors_within_tolerance: all(
                $active_successors[];
                .logical_set.within_previous_tolerance == true
              ),
              generations: $generations
            }
          }
      end) as $current_set
    | ($mount_probe[0]) as $terminal_mount_probe
    | {
        valid: all($base.phases[]; .backend_current_set.head_valid == true),
        all_phases_valid: all($base.phases[]; .backend_current_set.head_valid == true),
        retention_converged: all($base.phases[]; .backend_current_set.retention_converged == true),
        all_phases_retention_converged: all($base.phases[]; .backend_current_set.retention_converged == true),
        max_active_versions: ([ $base.phases[].backend_current_set.active_versions ] | max // 0),
        max_active_storage_bytes: ([ $base.phases[].backend_current_set.active_storage_bytes ] | max // 0),
        phases: [ $base.phases[] | {
          phase,
          expected_generation: .backend_current_set.expected_generation,
          observed_generation: .backend_current_set.observed_generation,
          active_versions: .backend_current_set.active_versions,
          active_storage_bytes: .backend_current_set.active_storage_bytes,
          current_entry_bytes: .backend_current_set.current_entry_bytes,
          head_valid: .backend_current_set.head_valid,
          retention_converged: .backend_current_set.retention_converged,
          valid: .backend_current_set.valid
        } ]
      } as $backend_current
    | ($current_set
        | .backend_current_head_set = $backend_current.valid
        | .backend_current_version_set = $backend_current.retention_converged
        | .current_set_replacement = (.current_set_replacement and $backend_current.valid)
        | if (.replay | type) == "object" then
            .replay.backend_retention_converged = $backend_current.retention_converged
            | .replay.ready_for_graduation = (
                .replay.ready_for_graduation and $backend_current.valid
              )
          else
            .
          end
      ) as $audited_current_set
    | (if $inputs[0].composition_mode == "fixture" then
        {
          mode: "fixture",
          tool_env_delivery: $inputs[0].tool_env_delivery,
          bootstrap_only: all(
            $base.phases[];
            .state.restore_status == "miss"
          ),
          mountcache_published: any(
            $base.phases[];
            ((.state.mount_cache.published_archives // 0) > 0)
          ),
          signed_refs_available: (
            any(
              $base.phases[];
              .state.restore_status == "restored"
              and ((.state.mount_cache.available_archives // 0) > 0)
              and ((.state.mount_cache.available_bytes // 0) > 0)
            )
            or (($terminal_mount_probe.signed_ref_archives // 0) > 0)
          ),
          zero_eager_mount_restore: all(
            $base.phases[];
            (.state.mount_cache.restored_blobs // 0) == 0
            and (.state.mount_cache.restored_archives // 0) == 0
            and (.state.mount_cache.restored_bytes // 0) == 0
          ),
          generation_refs_bounded: all(
            $base.phases[];
            (.state.mount_cache.generation_archives // -1)
              == (.state.mount_cache.selected_archives // -2)
            and (.state.mount_cache.generation_archives // 0) > 0
          ),
          deferred_publish_lifecycle: all(
            $base.phases[];
            (.state.mount_cache.aborted_archives // -1) == 0
            and (.state.mount_cache.staged_archives // -1)
              == (.state.mount_cache.released_archives // -2)
            and (.state.mount_cache.staged_archives // -1)
              == (.state.mount_cache.published_archives // -2)
          ),
          mountcache_hydrated: (($terminal_mount_probe.hydrate_hits // 0) > 0),
          toolcache_exercised: any(
            $base.phases[];
            (((.tool_cache.hits // 0) + (.tool_cache.misses // 0) + (.tool_cache.writes // 0)) > 0)
          ),
          toolcache_hits: any(
            $base.phases[];
            ((.tool_cache.hits // 0) > 0)
          ),
          fully_state_cached_short_circuit: any(
            $base.phases[];
            .state.restore_status == "restored"
            and .cached_steps > ($base.phases[0].cached_steps // 0)
            and (
              ((.tool_cache.hits // 0)
               + (.tool_cache.misses // 0)
               + (.tool_cache.writes // 0)) == 0
            )
            and (
              ((.state.mount_cache.hydrate_hits // 0)
               + (.state.mount_cache.hydrate_misses // 0)
               + (.state.mount_cache.hydrate_errors // 0)) == 0
            )
          )
        }
        | .valid = (
            .mountcache_published
            and .signed_refs_available
            and .zero_eager_mount_restore
            and .generation_refs_bounded
            and .deferred_publish_lifecycle
            and $terminal_mount_probe.valid
            and .toolcache_exercised
            and (
              .bootstrap_only
              or .fully_state_cached_short_circuit
              or (.toolcache_hits and .mountcache_hydrated)
            )
          )
      else
        {
          mode: "off",
          tool_env_delivery: "none",
          bootstrap_only: false,
          mountcache_published: false,
          signed_refs_available: false,
          zero_eager_mount_restore: true,
          generation_refs_bounded: true,
          deferred_publish_lifecycle: true,
          mountcache_hydrated: false,
          toolcache_exercised: false,
          toolcache_hits: false,
          fully_state_cached_short_circuit: false,
          valid: true
        }
      end) as $composition
    | {
        schema_version: "buildkit-state-canary-result.v2",
        inputs: $inputs[0],
        success: (
          $base.all_phases_valid
          and $audited_current_set.current_set_replacement
          and ($audited_current_set.clean_start_followup_pending != true)
          and $audited_current_set.only_current_head_fetched
          and ($audited_current_set.exact_source_sequence != false)
          and ($audited_current_set.same_ref_solver_reuse != false)
          and $backend_current.valid
          and (if $lane == "replay-full" then
                 $audited_current_set.replay.ready_for_graduation
               else
                 true
               end)
          and $composition.valid
        ),
        current_set: $audited_current_set,
        backend_current_set: $backend_current,
        composition: $composition,
        terminal_mount_probe: $terminal_mount_probe,
        phases: $base.phases
      }' "${phase_files[@]}" > "$result"
}

audit_backend_current_set() {
  local phase="$1"
  local expected_generation="$2"
  local expected_bytes="$3"
  local result_path="$4"
  local inspect_path attempt started finished command_status head_valid retention_converged
  local max_attempts="${BORINGCACHE_STATE_CANARY_BACKEND_AUDIT_MAX_ATTEMPTS:-30}"
  case "$max_attempts" in
    ''|*[!0-9]*|0) max_attempts=30 ;;
  esac
  ((max_attempts <= 60)) || max_attempts=60
  inspect_path="$artifact_dir/${phase}.backend-current-set-inspect.json"
  [[ "$expected_generation" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "State generation is unavailable for the backend current-set audit in ${phase}" >&2
    return 1
  }
  [[ "$expected_bytes" =~ ^[1-9][0-9]*$ ]] || {
    echo "State logical bytes are unavailable for the backend current-set audit in ${phase}" >&2
    return 1
  }

  started="$(date +%s)"
  head_valid=false
  retention_converged=false
  command_status=1
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    set +e
    BORINGCACHE_STATE_CANARY_EXPECTED_BACKEND_GENERATION="$expected_generation" \
      BORINGCACHE_STATE_CANARY_EXPECTED_BACKEND_BYTES="$expected_bytes" \
      boringcache inspect "$workspace" "$cache_tag" --json > "$inspect_path"
    command_status=$?
    set -e
    if [[ "$command_status" -eq 0 ]] && jq -e \
      --arg workspace "$workspace" \
      --arg tag "$cache_tag" \
      --arg generation "$expected_generation" \
      --argjson expected_bytes "$expected_bytes" '
        .workspace.slug == $workspace
        and .identifier.query == $tag
        and .identifier.matched_by == "tag"
        and .entry.status == "ready"
        and .entry.storage_mode == "cas"
        and .entry.cas_layout == "buildkit-state-v1"
        and .entry.manifest_root_digest == $generation
        and .entry.stored_size_bytes == $expected_bytes
        and .entry.blob_count > 0
        and .entry.blob_total_size_bytes == .entry.stored_size_bytes
        and .versions.tag == $tag
        and .versions.version_count >= 1
        and .versions.current == true
        and .versions.total_storage_bytes >= .entry.stored_size_bytes
      ' "$inspect_path" >/dev/null 2>&1; then
      head_valid=true
      break
    fi
    if ((attempt < max_attempts)); then
      sleep 2
    fi
  done
  finished="$(date +%s)"
  if ((attempt > max_attempts)); then
    attempt="$max_attempts"
  fi

  [[ -s "$inspect_path" ]] || printf '{}\n' > "$inspect_path"
  if [[ "$head_valid" == true ]] && jq -e '
    .versions.version_count == 1
    and .versions.total_storage_bytes == .entry.stored_size_bytes
  ' "$inspect_path" >/dev/null 2>&1; then
    retention_converged=true
  fi
  jq -n \
    --arg expected_generation "$expected_generation" \
    --argjson expected_bytes "$expected_bytes" \
    --argjson attempts "$attempt" \
    --argjson elapsed_seconds "$((finished - started))" \
    --argjson command_status "$command_status" \
    --argjson head_valid "$head_valid" \
    --argjson retention_converged "$retention_converged" \
    --slurpfile inspection "$inspect_path" '
      {
        schema_version: "buildkit-state-backend-current-set.v1",
        attempted: true,
        expected_generation: $expected_generation,
        expected_bytes: $expected_bytes,
        attempts: $attempts,
        elapsed_seconds: $elapsed_seconds,
        command_status: $command_status,
        active_versions: ($inspection[0].versions.version_count // null),
        active_storage_bytes: ($inspection[0].versions.total_storage_bytes // null),
        current_entry_bytes: ($inspection[0].entry.stored_size_bytes // null),
        current_entry_blob_count: ($inspection[0].entry.blob_count // null),
        observed_generation: ($inspection[0].entry.manifest_root_digest // null),
        current: ($inspection[0].versions.current // false),
        head_valid: $head_valid,
        retention_converged: $retention_converged,
        valid: $head_valid
      }
    ' > "$result_path"

  if [[ "$head_valid" != true ]]; then
    echo "Backend did not expose the exact current BuildKit state generation in ${phase}" >&2
    return 1
  fi
}

trap write_combined_result EXIT

run_phase() {
  local phase="$1"
  local metadata_phase="$2"
  local source_scenario="$3"
  local expected_source_sha="$4"
  local expectation="$5"
  local log_path="$artifact_dir/${phase}.build.log"
  local daemon_log_path="$artifact_dir/${phase}.buildkitd.log"
  local observability_path="$artifact_dir/${phase}.observability.jsonl"
  local state_summary_path="$artifact_dir/${phase}.state-summary.json"
  local phase_result_path="$artifact_dir/${phase}.phase.json"
  local backend_current_set_result_path="$artifact_dir/${phase}.backend-current-set.json"
  local resources_after="$artifact_dir/${phase}.managed-resources.after.txt"
  local resources_leaked="$artifact_dir/${phase}.managed-resources.leaked.txt"

  git -C "$repo_root/upstream" checkout --detach "$expected_source_sha"
  "$repo_root/scripts/prepare-source.sh" "$source_scenario"
  local prepared_sha
  prepared_sha="$(git -C "$repo_root/upstream" rev-parse HEAD)"
  if [[ "$prepared_sha" != "$expected_source_sha" ]]; then
    echo "Prepared source moved from ${expected_source_sha} to ${prepared_sha}" >&2
    return 1
  fi
  if [[ "$composition_mode" == fixture ]]; then
    "$repo_root/scripts/render-posthog-toolcache-dockerfile.sh" "$dockerfile_path"
  fi

  rm -f \
    "$log_path" \
    "$daemon_log_path" \
    "$observability_path" \
    "$state_summary_path" \
    "$phase_result_path" \
    "$backend_current_set_result_path" \
    "$resources_after" \
    "$resources_leaked"

  local phase_started phase_finished command_status tee_status
  local composition_args=(--metadata-hint "composition=${composition_mode}")
  local product_target_args=(--progress plain)
  if [[ "$composition_mode" == fixture ]]; then
    composition_args=(--tool-cache "turbo:${tool_cache_tag}" "${composition_args[@]}")
    product_target_args+=(--target posthog-runtime)
  fi
  phase_started="$(date +%s)"
  local command_statuses=()
  set +e
  BORINGCACHE_STATE_SUMMARY_PATH="$state_summary_path" \
    BORINGCACHE_MANAGED_BUILDKIT_LOG_PATH="$daemon_log_path" \
    BORINGCACHE_OBSERVABILITY_JSONL_PATH="$observability_path" \
    BORINGCACHE_MANAGED_BUILDKIT_IMAGE="$buildkit_image" \
    DOCKER_BUILDKIT=1 \
    boringcache docker \
      --backend state \
      --workspace "$workspace" \
      --tag "$cache_tag" \
      "${composition_args[@]}" \
      --no-platform \
      --no-git \
      --fail-on-cache-error \
      --metadata-hint "benchmark=posthog" \
      --metadata-hint "lane=${lane}" \
      --metadata-hint "phase=${metadata_phase}" \
      --metadata-hint "source_sha=${expected_source_sha}" \
      -- \
      docker buildx build \
        --file "$dockerfile_path" \
        "${product_target_args[@]}" \
        --platform "$docker_platform" \
        --output type=cacheonly \
        "$docker_context" 2>&1 | tee "$log_path"
  command_statuses=("${PIPESTATUS[@]}")
  set -e
  command_status="${command_statuses[0]}"
  tee_status="${command_statuses[1]}"
  phase_finished="$(date +%s)"

  snapshot_managed_resources > "$resources_after"
  comm -13 "$baseline_resources" "$resources_after" > "$resources_leaked"

  local cached_steps executed_steps state_overhead restore_status publish_status
  local restored_blobs restored_bytes restored_files logical_bytes logical_blobs transport_delta_bytes transport_delta_blobs
  local restored_generation candidate_generation generation parent_generation head_generations_fetched
  local candidate_blobs candidate_bytes candidate_files restore_core_blobs restore_core_bytes restore_core_files
  local restore_mount_blobs restore_mount_bytes restore_mount_files restore_lazy_content_blobs restore_lazy_content_bytes
  local restore_manifest_seconds restore_verify_seconds
  local restore_url_plan_seconds restore_helper_seconds
  local restore_download_sequential_blobs restore_download_parallel_blobs restore_download_range_parts
  local restore_download_request_retries restore_download_origin_fallbacks
  local window_baseline_bytes window_generation_count window_max_restore_bytes window_max_generations
  local window_rebase_reason published_window_baseline_bytes published_window_generation_count
  local finalize_eligible finalize_already_ready finalize_materialized finalize_failed finalize_required_blobs
  local finalize_seconds retention_policy retention_source retention_disk_usage_baseline_bytes
  local prune_applied prune_triggered prune_target_satisfied prune_target_reason prune_all prune_filter_count
  local finalize_prune_max_used_space_bytes prune_duration_ms pruned_records pruned_bytes
  local records_before_prune records_after_prune prune_keep_duration_ms prune_cutoff_unix_nano
  local prune_cache_usage_before_bytes prune_cache_usage_after_bytes prune_disk_total_bytes
  local prune_disk_free_before_bytes prune_disk_free_after_bytes
  local prune_disk_available_before_bytes prune_disk_available_after_bytes
  local prune_reserved_space_bytes prune_min_free_space_bytes prune_effective_keep_bytes
  local content_gc_applied content_gc_duration_ms
  local records_before_gc records_after_gc content_gc_seconds
  local save_reused_blobs save_reused_bytes lazy_content_runtime_status
  local lazy_content_available_blobs lazy_content_available_bytes lazy_content_hydrated_blobs lazy_content_hydrated_bytes
  local lazy_content_hydration_attempts lazy_content_hydration_failures lazy_content_hydration_milliseconds
  local state_record_flow_json mount_cache_json tool_cache_json
  local summary_valid state_record_flow_valid clean_start_valid mount_cache_valid tool_cache_valid cleanup_valid expectation_valid current_head_only success
  cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$log_path" || true)"
  executed_steps="$(grep -Ec '^#[0-9]+ DONE ([0-9]+([.][0-9]+)?)s$' "$log_path" || true)"
  state_overhead=""
  restore_status="missing"
  publish_status="missing"
  restored_blobs="0"
  restored_bytes="0"
  restored_files="0"
  logical_bytes="0"
  logical_blobs="0"
  transport_delta_bytes="0"
  transport_delta_blobs="0"
  restored_generation=""
  candidate_generation=""
  candidate_blobs="0"
  candidate_bytes="0"
  candidate_files="0"
  restore_core_blobs="0"
  restore_core_bytes="0"
  restore_core_files="0"
  restore_mount_blobs="0"
  restore_mount_bytes="0"
  restore_mount_files="0"
  restore_lazy_content_blobs="0"
  restore_lazy_content_bytes="0"
  restore_manifest_seconds="0"
  restore_verify_seconds="0"
  restore_url_plan_seconds="0"
  restore_helper_seconds="0"
  restore_download_sequential_blobs="0"
  restore_download_parallel_blobs="0"
  restore_download_range_parts="0"
  restore_download_request_retries="0"
  restore_download_origin_fallbacks="0"
  window_baseline_bytes="0"
  window_generation_count="0"
  window_max_restore_bytes="0"
  window_max_generations="0"
  window_rebase_reason=""
  published_window_baseline_bytes="0"
  published_window_generation_count="0"
  generation=""
  parent_generation=""
  finalize_eligible="0"
  finalize_already_ready="0"
  finalize_materialized="0"
  finalize_failed="0"
  finalize_required_blobs="0"
  finalize_seconds=""
  retention_policy=""
  retention_source=""
  retention_disk_usage_baseline_bytes="0"
  prune_applied=false
  prune_triggered=false
  prune_target_satisfied=false
  prune_target_reason=""
  prune_all=false
  prune_filter_count="0"
  finalize_prune_max_used_space_bytes="0"
  prune_duration_ms="0"
  pruned_records="0"
  pruned_bytes="0"
  records_before_prune="0"
  records_after_prune="0"
  prune_keep_duration_ms="0"
  prune_cutoff_unix_nano="0"
  prune_cache_usage_before_bytes="0"
  prune_cache_usage_after_bytes="0"
  prune_disk_total_bytes="0"
  prune_disk_free_before_bytes="0"
  prune_disk_free_after_bytes="0"
  prune_disk_available_before_bytes="0"
  prune_disk_available_after_bytes="0"
  prune_reserved_space_bytes="0"
  prune_min_free_space_bytes="0"
  prune_effective_keep_bytes="0"
  content_gc_applied=false
  content_gc_duration_ms="0"
  records_before_gc="0"
  records_after_gc="0"
  content_gc_seconds=""
  save_reused_blobs="0"
  save_reused_bytes="0"
  lazy_content_runtime_status="not_applicable"
  lazy_content_available_blobs="0"
  lazy_content_available_bytes="0"
  lazy_content_hydrated_blobs="0"
  lazy_content_hydrated_bytes="0"
  lazy_content_hydration_attempts="0"
  lazy_content_hydration_failures="0"
  lazy_content_hydration_milliseconds="0"
  state_record_flow_json=null
  mount_cache_json=null
  tool_cache_json=null
  head_generations_fetched="0"
  summary_valid=false
  state_record_flow_valid=false
  clean_start_valid=false
  mount_cache_valid=false
  tool_cache_valid=false
  cleanup_valid=false
  expectation_valid=false
  current_head_only=false

  if [[ -s "$state_summary_path" ]] && jq -e \
    --arg digest "$buildkit_digest" \
    --arg platform "$docker_platform" \
    '.schema_version == "buildkit-state-summary.v3"
      and .compatibility.image_digest == $digest
      and .compatibility.platform == $platform
      and .compatibility.state_format == "buildkit-state-v1"
      and .compatibility.rootless == false
      and (.finalize.eligible | type == "number")
      and .finalize.eligible >= 0
      and (.finalize.already_ready | type == "number")
      and .finalize.already_ready >= 0
      and (.finalize.materialized | type == "number")
      and .finalize.materialized >= 0
      and (.finalize.failed | type == "number")
      and .finalize.failed == 0
      and .finalize.eligible == (.finalize.already_ready + .finalize.materialized + .finalize.failed)
      and (.finalize.required_blobs | type == "number")
      and .finalize.required_blobs >= 0
      and (.finalize.seconds | type == "number")
      and .finalize.seconds >= 0
      and .finalize.retention_policy == "state-window-scaffold-clean-v1"
      and .finalize.retention_source == "post-clean-measured"
      and (.finalize.retention_disk_usage_baseline_bytes | type == "number")
      and .finalize.retention_disk_usage_baseline_bytes > 0
      and .finalize.prune_applied == true
      and (.finalize.prune_triggered | type == "boolean")
      and .finalize.prune_target_satisfied == true
      and .finalize.prune_target_reason == "scaffold-clean"
      and .finalize.prune_all == true
      and .finalize.prune_filter_count == 2
      and (.finalize.prune_max_used_space_bytes | type == "number")
      and .finalize.prune_max_used_space_bytes == 0
      and (.finalize.prune_duration_ms | type == "number")
      and .finalize.prune_duration_ms >= 0
      and (.finalize.pruned_records | type == "number")
      and .finalize.pruned_records >= 0
      and (.finalize.pruned_bytes | type == "number")
      and .finalize.pruned_bytes >= 0
      and (.finalize.records_before_prune | type == "number")
      and (.finalize.records_after_prune | type == "number")
      and .finalize.records_before_prune >= .finalize.records_after_prune
      and (.finalize.records_before_prune - .finalize.records_after_prune)
        == .finalize.pruned_records
      and (.finalize.prune_keep_duration_ms | type == "number")
      and .finalize.prune_keep_duration_ms == 0
      and (.finalize.prune_cutoff_unix_nano | type == "number")
      and .finalize.prune_cutoff_unix_nano == 0
      and (.finalize.prune_cache_usage_before_bytes | type == "number")
      and (.finalize.prune_cache_usage_after_bytes | type == "number")
      and .finalize.prune_cache_usage_before_bytes >= 0
      and .finalize.prune_cache_usage_after_bytes >= 0
      and .finalize.prune_cache_usage_after_bytes
        <= .finalize.prune_cache_usage_before_bytes
      and .finalize.retention_disk_usage_baseline_bytes
        == ([.finalize.prune_cache_usage_after_bytes, 1] | max)
      and (.finalize.prune_disk_total_bytes | type == "number")
      and .finalize.prune_disk_total_bytes > 0
      and (.finalize.prune_disk_free_before_bytes | type == "number")
      and (.finalize.prune_disk_free_after_bytes | type == "number")
      and .finalize.prune_disk_free_before_bytes >= 0
      and .finalize.prune_disk_free_after_bytes >= 0
      and .finalize.prune_disk_free_before_bytes <= .finalize.prune_disk_total_bytes
      and .finalize.prune_disk_free_after_bytes <= .finalize.prune_disk_total_bytes
      and (.finalize.prune_disk_available_before_bytes | type == "number")
      and (.finalize.prune_disk_available_after_bytes | type == "number")
      and .finalize.prune_disk_available_before_bytes >= 0
      and .finalize.prune_disk_available_after_bytes >= 0
      and .finalize.prune_disk_available_before_bytes
        <= .finalize.prune_disk_free_before_bytes
      and .finalize.prune_disk_available_after_bytes
        <= .finalize.prune_disk_free_after_bytes
      and .finalize.prune_min_free_space_bytes == 0
      and .finalize.prune_reserved_space_bytes == 0
      and .finalize.prune_effective_keep_bytes == 0
      and .finalize.prune_triggered
        == (.finalize.pruned_records > 0 or .finalize.pruned_bytes > 0)
      and (if .finalize.prune_triggered then
             .finalize.pruned_records > 0 or .finalize.pruned_bytes > 0
           else
             .finalize.pruned_records == 0
             and .finalize.pruned_bytes == 0
             and .finalize.records_before_prune == .finalize.records_after_prune
             and .finalize.prune_cache_usage_before_bytes
               == .finalize.prune_cache_usage_after_bytes
           end)
      and .finalize.content_gc_applied == true
      and (.finalize.content_gc_duration_ms | type == "number")
      and .finalize.content_gc_duration_ms >= 0
      and (.finalize.records_before_gc | type == "number")
      and (.finalize.records_after_gc | type == "number")
      and .finalize.records_after_prune == .finalize.records_before_gc
      and .finalize.records_before_gc == .finalize.records_after_gc
      and .finalize.records_after_gc >= .finalize.eligible
      and (.content_gc_seconds | type == "number")
      and .content_gc_seconds >= 0
      and ((.content_gc_seconds * 1000 | round) == .finalize.content_gc_duration_ms)
      and .save.publish_status == "published"
      and (.save.generation | type == "string")
      and (.save.logical_generation_blobs | type == "number")
      and .save.logical_generation_blobs > 0
      and (.save.logical_generation_bytes | type == "number")
      and .save.logical_generation_bytes > 0
      and (.restore.lazy_content_blobs | type == "number")
      and .restore.lazy_content_blobs >= 0
      and (.restore.lazy_content_bytes | type == "number")
      and .restore.lazy_content_bytes >= 0
      and (.save.reused_blobs | type == "number")
      and .save.reused_blobs >= 0
      and (.save.reused_bytes | type == "number")
      and .save.reused_bytes >= 0
      and (.save.uploaded_blobs | type == "number")
      and .save.uploaded_blobs >= 0
      and (.save.uploaded_bytes | type == "number")
      and .save.uploaded_bytes >= 0
      and .save.logical_generation_blobs == (.save.reused_blobs + .save.uploaded_blobs)
      and .save.logical_generation_bytes == (.save.reused_bytes + .save.uploaded_bytes)
      and (.save.lazy_content_runtime_status | type == "string")
      and (.save.lazy_content_available_blobs | type == "number")
      and .save.lazy_content_available_blobs >= 0
      and (.save.lazy_content_available_bytes | type == "number")
      and .save.lazy_content_available_bytes >= 0
      and (.save.lazy_content_hydrated_blobs | type == "number")
      and .save.lazy_content_hydrated_blobs >= 0
      and (.save.lazy_content_hydrated_bytes | type == "number")
      and .save.lazy_content_hydrated_bytes >= 0
      and (.save.lazy_content_hydration_attempts | type == "number")
      and .save.lazy_content_hydration_attempts >= 0
      and (.save.lazy_content_hydration_failures | type == "number")
      and .save.lazy_content_hydration_failures == 0
      and (.save.lazy_content_hydration_milliseconds | type == "number")
      and .save.lazy_content_hydration_milliseconds >= 0
      and .save.lazy_content_hydrated_blobs <= .save.lazy_content_available_blobs
      and .save.lazy_content_hydrated_bytes <= .save.lazy_content_available_bytes
      and .save.lazy_content_hydration_attempts >= .save.lazy_content_hydrated_blobs
      and (if .restore.status == "restored" then
             .save.lazy_content_runtime_status == "recorded"
             and .save.lazy_content_available_blobs == .restore.lazy_content_blobs
             and .save.lazy_content_available_bytes == .restore.lazy_content_bytes
           else
             .save.lazy_content_runtime_status == "not_applicable"
             and .save.lazy_content_available_blobs == 0
             and .save.lazy_content_available_bytes == 0
             and .save.lazy_content_hydrated_blobs == 0
             and .save.lazy_content_hydrated_bytes == 0
             and .save.lazy_content_hydration_attempts == 0
           end)
      and (.total_state_overhead_seconds | type == "number")
      and .total_state_overhead_seconds >= 0' \
    "$state_summary_path" >/dev/null; then
    summary_valid=true
    state_overhead="$(jq -r '.total_state_overhead_seconds' "$state_summary_path")"
    restore_status="$(jq -r '.restore.status' "$state_summary_path")"
    publish_status="$(jq -r '.save.publish_status' "$state_summary_path")"
    restored_blobs="$(jq -r '.restore.blobs // 0' "$state_summary_path")"
    restored_bytes="$(jq -r '.restore.bytes // 0' "$state_summary_path")"
    restored_files="$(jq -r '.restore.files // 0' "$state_summary_path")"
    logical_bytes="$(jq -r '.save.logical_generation_bytes' "$state_summary_path")"
    logical_blobs="$(jq -r '.save.logical_generation_blobs' "$state_summary_path")"
    transport_delta_bytes="$(jq -r '.save.uploaded_bytes' "$state_summary_path")"
    transport_delta_blobs="$(jq -r '.save.uploaded_blobs' "$state_summary_path")"
    restored_generation="$(jq -r '.restore.generation // ""' "$state_summary_path")"
    candidate_generation="$(jq -r '.restore.candidate_generation // ""' "$state_summary_path")"
    candidate_blobs="$(jq -r '.restore.candidate_blobs // 0' "$state_summary_path")"
    candidate_bytes="$(jq -r '.restore.candidate_bytes // 0' "$state_summary_path")"
    candidate_files="$(jq -r '.restore.candidate_files // 0' "$state_summary_path")"
    restore_core_blobs="$(jq -r '.restore.core_blobs // 0' "$state_summary_path")"
    restore_core_bytes="$(jq -r '.restore.core_bytes // 0' "$state_summary_path")"
    restore_core_files="$(jq -r '.restore.core_files // 0' "$state_summary_path")"
    restore_mount_blobs="$(jq -r '.restore.mount_cache_blobs // 0' "$state_summary_path")"
    restore_mount_bytes="$(jq -r '.restore.mount_cache_bytes // 0' "$state_summary_path")"
    restore_mount_files="$(jq -r '.restore.mount_cache_files // 0' "$state_summary_path")"
    restore_lazy_content_blobs="$(jq -r '.restore.lazy_content_blobs' "$state_summary_path")"
    restore_lazy_content_bytes="$(jq -r '.restore.lazy_content_bytes' "$state_summary_path")"
    restore_manifest_seconds="$(jq -r '.restore.manifest_seconds // 0' "$state_summary_path")"
    restore_verify_seconds="$(jq -r '.restore.verify_seconds // 0' "$state_summary_path")"
    restore_url_plan_seconds="$(jq -r '.restore.url_plan_seconds // 0' "$state_summary_path")"
    restore_helper_seconds="$(jq -r '.restore.helper_seconds // 0' "$state_summary_path")"
    restore_download_sequential_blobs="$(jq -r '.restore.download_sequential_blobs // 0' "$state_summary_path")"
    restore_download_parallel_blobs="$(jq -r '.restore.download_parallel_blobs // 0' "$state_summary_path")"
    restore_download_range_parts="$(jq -r '.restore.download_range_parts // 0' "$state_summary_path")"
    restore_download_request_retries="$(jq -r '.restore.download_request_retries // 0' "$state_summary_path")"
    restore_download_origin_fallbacks="$(jq -r '.restore.download_origin_fallbacks // 0' "$state_summary_path")"
    window_baseline_bytes="$(jq -r '.restore.state_window_baseline_bytes // 0' "$state_summary_path")"
    window_generation_count="$(jq -r '.restore.state_window_generation_count // 0' "$state_summary_path")"
    window_max_restore_bytes="$(jq -r '.restore.state_window_max_restore_bytes // 0' "$state_summary_path")"
    window_max_generations="$(jq -r '.restore.state_window_max_generations // 0' "$state_summary_path")"
    window_rebase_reason="$(jq -r '.restore.state_window_rebase_reason // ""' "$state_summary_path")"
    generation="$(jq -r '.save.generation // ""' "$state_summary_path")"
    parent_generation="$(jq -r '.save.parent // ""' "$state_summary_path")"
    published_window_baseline_bytes="$(jq -r '.save.state_window_baseline_bytes // 0' "$state_summary_path")"
    published_window_generation_count="$(jq -r '.save.state_window_generation_count // 0' "$state_summary_path")"
    finalize_eligible="$(jq -r '.finalize.eligible' "$state_summary_path")"
    finalize_already_ready="$(jq -r '.finalize.already_ready' "$state_summary_path")"
    finalize_materialized="$(jq -r '.finalize.materialized' "$state_summary_path")"
    finalize_failed="$(jq -r '.finalize.failed' "$state_summary_path")"
    finalize_required_blobs="$(jq -r '.finalize.required_blobs' "$state_summary_path")"
    finalize_seconds="$(jq -r '.finalize.seconds' "$state_summary_path")"
    retention_policy="$(jq -r '.finalize.retention_policy' "$state_summary_path")"
    retention_source="$(jq -r '.finalize.retention_source' "$state_summary_path")"
    retention_disk_usage_baseline_bytes="$(jq -r '.finalize.retention_disk_usage_baseline_bytes' "$state_summary_path")"
    prune_applied="$(jq -r '.finalize.prune_applied' "$state_summary_path")"
    prune_triggered="$(jq -r '.finalize.prune_triggered' "$state_summary_path")"
    prune_target_satisfied="$(jq -r '.finalize.prune_target_satisfied' "$state_summary_path")"
    prune_target_reason="$(jq -r '.finalize.prune_target_reason' "$state_summary_path")"
    prune_all="$(jq -r '.finalize.prune_all' "$state_summary_path")"
    prune_filter_count="$(jq -r '.finalize.prune_filter_count' "$state_summary_path")"
    finalize_prune_max_used_space_bytes="$(jq -r '.finalize.prune_max_used_space_bytes' "$state_summary_path")"
    prune_duration_ms="$(jq -r '.finalize.prune_duration_ms' "$state_summary_path")"
    pruned_records="$(jq -r '.finalize.pruned_records' "$state_summary_path")"
    pruned_bytes="$(jq -r '.finalize.pruned_bytes' "$state_summary_path")"
    records_before_prune="$(jq -r '.finalize.records_before_prune' "$state_summary_path")"
    records_after_prune="$(jq -r '.finalize.records_after_prune' "$state_summary_path")"
    prune_keep_duration_ms="$(jq -r '.finalize.prune_keep_duration_ms' "$state_summary_path")"
    prune_cutoff_unix_nano="$(jq -r '.finalize.prune_cutoff_unix_nano' "$state_summary_path")"
    prune_cache_usage_before_bytes="$(jq -r '.finalize.prune_cache_usage_before_bytes' "$state_summary_path")"
    prune_cache_usage_after_bytes="$(jq -r '.finalize.prune_cache_usage_after_bytes' "$state_summary_path")"
    prune_disk_total_bytes="$(jq -r '.finalize.prune_disk_total_bytes' "$state_summary_path")"
    prune_disk_free_before_bytes="$(jq -r '.finalize.prune_disk_free_before_bytes' "$state_summary_path")"
    prune_disk_free_after_bytes="$(jq -r '.finalize.prune_disk_free_after_bytes' "$state_summary_path")"
    prune_disk_available_before_bytes="$(jq -r '.finalize.prune_disk_available_before_bytes' "$state_summary_path")"
    prune_disk_available_after_bytes="$(jq -r '.finalize.prune_disk_available_after_bytes' "$state_summary_path")"
    prune_reserved_space_bytes="$(jq -r '.finalize.prune_reserved_space_bytes' "$state_summary_path")"
    prune_min_free_space_bytes="$(jq -r '.finalize.prune_min_free_space_bytes' "$state_summary_path")"
    prune_effective_keep_bytes="$(jq -r '.finalize.prune_effective_keep_bytes' "$state_summary_path")"
    content_gc_applied="$(jq -r '.finalize.content_gc_applied' "$state_summary_path")"
    content_gc_duration_ms="$(jq -r '.finalize.content_gc_duration_ms' "$state_summary_path")"
    records_before_gc="$(jq -r '.finalize.records_before_gc' "$state_summary_path")"
    records_after_gc="$(jq -r '.finalize.records_after_gc' "$state_summary_path")"
    content_gc_seconds="$(jq -r '.content_gc_seconds' "$state_summary_path")"
    save_reused_blobs="$(jq -r '.save.reused_blobs' "$state_summary_path")"
    save_reused_bytes="$(jq -r '.save.reused_bytes' "$state_summary_path")"
    lazy_content_runtime_status="$(jq -r '.save.lazy_content_runtime_status' "$state_summary_path")"
    lazy_content_available_blobs="$(jq -r '.save.lazy_content_available_blobs' "$state_summary_path")"
    lazy_content_available_bytes="$(jq -r '.save.lazy_content_available_bytes' "$state_summary_path")"
    lazy_content_hydrated_blobs="$(jq -r '.save.lazy_content_hydrated_blobs' "$state_summary_path")"
    lazy_content_hydrated_bytes="$(jq -r '.save.lazy_content_hydrated_bytes' "$state_summary_path")"
    lazy_content_hydration_attempts="$(jq -r '.save.lazy_content_hydration_attempts' "$state_summary_path")"
    lazy_content_hydration_failures="$(jq -r '.save.lazy_content_hydration_failures' "$state_summary_path")"
    lazy_content_hydration_milliseconds="$(jq -r '.save.lazy_content_hydration_milliseconds' "$state_summary_path")"
    state_record_flow_json="$(jq -c '.state_record_flow // null' "$state_summary_path")"
    mount_cache_json="$(jq -c '.mount_cache' "$state_summary_path")"
    if jq -e --arg phase "$phase" '
      def nonnegative_integer:
        type == "number" and . >= 0 and . == floor;
      def positive_integer:
        type == "number" and . > 0 and . == floor;
      def nonempty_string:
        type == "string" and (gsub("^[[:space:]]+|[[:space:]]+$"; "") | length) > 0;
      .state_record_flow as $flow
      | $flow.status == "recorded"
      and ($flow.total_records | nonnegative_integer)
      and ($flow.eligible_records | nonnegative_integer)
      and ($flow.created_during_build | nonnegative_integer)
      and ($flow.local_source_records | nonnegative_integer)
      and ($flow.local_sources_created_during_build | nonnegative_integer)
      and $flow.eligible_records <= $flow.total_records
      and $flow.created_during_build <= $flow.total_records
      and $flow.local_source_records <= $flow.total_records
      and $flow.created_during_build >= 3
      and (if ($phase | test("^same-ref-(warm|repeat)")) then
        $flow.created_during_build == 3
      else
        true
      end)
      and $flow.local_sources_created_during_build == 3
      and $flow.local_sources_created_during_build <= $flow.created_during_build
      and $flow.local_sources_created_during_build <= $flow.local_source_records
      and ($flow.local_source_groups | type) == "array"
      and ($flow.local_source_groups | length) > 0
      and all($flow.local_source_groups[];
        (.description | nonempty_string)
        and (.total | nonnegative_integer)
        and (.created_during_build | nonnegative_integer)
        and .created_during_build <= .total
      )
      and (($flow.local_source_groups | map(.description) | unique | length)
        == ($flow.local_source_groups | length))
      and (($flow.local_source_groups | map(.total) | add // 0)
        == $flow.local_source_records)
      and (($flow.local_source_groups | map(.created_during_build) | add // 0)
        == $flow.local_sources_created_during_build)
      and ($flow.created_local_sources | type) == "array"
      and ($flow.created_local_sources | length) == 3
      and all($flow.created_local_sources[];
        (.record_id | nonempty_string)
        and (.description | nonempty_string)
        and (.created_at_unix_nano | positive_integer)
        and (.active_references | nonnegative_integer)
        and (.retained | type) == "boolean"
      )
      and (($flow.created_local_sources | map(.record_id) | unique | length) == 3)
      and all($flow.created_local_sources[];
        .description as $description
        | any($flow.local_source_groups[]; .description == $description)
      )
      and all($flow.local_source_groups[];
        . as $group
        | ([$flow.created_local_sources[] | select(.description == $group.description)] | length)
          == $group.created_during_build
      )
    ' "$state_summary_path" >/dev/null; then
      state_record_flow_valid=true
    fi
    if jq -e \
      --arg composition_mode "$composition_mode" \
      'if $composition_mode == "fixture" then
         .mount_cache.enabled == true
         and .mount_cache.runtime_status == "recorded"
         and .mount_cache.hydrate_errors == 0
         and .mount_cache.publish_errors == 0
         and .mount_cache.restored_blobs == 0
         and .mount_cache.restored_archives == 0
         and .mount_cache.restored_bytes == 0
         and .mount_cache.aborted_archives == 0
         and .mount_cache.staged_archives == .mount_cache.released_archives
         and .mount_cache.staged_archives == .mount_cache.published_archives
         and .mount_cache.generation_archives == .mount_cache.selected_archives
         and .mount_cache.generation_archives > 0
         and (if .restore.status == "restored" then
                .mount_cache.available_archives > 0
                and .mount_cache.available_bytes > 0
              else
                .mount_cache.available_archives == 0
                and .mount_cache.available_bytes == 0
              end)
       else
         .mount_cache.enabled == false
         and .mount_cache.runtime_status == "disabled"
         and .mount_cache.generation_archives == 0
         and .mount_cache.staged_archives == 0
         and .mount_cache.released_archives == 0
         and .mount_cache.aborted_archives == 0
       end' \
      "$state_summary_path" >/dev/null; then
      mount_cache_valid=true
    fi
    if jq -e '
      def has_number($object; $name):
        ($object | has($name)) and (($object[$name] | type) == "number");
      def has_zero_number($object; $name):
        has_number($object; $name) and $object[$name] == 0;
      if .restore.status == "clean_start" then
        (.restore | has("generation"))
        and .restore.generation == null
        and ((.restore.candidate_generation | type) == "string")
        and (.restore.candidate_generation | test("^sha256:[0-9a-f]{64}$"))
        and (.restore.candidate_blobs | type == "number" and . > 0)
        and (.restore.candidate_bytes | type == "number" and . > 0)
        and (.restore.candidate_files | type == "number" and . > 0)
        and has_number(.restore; "resolve_seconds")
        and .restore.resolve_seconds >= 0
        and has_number(.restore; "manifest_seconds")
        and .restore.manifest_seconds >= 0
        and has_number(.restore; "verify_seconds")
        and .restore.verify_seconds >= 0
        and has_number(.restore; "seconds")
        and .restore.seconds >= 0
        and (.restore.state_window_baseline_bytes | type == "number" and . > 0)
        and (.restore.state_window_generation_count | type == "number" and . > 0)
        and (.restore.state_window_max_restore_bytes | type == "number" and . > 0)
        and (.restore.state_window_max_generations | type == "number" and . > 0)
        and (
          (.restore.state_window_rebase_reason == "restore_bytes"
            and .restore.candidate_bytes > .restore.state_window_max_restore_bytes)
          or
          (.restore.state_window_rebase_reason == "generation_count"
            and .restore.state_window_generation_count >= .restore.state_window_max_generations)
        )
        and has_zero_number(.restore; "blobs")
        and has_zero_number(.restore; "bytes")
        and has_zero_number(.restore; "files")
        and has_zero_number(.restore; "core_blobs")
        and has_zero_number(.restore; "core_bytes")
        and has_zero_number(.restore; "core_files")
        and has_zero_number(.restore; "mount_cache_blobs")
        and has_zero_number(.restore; "mount_cache_bytes")
        and has_zero_number(.restore; "mount_cache_files")
        and has_zero_number(.restore; "download_sequential_blobs")
        and has_zero_number(.restore; "download_parallel_blobs")
        and has_zero_number(.restore; "download_range_parts")
        and has_zero_number(.restore; "download_request_retries")
        and has_zero_number(.restore; "download_origin_fallbacks")
        and has_zero_number(.restore; "url_plan_seconds")
        and has_zero_number(.restore; "helper_seconds")
        and (.save | has("generation"))
        and ((.save.generation | type) == "string")
        and (.save.generation | test("^sha256:[0-9a-f]{64}$"))
        and .save.generation != .restore.candidate_generation
        and (.save | has("parent"))
        and .save.parent == null
        and .save.publish_status == "published"
        and (.save.state_window_baseline_bytes | type == "number" and . > 0)
        and .save.state_window_baseline_bytes == .save.logical_generation_bytes
        and .save.state_window_generation_count == 1
      else
        true
      end
    ' "$state_summary_path" >/dev/null; then
      clean_start_valid=true
    fi
    if [[ "$restore_status" == "restored" || "$restore_status" == "clean_start" ]]; then
      head_generations_fetched=1
    fi
  fi

  if [[ "$composition_mode" == off ]]; then
    tool_cache_valid=true
  elif [[ -s "$observability_path" ]]; then
    tool_cache_json="$(jq -sc '
      map(select(.operation == "cache_session_summary" and .adapter == "turborepo"))
      | if length != 1 then null else .[0] | {
          adapter,
          duration_ms,
          hits: (.classification.cache_temperature.hits // 0),
          misses: (.classification.cache_temperature.misses // 0),
          writes: (.classification.cache_temperature.writes // 0),
          errors: (.classification.cache_temperature.errors // 0),
          backend_errors: (.backend_api.total_error_count // 0),
          backend_retries: (.backend_api.total_retry_count // 0)
        } end
    ' "$observability_path")"
    if jq -e '
      . != null
      and .adapter == "turborepo"
      and .errors == 0
      and .backend_errors == 0
    ' <<< "$tool_cache_json" >/dev/null; then
      tool_cache_valid=true
    fi
  fi

  if { [[ "$restore_status" == "miss" && "$head_generations_fetched" -eq 0 && -z "$restored_generation" ]] || \
       [[ "$restore_status" == "restored" && "$head_generations_fetched" -eq 1 && -n "$restored_generation" ]] || \
       [[ "$restore_status" == "clean_start" && "$head_generations_fetched" -eq 1 && -z "$restored_generation" && -n "$candidate_generation" && "$clean_start_valid" == true ]]; }; then
    current_head_only=true
  fi

  if [[ ! -s "$resources_leaked" ]]; then
    cleanup_valid=true
  fi

  case "$expectation" in
    cold|replay-root)
      if [[ "$logical_blobs" -gt 0 && "$logical_bytes" -gt 0 ]] && \
         { [[ "$restore_status" == "miss" && -z "$parent_generation" ]] || \
           [[ "$restore_status" == "clean_start" && -z "$parent_generation" && "$clean_start_valid" == true ]]; }; then
        expectation_valid=true
      fi
      ;;
    same-ref|replay-successor)
      if [[ "$logical_blobs" -gt 0 && "$logical_bytes" -gt 0 ]] && \
         { [[ "$restore_status" == "restored" && "$parent_generation" == "$restored_generation" ]] || \
           [[ "$restore_status" == "clean_start" && -z "$parent_generation" && "$clean_start_valid" == true ]]; }; then
        expectation_valid=true
      fi
      ;;
    rolling)
      if [[ "$logical_blobs" -gt 0 && "$logical_bytes" -gt 0 ]] && \
         { [[ "$restore_status" == "miss" && -z "$parent_generation" ]] || \
           [[ "$restore_status" == "restored" && "$parent_generation" == "$restored_generation" ]] || \
           [[ "$restore_status" == "clean_start" && -z "$parent_generation" && "$clean_start_valid" == true ]]; }; then
        expectation_valid=true
      fi
      ;;
  esac

  success=false
  if [[ "$command_status" -eq 0 && "$tee_status" -eq 0 && "$summary_valid" == true && "$state_record_flow_valid" == true && "$clean_start_valid" == true && "$mount_cache_valid" == true && "$tool_cache_valid" == true && "$cleanup_valid" == true && "$expectation_valid" == true && "$current_head_only" == true ]]; then
    success=true
  fi

  jq -n '{
    schema_version: "buildkit-state-backend-current-set.v1",
    attempted: false,
    head_valid: false,
    retention_converged: false,
    valid: false
  }' > "$backend_current_set_result_path"
  if [[ "$success" == true ]] && ! audit_backend_current_set \
    "$phase" \
    "$generation" \
    "$logical_bytes" \
    "$backend_current_set_result_path"; then
    success=false
  fi

  jq -n \
    --arg schema_version "buildkit-state-canary-phase.v2" \
    --arg phase "$phase" \
    --arg metadata_phase "$metadata_phase" \
    --arg source_sha "$expected_source_sha" \
    --arg cache_tag "$cache_tag" \
    --arg restore_status "$restore_status" \
    --arg publish_status "$publish_status" \
    --arg state_overhead_seconds "$state_overhead" \
    --argjson phase_seconds "$((phase_finished - phase_started))" \
    --argjson command_status "$command_status" \
    --argjson tee_status "$tee_status" \
    --argjson cached_steps "$cached_steps" \
    --argjson executed_steps "$executed_steps" \
    --argjson restored_blobs "$restored_blobs" \
    --argjson restored_bytes "$restored_bytes" \
    --argjson restored_files "$restored_files" \
    --arg restored_generation "$restored_generation" \
    --arg candidate_generation "$candidate_generation" \
    --argjson candidate_blobs "$candidate_blobs" \
    --argjson candidate_bytes "$candidate_bytes" \
    --argjson candidate_files "$candidate_files" \
    --argjson restore_core_blobs "$restore_core_blobs" \
    --argjson restore_core_bytes "$restore_core_bytes" \
    --argjson restore_core_files "$restore_core_files" \
    --argjson restore_mount_blobs "$restore_mount_blobs" \
    --argjson restore_mount_bytes "$restore_mount_bytes" \
    --argjson restore_mount_files "$restore_mount_files" \
    --argjson restore_lazy_content_blobs "$restore_lazy_content_blobs" \
    --argjson restore_lazy_content_bytes "$restore_lazy_content_bytes" \
    --arg restore_manifest_seconds "$restore_manifest_seconds" \
    --arg restore_verify_seconds "$restore_verify_seconds" \
    --arg restore_url_plan_seconds "$restore_url_plan_seconds" \
    --arg restore_helper_seconds "$restore_helper_seconds" \
    --argjson restore_download_sequential_blobs "$restore_download_sequential_blobs" \
    --argjson restore_download_parallel_blobs "$restore_download_parallel_blobs" \
    --argjson restore_download_range_parts "$restore_download_range_parts" \
    --argjson restore_download_request_retries "$restore_download_request_retries" \
    --argjson restore_download_origin_fallbacks "$restore_download_origin_fallbacks" \
    --argjson window_baseline_bytes "$window_baseline_bytes" \
    --argjson window_generation_count "$window_generation_count" \
    --argjson window_max_restore_bytes "$window_max_restore_bytes" \
    --argjson window_max_generations "$window_max_generations" \
    --arg window_rebase_reason "$window_rebase_reason" \
    --arg generation "$generation" \
    --arg parent_generation "$parent_generation" \
    --argjson published_window_baseline_bytes "$published_window_baseline_bytes" \
    --argjson published_window_generation_count "$published_window_generation_count" \
    --argjson logical_bytes "$logical_bytes" \
    --argjson logical_blobs "$logical_blobs" \
    --argjson transport_delta_bytes "$transport_delta_bytes" \
    --argjson transport_delta_blobs "$transport_delta_blobs" \
    --argjson save_reused_blobs "$save_reused_blobs" \
    --argjson save_reused_bytes "$save_reused_bytes" \
    --arg lazy_content_runtime_status "$lazy_content_runtime_status" \
    --argjson lazy_content_available_blobs "$lazy_content_available_blobs" \
    --argjson lazy_content_available_bytes "$lazy_content_available_bytes" \
    --argjson lazy_content_hydrated_blobs "$lazy_content_hydrated_blobs" \
    --argjson lazy_content_hydrated_bytes "$lazy_content_hydrated_bytes" \
    --argjson lazy_content_hydration_attempts "$lazy_content_hydration_attempts" \
    --argjson lazy_content_hydration_failures "$lazy_content_hydration_failures" \
    --argjson lazy_content_hydration_milliseconds "$lazy_content_hydration_milliseconds" \
    --argjson finalize_eligible "$finalize_eligible" \
    --argjson finalize_already_ready "$finalize_already_ready" \
    --argjson finalize_materialized "$finalize_materialized" \
    --argjson finalize_failed "$finalize_failed" \
    --argjson finalize_required_blobs "$finalize_required_blobs" \
    --arg finalize_seconds "$finalize_seconds" \
    --arg retention_policy "$retention_policy" \
    --arg retention_source "$retention_source" \
    --argjson retention_disk_usage_baseline_bytes "$retention_disk_usage_baseline_bytes" \
    --argjson prune_applied "$prune_applied" \
    --argjson prune_triggered "$prune_triggered" \
    --argjson prune_target_satisfied "$prune_target_satisfied" \
    --arg prune_target_reason "$prune_target_reason" \
    --argjson prune_all "$prune_all" \
    --argjson prune_filter_count "$prune_filter_count" \
    --argjson finalize_prune_max_used_space_bytes "$finalize_prune_max_used_space_bytes" \
    --argjson prune_duration_ms "$prune_duration_ms" \
    --argjson pruned_records "$pruned_records" \
    --argjson pruned_bytes "$pruned_bytes" \
    --argjson records_before_prune "$records_before_prune" \
    --argjson records_after_prune "$records_after_prune" \
    --argjson prune_keep_duration_ms "$prune_keep_duration_ms" \
    --argjson prune_cutoff_unix_nano "$prune_cutoff_unix_nano" \
    --argjson prune_cache_usage_before_bytes "$prune_cache_usage_before_bytes" \
    --argjson prune_cache_usage_after_bytes "$prune_cache_usage_after_bytes" \
    --argjson prune_disk_total_bytes "$prune_disk_total_bytes" \
    --argjson prune_disk_free_before_bytes "$prune_disk_free_before_bytes" \
    --argjson prune_disk_free_after_bytes "$prune_disk_free_after_bytes" \
    --argjson prune_disk_available_before_bytes "$prune_disk_available_before_bytes" \
    --argjson prune_disk_available_after_bytes "$prune_disk_available_after_bytes" \
    --argjson prune_reserved_space_bytes "$prune_reserved_space_bytes" \
    --argjson prune_min_free_space_bytes "$prune_min_free_space_bytes" \
    --argjson prune_effective_keep_bytes "$prune_effective_keep_bytes" \
    --argjson content_gc_applied "$content_gc_applied" \
    --argjson content_gc_duration_ms "$content_gc_duration_ms" \
    --argjson records_before_gc "$records_before_gc" \
    --argjson records_after_gc "$records_after_gc" \
    --arg content_gc_seconds "$content_gc_seconds" \
    --argjson state_record_flow "$state_record_flow_json" \
    --argjson mount_cache "$mount_cache_json" \
    --argjson tool_cache "$tool_cache_json" \
    --argjson head_generations_fetched "$head_generations_fetched" \
    --argjson summary_valid "$summary_valid" \
    --argjson state_record_flow_valid "$state_record_flow_valid" \
    --argjson clean_start_valid "$clean_start_valid" \
    --argjson mount_cache_valid "$mount_cache_valid" \
    --argjson tool_cache_valid "$tool_cache_valid" \
    --argjson cleanup_valid "$cleanup_valid" \
    --argjson expectation_valid "$expectation_valid" \
    --argjson current_head_only "$current_head_only" \
    --argjson success "$success" \
    --slurpfile backend_current_set "$backend_current_set_result_path" \
    '{
      schema_version: $schema_version,
      phase: $phase,
      metadata_phase: $metadata_phase,
      source_sha: $source_sha,
      cache_tag: $cache_tag,
      phase_seconds: $phase_seconds,
      command_status: $command_status,
      tee_status: $tee_status,
      cached_steps: $cached_steps,
      executed_steps: $executed_steps,
      state: {
        restore_status: $restore_status,
        publish_status: $publish_status,
        overhead_seconds: (if $state_overhead_seconds == "" then null else ($state_overhead_seconds | tonumber) end),
        restored_blobs: $restored_blobs,
        restored_bytes: $restored_bytes,
        restored_files: $restored_files,
        restored_generation: (if $restored_generation == "" then null else $restored_generation end),
        restore: {
          candidate_generation: (if $candidate_generation == "" then null else $candidate_generation end),
          candidate_blobs: $candidate_blobs,
          candidate_bytes: $candidate_bytes,
          candidate_files: $candidate_files,
          restored_blobs: $restored_blobs,
          restored_bytes: $restored_bytes,
          restored_files: $restored_files,
          core_blobs: $restore_core_blobs,
          core_bytes: $restore_core_bytes,
          core_files: $restore_core_files,
          mount_cache_blobs: $restore_mount_blobs,
          mount_cache_bytes: $restore_mount_bytes,
          mount_cache_files: $restore_mount_files,
          lazy_content_blobs: $restore_lazy_content_blobs,
          lazy_content_bytes: $restore_lazy_content_bytes,
          manifest_seconds: ($restore_manifest_seconds | tonumber),
          verify_seconds: ($restore_verify_seconds | tonumber),
          url_plan_seconds: ($restore_url_plan_seconds | tonumber),
          helper_seconds: ($restore_helper_seconds | tonumber),
          download_sequential_blobs: $restore_download_sequential_blobs,
          download_parallel_blobs: $restore_download_parallel_blobs,
          download_range_parts: $restore_download_range_parts,
          download_request_retries: $restore_download_request_retries,
          download_origin_fallbacks: $restore_download_origin_fallbacks
        },
        head_generations_fetched: $head_generations_fetched,
        generation: (if $generation == "" then null else $generation end),
        parent_generation: (if $parent_generation == "" then null else $parent_generation end),
        state_window: {
          candidate_baseline_bytes: $window_baseline_bytes,
          candidate_generation_count: $window_generation_count,
          max_restore_bytes: $window_max_restore_bytes,
          max_generations: $window_max_generations,
          rebase_reason: (if $window_rebase_reason == "" then null else $window_rebase_reason end),
          published_baseline_bytes: $published_window_baseline_bytes,
          published_generation_count: $published_window_generation_count
        },
        logical_generation_bytes: $logical_bytes,
        logical_generation_blobs: $logical_blobs,
        transport_delta_bytes: $transport_delta_bytes,
        transport_delta_blobs: $transport_delta_blobs,
        save: {
          reused_blobs: $save_reused_blobs,
          reused_bytes: $save_reused_bytes,
          uploaded_blobs: $transport_delta_blobs,
          uploaded_bytes: $transport_delta_bytes,
          lazy_content_runtime_status: $lazy_content_runtime_status,
          lazy_content_available_blobs: $lazy_content_available_blobs,
          lazy_content_available_bytes: $lazy_content_available_bytes,
          lazy_content_hydrated_blobs: $lazy_content_hydrated_blobs,
          lazy_content_hydrated_bytes: $lazy_content_hydrated_bytes,
          lazy_content_hydration_attempts: $lazy_content_hydration_attempts,
          lazy_content_hydration_failures: $lazy_content_hydration_failures,
          lazy_content_hydration_milliseconds: $lazy_content_hydration_milliseconds
        },
        finalize: {
          eligible: $finalize_eligible,
          already_ready: $finalize_already_ready,
          materialized: $finalize_materialized,
          failed: $finalize_failed,
          required_blobs: $finalize_required_blobs,
          seconds: (if $finalize_seconds == "" then null else ($finalize_seconds | tonumber) end),
          retention_policy: $retention_policy,
          retention_source: $retention_source,
          retention_disk_usage_baseline_bytes: $retention_disk_usage_baseline_bytes,
          prune_applied: $prune_applied,
          prune_triggered: $prune_triggered,
          prune_target_satisfied: $prune_target_satisfied,
          prune_target_reason: $prune_target_reason,
          prune_all: $prune_all,
          prune_filter_count: $prune_filter_count,
          prune_max_used_space_bytes: $finalize_prune_max_used_space_bytes,
          prune_duration_ms: $prune_duration_ms,
          pruned_records: $pruned_records,
          pruned_bytes: $pruned_bytes,
          records_before_prune: $records_before_prune,
          records_after_prune: $records_after_prune,
          prune_keep_duration_ms: $prune_keep_duration_ms,
          prune_cutoff_unix_nano: $prune_cutoff_unix_nano,
          prune_cache_usage_before_bytes: $prune_cache_usage_before_bytes,
          prune_cache_usage_after_bytes: $prune_cache_usage_after_bytes,
          prune_disk_total_bytes: $prune_disk_total_bytes,
          prune_disk_free_before_bytes: $prune_disk_free_before_bytes,
          prune_disk_free_after_bytes: $prune_disk_free_after_bytes,
          prune_disk_available_before_bytes: $prune_disk_available_before_bytes,
          prune_disk_available_after_bytes: $prune_disk_available_after_bytes,
          prune_reserved_space_bytes: $prune_reserved_space_bytes,
          prune_min_free_space_bytes: $prune_min_free_space_bytes,
          prune_effective_keep_bytes: $prune_effective_keep_bytes,
          content_gc_applied: $content_gc_applied,
          content_gc_duration_ms: $content_gc_duration_ms,
          records_before_gc: $records_before_gc,
          records_after_gc: $records_after_gc
        },
        content_gc_seconds: (if $content_gc_seconds == "" then null else ($content_gc_seconds | tonumber) end),
        state_record_flow: $state_record_flow,
        mount_cache: $mount_cache
      },
      tool_cache: $tool_cache,
      backend_current_set: $backend_current_set[0],
      checks: {
        summary_valid: $summary_valid,
        state_record_flow_valid: $state_record_flow_valid,
        clean_start_valid: $clean_start_valid,
        mount_cache_valid: $mount_cache_valid,
        tool_cache_valid: $tool_cache_valid,
        managed_builder_destroyed: $cleanup_valid,
        phase_expectation_valid: $expectation_valid,
        current_head_only: $current_head_only,
        backend_current_set_valid: ($backend_current_set[0].head_valid == true),
        backend_retention_converged: ($backend_current_set[0].retention_converged == true)
      },
      success: $success
    }' > "$phase_result_path"

  if [[ "$success" != true ]]; then
    echo "BuildKit state canary phase ${phase} failed validation" >&2
    if [[ -s "$resources_leaked" ]]; then
      echo "Managed resources left behind:" >&2
      sed 's/^/  /' "$resources_leaked" >&2
    fi
    return 1
  fi
}

run_terminal_mount_probe() {
  local log_path="$artifact_dir/mount-probe.build.log"
  local daemon_log_path="$artifact_dir/mount-probe.buildkitd.log"
  local observability_path="$artifact_dir/mount-probe.observability.jsonl"
  local state_summary_path="$artifact_dir/mount-probe.state-summary.json"
  local resources_after="$artifact_dir/mount-probe.managed-resources.after.txt"
  local resources_leaked="$artifact_dir/mount-probe.managed-resources.leaked.txt"
  local phase_started phase_finished command_status tee_status summary_valid cleanup_valid success
  local last_product_phase_path expected_generation result_summary_path
  local command_statuses=()

  if [[ "$lane" == fresh ]]; then
    last_product_phase_path="$artifact_dir/$(fresh_warm_phase_name "$warm_generations").phase.json"
  elif [[ "$lane" == rolling ]]; then
    last_product_phase_path="$artifact_dir/rolling.phase.json"
  else
    last_product_phase_path="$(find "$artifact_dir" -maxdepth 1 -name 'replay-*.phase.json' -type f | LC_ALL=C sort | tail -n1)"
  fi
  [[ -s "$last_product_phase_path" ]] || {
    echo "Terminal mount probe cannot find the last product phase" >&2
    return 1
  }
  expected_generation="$(jq -r '.state.generation // ""' "$last_product_phase_path")"
  [[ "$expected_generation" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "Terminal mount probe has no exact product generation to restore" >&2
    return 1
  }

  rm -f \
    "$log_path" \
    "$daemon_log_path" \
    "$observability_path" \
    "$state_summary_path" \
    "$resources_after" \
    "$resources_leaked"

  phase_started="$(date +%s)"
  set +e
  BORINGCACHE_STATE_SUMMARY_PATH="$state_summary_path" \
    BORINGCACHE_STATE_CANARY_PROBE_EXPECTED_GENERATION="$expected_generation" \
    BORINGCACHE_MANAGED_BUILDKIT_LOG_PATH="$daemon_log_path" \
    BORINGCACHE_OBSERVABILITY_JSONL_PATH="$observability_path" \
    BORINGCACHE_MANAGED_BUILDKIT_IMAGE="$buildkit_image" \
    DOCKER_BUILDKIT=1 \
    boringcache docker \
      --backend state \
      --workspace "$workspace" \
      --tag "$cache_tag" \
      --tool-cache "turbo:${tool_cache_tag}" \
      --read-only \
      --no-platform \
      --no-git \
      --fail-on-cache-error \
      --metadata-hint "benchmark=posthog" \
      --metadata-hint "lane=${lane}" \
      --metadata-hint "phase=terminal-mount-probe" \
      --metadata-hint "source_sha=${source_sha}" \
      -- \
      docker buildx build \
        --file "$dockerfile_path" \
        --target boringcache-state-mount-probe \
        --no-cache-filter boringcache-state-mount-probe \
        --build-arg BORINGCACHE_STATE_MOUNT_PROBE=read-only \
        --platform "$docker_platform" \
        --progress plain \
        --output type=cacheonly \
        "$docker_context" 2>&1 | tee "$log_path"
  command_statuses=("${PIPESTATUS[@]}")
  set -e
  command_status="${command_statuses[0]}"
  tee_status="${command_statuses[1]}"
  phase_finished="$(date +%s)"

  snapshot_managed_resources > "$resources_after"
  comm -13 "$baseline_resources" "$resources_after" > "$resources_leaked"
  cleanup_valid=false
  [[ -s "$resources_leaked" ]] || cleanup_valid=true

  summary_valid=false
  if [[ -s "$state_summary_path" ]] && jq -e \
    --arg digest "$buildkit_digest" \
    --arg platform "$docker_platform" \
    --arg expected_generation "$expected_generation" \
    '.schema_version == "buildkit-state-summary.v3"
      and .compatibility.image_digest == $digest
      and .compatibility.platform == $platform
      and .compatibility.state_format == "buildkit-state-v1"
      and .compatibility.rootless == false
      and .restore.status == "restored"
      and .restore.generation == $expected_generation
      and .save.status == "read_only"
      and .save.publish_status == "read_only"
      and .save.generation == null
      and (.restore.lazy_content_blobs | type == "number")
      and .restore.lazy_content_blobs >= 0
      and (.restore.lazy_content_bytes | type == "number")
      and .restore.lazy_content_bytes >= 0
      and .save.lazy_content_runtime_status == "recorded"
      and .save.lazy_content_available_blobs == .restore.lazy_content_blobs
      and .save.lazy_content_available_bytes == .restore.lazy_content_bytes
      and .save.lazy_content_hydrated_blobs <= .save.lazy_content_available_blobs
      and .save.lazy_content_hydrated_bytes <= .save.lazy_content_available_bytes
      and .save.lazy_content_hydration_attempts >= .save.lazy_content_hydrated_blobs
      and .save.lazy_content_hydration_failures == 0
      and (.save.lazy_content_hydration_milliseconds | type == "number")
      and .save.lazy_content_hydration_milliseconds >= 0
      and .mount_cache.enabled == true
      and .mount_cache.runtime_status == "recorded"
      and .mount_cache.available_archives > 0
      and .mount_cache.available_bytes > 0
      and .mount_cache.restored_blobs == 0
      and .mount_cache.restored_archives == 0
      and .mount_cache.restored_bytes == 0
      and .mount_cache.generation_archives == 0
      and .mount_cache.staged_archives == 0
      and .mount_cache.released_archives == 0
      and .mount_cache.aborted_archives == 0
      and .mount_cache.selected_archives > 0
      and .mount_cache.selected_archives <= .mount_cache.available_archives
      and .mount_cache.hydrate_hits == 1
      and .mount_cache.hydrate_misses == 0
      and .mount_cache.hydrate_errors == 0
      and .mount_cache.hydrate_skips == 0
      and .mount_cache.hydrated_files > 0
      and .mount_cache.hydrated_compressed_bytes > 0
      and .mount_cache.hydrated_uncompressed_bytes > 0
      and .mount_cache.published_archives == 0
      and .mount_cache.publish_errors == 0' \
    "$state_summary_path" >/dev/null; then
    summary_valid=true
  fi

  success=false
  if [[ "$command_status" -eq 0 && "$tee_status" -eq 0 && "$summary_valid" == true && "$cleanup_valid" == true ]]; then
    success=true
  fi

  result_summary_path="$state_summary_path"
  if [[ ! -s "$result_summary_path" ]] || ! jq -e . "$result_summary_path" >/dev/null 2>&1; then
    result_summary_path="$artifact_dir/mount-probe.empty-summary.json"
    jq -n '{}' > "$result_summary_path"
  fi

  jq -n \
    --argjson phase_seconds "$((phase_finished - phase_started))" \
    --argjson command_status "$command_status" \
    --argjson tee_status "$tee_status" \
    --argjson summary_valid "$summary_valid" \
    --argjson cleanup_valid "$cleanup_valid" \
    --argjson success "$success" \
    --arg expected_generation "$expected_generation" \
    --slurpfile summary "$result_summary_path" \
    '{
      schema_version: "buildkit-state-mount-probe.v1",
      enabled: true,
      attempted: true,
      read_only: true,
      timing_included_in_product_phases: false,
      expected_generation: $expected_generation,
      restored_generation: ($summary[0].restore.generation // null),
      phase_seconds: $phase_seconds,
      command_status: $command_status,
      tee_status: $tee_status,
      signed_ref_archives: ($summary[0].mount_cache.available_archives // 0),
      selected_archives: ($summary[0].mount_cache.selected_archives // 0),
      eager_restored_blobs: ($summary[0].mount_cache.restored_blobs // 0),
      eager_restored_archives: ($summary[0].mount_cache.restored_archives // 0),
      eager_restored_bytes: ($summary[0].mount_cache.restored_bytes // 0),
      hydrate_hits: ($summary[0].mount_cache.hydrate_hits // 0),
      hydrate_misses: ($summary[0].mount_cache.hydrate_misses // 0),
      hydrate_errors: ($summary[0].mount_cache.hydrate_errors // 0),
      hydrate_skips: ($summary[0].mount_cache.hydrate_skips // 0),
      hydrated_compressed_bytes: ($summary[0].mount_cache.hydrated_compressed_bytes // 0),
      hydrated_uncompressed_bytes: ($summary[0].mount_cache.hydrated_uncompressed_bytes // 0),
      lazy_content: {
        signed_blobs: ($summary[0].restore.lazy_content_blobs // 0),
        signed_bytes: ($summary[0].restore.lazy_content_bytes // 0),
        hydrated_blobs: ($summary[0].save.lazy_content_hydrated_blobs // 0),
        hydrated_bytes: ($summary[0].save.lazy_content_hydrated_bytes // 0),
        hydration_attempts: ($summary[0].save.lazy_content_hydration_attempts // 0),
        hydration_failures: ($summary[0].save.lazy_content_hydration_failures // 0),
        hydration_milliseconds: ($summary[0].save.lazy_content_hydration_milliseconds // 0)
      },
      staged_archives: ($summary[0].mount_cache.staged_archives // 0),
      released_archives: ($summary[0].mount_cache.released_archives // 0),
      aborted_archives: ($summary[0].mount_cache.aborted_archives // 0),
      published_archives: ($summary[0].mount_cache.published_archives // 0),
      checks: {
        summary_valid: $summary_valid,
        managed_builder_destroyed: $cleanup_valid
      },
      valid: $success
    }' > "$mount_probe_result_path"
  [[ "$result_summary_path" == "$state_summary_path" ]] || rm -f "$result_summary_path"

  if [[ "$success" != true ]]; then
    echo "BuildKit state terminal mount-cache probe failed validation" >&2
    return 1
  fi
}

if [[ "$lane" == "fresh" ]]; then
  run_phase cold cold base "$source_sha" cold
  # Each state invocation owns and removes its builder, daemon, network, and
  # volume. The second phase proves remote restore into a new root. Cold-to-warm
  # movement is recorded separately as bootstrap convergence. Repeating the
  # exact SHA shows how many generations convergence takes; the
  # final warm-to-warm transition is the provisional plateau gate.
  for ((index = 1; index <= warm_generations; index++)); do
    phase="$(fresh_warm_phase_name "$index")"
    run_phase "$phase" warm warm1 "$source_sha" same-ref
  done
elif [[ "$lane" == "rolling" ]]; then
  run_phase rolling commit base "$source_sha" rolling
else
  selected_commits=()
  while IFS= read -r commit; do
    selected_commits+=("$commit")
  done < <(jq -r '.selected_commits[]' "$replay_plan_path")
  for index in "${!selected_commits[@]}"; do
    commit="${selected_commits[$index]}"
    printf -v phase 'replay-%03d-%s' "$((index + 1))" "${commit:0:12}"
    expectation=replay-successor
    if ((index == 0)); then
      expectation=replay-root
    fi
    run_phase "$phase" "generation-$((index + 1))" base "$commit" "$expectation"
  done
  last_index=$((${#selected_commits[@]} - 1))
  commit="${selected_commits[$last_index]}"
  phase="replay-repeat-${commit:0:12}"
  run_phase "$phase" "generation-repeat" base "$commit" replay-successor
fi

if [[ "$composition_mode" == fixture ]]; then
  run_terminal_mount_probe
fi

write_combined_result
trap - EXIT
jq -e '.success == true' "$artifact_dir/canary-result.json" >/dev/null || {
  echo "BuildKit state current-set/growth contract failed" >&2
  exit 1
}
