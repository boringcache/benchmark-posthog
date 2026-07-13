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
    mountcache_enabled: ($composition_mode == "fixture")
  }' > "$artifact_dir/inputs.json"

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
    --arg lane "$lane" \
    --argjson tolerance "$plateau_tolerance_percent" \
    --argjson warm_generations "$warm_generations" \
    'def absolute_delta_within_tolerance($delta; $limit):
       if (($delta | type) == "number" and ($limit | type) == "number") then
         (($delta | if . < 0 then -. else . end) <= $limit)
       else
         false
       end;
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
          | ($current.state.logical_generation_blobs - $previous.state.logical_generation_blobs) as $blob_delta
          | ($current.state.logical_generation_bytes - $previous.state.logical_generation_bytes) as $byte_delta
          | (($previous.state.logical_generation_blobs * $tolerance / 100) | ceil) as $blob_tolerance
          | (($previous.state.logical_generation_bytes * $tolerance / 100) | ceil) as $byte_tolerance
          | {
              transition_index: $index,
              from_phase: $previous.phase,
              to_phase: $current.phase,
              kind: (if $index == 1 then "bootstrap" else "same-ref" end),
              final_convergence_pair: ($index == (($base.phases | length) - 1) and $index > 1),
              lineage: {
                previous_generation: $previous.state.generation,
                restored_generation: $current.state.restored_generation,
                parent_generation: $current.state.parent_generation,
                current_generation: $current.state.generation,
                valid: (
                  $current.state.restore_status == "restored"
                  and $current.state.restored_generation == $previous.state.generation
                  and $current.state.parent_generation == $previous.state.generation
                )
              },
              current_head_only: (
                $current.state.head_generations_fetched == 1
                and $current.checks.current_head_only
              ),
              solver_reuse: (
                $current.cached_steps > $cold.cached_steps
                and $current.executed_steps < $cold.executed_steps
              ),
              logical_set: {
                previous_blobs: $previous.state.logical_generation_blobs,
                previous_bytes: $previous.state.logical_generation_bytes,
                current_blobs: $current.state.logical_generation_blobs,
                current_bytes: $current.state.logical_generation_bytes,
                blob_delta: $blob_delta,
                byte_delta: $byte_delta,
                blob_delta_percent: (
                  if $previous.state.logical_generation_blobs == 0 then null
                  else (($blob_delta * 10000 / $previous.state.logical_generation_blobs) | round) / 100
                  end
                ),
                byte_delta_percent: (
                  if $previous.state.logical_generation_bytes == 0 then null
                  else (($byte_delta * 10000 / $previous.state.logical_generation_bytes) | round) / 100
                  end
                ),
                blob_tolerance: $blob_tolerance,
                byte_tolerance: $byte_tolerance,
                within_tolerance: (
                  absolute_delta_within_tolerance($blob_delta; $blob_tolerance)
                  and absolute_delta_within_tolerance($byte_delta; $byte_tolerance)
                ),
                positive_growth_within_tolerance: (
                  $blob_delta <= $blob_tolerance
                  and $byte_delta <= $byte_tolerance
                )
              }
            }
        ] as $transitions
        | ($transitions[0] // null) as $bootstrap
        | ($transitions[-1] // null) as $final_transition
        | ($warm_phases[0] // null) as $warm
        | ($warm_phases[1] // null) as $repeat
        | ((($warm_phases | length) == $warm_generations)
            and all($warm_phases[];
              .cached_steps > $cold.cached_steps
              and .executed_steps < $cold.executed_steps
            )) as $all_warm_solver_reuse
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
              and $bootstrap.logical_set.positive_growth_within_tolerance
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
            same_ref_plateau: ($final_transition.logical_set.within_tolerance // false),
            same_ref_solver_reuse: $all_warm_solver_reuse,
            same_ref_first_warm_solver_reuse: ($transitions[0].solver_reuse // false),
            same_ref_repeat_solver_reuse: ($transitions[1].solver_reuse // false),
            transitions: $transitions,
            growth: {
              tolerance_percent: $tolerance,
              bootstrap_logical_blob_delta: $bootstrap.logical_set.blob_delta,
              bootstrap_logical_byte_delta: $bootstrap.logical_set.byte_delta,
              bootstrap_blob_growth_within_tolerance: (
                (($bootstrap.logical_set.blob_delta | type) == "number")
                and (($bootstrap.logical_set.blob_tolerance | type) == "number")
                and ($bootstrap.logical_set.blob_delta <= $bootstrap.logical_set.blob_tolerance)
              ),
              bootstrap_bytes_growth_within_tolerance: (
                (($bootstrap.logical_set.byte_delta | type) == "number")
                and (($bootstrap.logical_set.byte_tolerance | type) == "number")
                and ($bootstrap.logical_set.byte_delta <= $bootstrap.logical_set.byte_tolerance)
              ),
              logical_blob_delta: $final_transition.logical_set.blob_delta,
              logical_byte_delta: $final_transition.logical_set.byte_delta,
              blob_count_within_tolerance: absolute_delta_within_tolerance(
                $final_transition.logical_set.blob_delta;
                $final_transition.logical_set.blob_tolerance
              ),
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
              and (
                ($rolling.state.restore_status == "miss" and $rolling.state.parent_generation == null)
                or (
                  $rolling.state.restore_status == "restored"
                  and $rolling.state.parent_generation == $rolling.state.restored_generation
                )
              )
            ),
            only_current_head_fetched: ($rolling.checks.current_head_only),
            same_ref_plateau: null,
            same_ref_solver_reuse: null,
            growth: null
          }
      else
        ($base.phases) as $phases
        | [range(0; ($phases | length)) as $index
          | $phases[$index] as $phase
          | (if $index == 0 then null else $phases[$index - 1] end) as $previous
          | (if $previous == null then null else
               ($phase.state.logical_generation_blobs - $previous.state.logical_generation_blobs)
             end) as $blob_delta
          | (if $previous == null then null else
               ($phase.state.logical_generation_bytes - $previous.state.logical_generation_bytes)
             end) as $byte_delta
          | (if $previous == null then null else
               (($blob_delta | if . < 0 then -. else . end) <=
                 ((($previous.state.logical_generation_blobs * $tolerance / 100)) | ceil))
             end) as $blob_plateau
          | (if $previous == null then null else
               (($byte_delta | if . < 0 then -. else . end) <=
                 ((($previous.state.logical_generation_bytes * $tolerance / 100)) | ceil))
             end) as $byte_plateau
          | {
              sequence_index: ($index + 1),
              source_sha: $phase.source_sha,
              generation: $phase.state.generation,
              restored_generation: $phase.state.restored_generation,
              parent_generation: $phase.state.parent_generation,
              current_head_only: $phase.checks.current_head_only,
              continuity: (
                if $previous == null then
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
                blob_delta_from_previous: $blob_delta,
                byte_delta_from_previous: $byte_delta,
                blob_delta_percent: (
                  if $previous == null or $previous.state.logical_generation_blobs == 0 then null
                  else (($blob_delta * 10000 / $previous.state.logical_generation_blobs) | round) / 100
                  end
                ),
                byte_delta_percent: (
                  if $previous == null or $previous.state.logical_generation_bytes == 0 then null
                  else (($byte_delta * 10000 / $previous.state.logical_generation_bytes) | round) / 100
                  end
                ),
                within_previous_tolerance: (
                  if $previous == null then null else ($blob_plateau and $byte_plateau) end
                )
              },
              transport_delta: {
                blobs: $phase.state.transport_delta_blobs,
                bytes: $phase.state.transport_delta_bytes
              }
            }
        ] as $generations
        | {
            current_set_replacement: (
              ($generations | length) == ($inputs[0].replay.selected_commits | length)
              and all($generations[];
                .continuity
                and .current_head_only
                and .logical_set.blobs > 0
                and .logical_set.bytes > 0)
            ),
            only_current_head_fetched: all($generations[]; .current_head_only),
            exact_source_sequence: (
              ($generations | map(.source_sha)) == $inputs[0].replay.selected_commits
            ),
            same_ref_plateau: null,
            same_ref_solver_reuse: null,
            growth: null,
            replay: {
              mode: $lane,
              planned_generations: ($inputs[0].replay.all_commits | length),
              measured_generations: ($generations | length),
              tolerance_percent: $tolerance,
              all_successors_within_tolerance: all(
                $generations[1:][];
                .logical_set.within_previous_tolerance == true
              ),
              generations: $generations
            }
          }
      end) as $current_set
    | (if $inputs[0].composition_mode == "fixture" then
        {
          mode: "fixture",
          tool_env_delivery: $inputs[0].tool_env_delivery,
          mountcache_published: any(
            $base.phases[];
            ((.state.mount_cache.published_archives // 0) > 0)
          ),
          mountcache_restored: any(
            $base.phases[];
            ((.state.mount_cache.restored_archives // 0) > 0)
          ),
          mountcache_hydrated: any(
            $base.phases[];
            ((.state.mount_cache.hydrate_hits // 0) > 0)
          ),
          toolcache_exercised: any(
            $base.phases[];
            (((.tool_cache.hits // 0) + (.tool_cache.misses // 0) + (.tool_cache.writes // 0)) > 0)
          ),
          toolcache_hits: any(
            $base.phases[];
            ((.tool_cache.hits // 0) > 0)
          )
        }
        | .valid = (
            .mountcache_published
            and .mountcache_restored
            and .toolcache_exercised
            and .toolcache_hits
          )
      else
        {
          mode: "off",
          tool_env_delivery: "none",
          mountcache_published: false,
          mountcache_restored: false,
          mountcache_hydrated: false,
          toolcache_exercised: false,
          toolcache_hits: false,
          valid: true
        }
      end) as $composition
    | {
        schema_version: "buildkit-state-canary-result.v2",
        inputs: $inputs[0],
        success: (
          $base.all_phases_valid
          and $current_set.current_set_replacement
          and $current_set.only_current_head_fetched
          and ($current_set.exact_source_sequence != false)
          and ($current_set.same_ref_solver_reuse != false)
          and $composition.valid
        ),
        current_set: $current_set,
        composition: $composition,
        phases: $base.phases
      }' "${phase_files[@]}" > "$result"
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

  rm -f \
    "$log_path" \
    "$daemon_log_path" \
    "$observability_path" \
    "$state_summary_path" \
    "$phase_result_path" \
    "$resources_after" \
    "$resources_leaked"

  local phase_started phase_finished command_status tee_status
  local composition_args=(--metadata-hint "composition=${composition_mode}")
  if [[ "$composition_mode" == fixture ]]; then
    composition_args=(--tool-cache "turbo:${tool_cache_tag}" "${composition_args[@]}")
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

  local cached_steps executed_steps state_overhead restore_status publish_status
  local restored_bytes restored_files logical_bytes logical_blobs transport_delta_bytes transport_delta_blobs
  local restored_generation generation parent_generation head_generations_fetched
  local finalize_eligible finalize_already_ready finalize_materialized finalize_failed finalize_required_blobs
  local finalize_seconds retention_policy content_gc_applied content_gc_duration_ms
  local records_before_gc records_after_gc content_gc_seconds
  local mount_cache_json tool_cache_json
  local summary_valid tool_cache_valid cleanup_valid expectation_valid current_head_only success
  cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$log_path" || true)"
  executed_steps="$(grep -Ec '^#[0-9]+ DONE ([0-9]+([.][0-9]+)?)s$' "$log_path" || true)"
  state_overhead=""
  restore_status="missing"
  publish_status="missing"
  restored_bytes="0"
  restored_files="0"
  logical_bytes="0"
  logical_blobs="0"
  transport_delta_bytes="0"
  transport_delta_blobs="0"
  restored_generation=""
  generation=""
  parent_generation=""
  finalize_eligible="0"
  finalize_already_ready="0"
  finalize_materialized="0"
  finalize_failed="0"
  finalize_required_blobs="0"
  finalize_seconds=""
  retention_policy=""
  content_gc_applied=false
  content_gc_duration_ms="0"
  records_before_gc="0"
  records_after_gc="0"
  content_gc_seconds=""
  mount_cache_json=null
  tool_cache_json=null
  head_generations_fetched="0"
  summary_valid=false
  tool_cache_valid=false
  cleanup_valid=false
  expectation_valid=false
  current_head_only=false

  if [[ -s "$state_summary_path" ]] && jq -e \
    --arg digest "$buildkit_digest" \
    --arg platform "$docker_platform" \
    --arg composition_mode "$composition_mode" \
    '.schema_version == "buildkit-state-summary.v2"
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
      and .finalize.retention_policy == "complete-main-cache-v1"
      and .finalize.content_gc_applied == true
      and (.finalize.content_gc_duration_ms | type == "number")
      and .finalize.content_gc_duration_ms >= 0
      and (.finalize.records_before_gc | type == "number")
      and (.finalize.records_after_gc | type == "number")
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
      and (.save.uploaded_blobs | type == "number")
      and .save.uploaded_blobs >= 0
      and (.save.uploaded_bytes | type == "number")
      and .save.uploaded_bytes >= 0
      and (.total_state_overhead_seconds | type == "number")
      and .total_state_overhead_seconds >= 0
      and (if $composition_mode == "fixture" then
             .mount_cache.enabled == true
             and .mount_cache.runtime_status == "recorded"
             and .mount_cache.hydrate_errors == 0
             and .mount_cache.publish_errors == 0
             and .mount_cache.generation_archives == .mount_cache.selected_archives
           else
             .mount_cache.enabled == false
             and .mount_cache.runtime_status == "disabled"
             and .mount_cache.generation_archives == 0
           end)' \
    "$state_summary_path" >/dev/null; then
    summary_valid=true
    state_overhead="$(jq -r '.total_state_overhead_seconds' "$state_summary_path")"
    restore_status="$(jq -r '.restore.status' "$state_summary_path")"
    publish_status="$(jq -r '.save.publish_status' "$state_summary_path")"
    restored_bytes="$(jq -r '.restore.bytes' "$state_summary_path")"
    restored_files="$(jq -r '.restore.files' "$state_summary_path")"
    logical_bytes="$(jq -r '.save.logical_generation_bytes' "$state_summary_path")"
    logical_blobs="$(jq -r '.save.logical_generation_blobs' "$state_summary_path")"
    transport_delta_bytes="$(jq -r '.save.uploaded_bytes' "$state_summary_path")"
    transport_delta_blobs="$(jq -r '.save.uploaded_blobs' "$state_summary_path")"
    restored_generation="$(jq -r '.restore.generation // ""' "$state_summary_path")"
    generation="$(jq -r '.save.generation // ""' "$state_summary_path")"
    parent_generation="$(jq -r '.save.parent // ""' "$state_summary_path")"
    finalize_eligible="$(jq -r '.finalize.eligible' "$state_summary_path")"
    finalize_already_ready="$(jq -r '.finalize.already_ready' "$state_summary_path")"
    finalize_materialized="$(jq -r '.finalize.materialized' "$state_summary_path")"
    finalize_failed="$(jq -r '.finalize.failed' "$state_summary_path")"
    finalize_required_blobs="$(jq -r '.finalize.required_blobs' "$state_summary_path")"
    finalize_seconds="$(jq -r '.finalize.seconds' "$state_summary_path")"
    retention_policy="$(jq -r '.finalize.retention_policy' "$state_summary_path")"
    content_gc_applied="$(jq -r '.finalize.content_gc_applied' "$state_summary_path")"
    content_gc_duration_ms="$(jq -r '.finalize.content_gc_duration_ms' "$state_summary_path")"
    records_before_gc="$(jq -r '.finalize.records_before_gc' "$state_summary_path")"
    records_after_gc="$(jq -r '.finalize.records_after_gc' "$state_summary_path")"
    content_gc_seconds="$(jq -r '.content_gc_seconds' "$state_summary_path")"
    mount_cache_json="$(jq -c '.mount_cache' "$state_summary_path")"
    if [[ "$restore_status" == "restored" ]]; then
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
       [[ "$restore_status" == "restored" && "$head_generations_fetched" -eq 1 && -n "$restored_generation" ]]; }; then
    current_head_only=true
  fi

  if [[ ! -s "$resources_leaked" ]]; then
    cleanup_valid=true
  fi

  case "$expectation" in
    cold|replay-root)
      if [[ "$restore_status" == "miss" && -z "$parent_generation" && "$logical_blobs" -gt 0 && "$logical_bytes" -gt 0 ]]; then
        expectation_valid=true
      fi
      ;;
    same-ref|replay-successor)
      if [[ "$restore_status" == "restored" && "$parent_generation" == "$restored_generation" && "$logical_blobs" -gt 0 && "$logical_bytes" -gt 0 ]]; then
        expectation_valid=true
      fi
      ;;
    rolling)
      if [[ "$logical_blobs" -gt 0 && "$logical_bytes" -gt 0 ]] && \
         { [[ "$restore_status" == "miss" && -z "$parent_generation" ]] || \
           [[ "$restore_status" == "restored" && "$parent_generation" == "$restored_generation" ]]; }; then
        expectation_valid=true
      fi
      ;;
  esac

  success=false
  if [[ "$command_status" -eq 0 && "$tee_status" -eq 0 && "$summary_valid" == true && "$tool_cache_valid" == true && "$cleanup_valid" == true && "$expectation_valid" == true && "$current_head_only" == true ]]; then
    success=true
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
    --argjson restored_bytes "$restored_bytes" \
    --argjson restored_files "$restored_files" \
    --arg restored_generation "$restored_generation" \
    --arg generation "$generation" \
    --arg parent_generation "$parent_generation" \
    --argjson logical_bytes "$logical_bytes" \
    --argjson logical_blobs "$logical_blobs" \
    --argjson transport_delta_bytes "$transport_delta_bytes" \
    --argjson transport_delta_blobs "$transport_delta_blobs" \
    --argjson finalize_eligible "$finalize_eligible" \
    --argjson finalize_already_ready "$finalize_already_ready" \
    --argjson finalize_materialized "$finalize_materialized" \
    --argjson finalize_failed "$finalize_failed" \
    --argjson finalize_required_blobs "$finalize_required_blobs" \
    --arg finalize_seconds "$finalize_seconds" \
    --arg retention_policy "$retention_policy" \
    --argjson content_gc_applied "$content_gc_applied" \
    --argjson content_gc_duration_ms "$content_gc_duration_ms" \
    --argjson records_before_gc "$records_before_gc" \
    --argjson records_after_gc "$records_after_gc" \
    --arg content_gc_seconds "$content_gc_seconds" \
    --argjson mount_cache "$mount_cache_json" \
    --argjson tool_cache "$tool_cache_json" \
    --argjson head_generations_fetched "$head_generations_fetched" \
    --argjson summary_valid "$summary_valid" \
    --argjson tool_cache_valid "$tool_cache_valid" \
    --argjson cleanup_valid "$cleanup_valid" \
    --argjson expectation_valid "$expectation_valid" \
    --argjson current_head_only "$current_head_only" \
    --argjson success "$success" \
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
        restored_bytes: $restored_bytes,
        restored_files: $restored_files,
        restored_generation: (if $restored_generation == "" then null else $restored_generation end),
        head_generations_fetched: $head_generations_fetched,
        generation: (if $generation == "" then null else $generation end),
        parent_generation: (if $parent_generation == "" then null else $parent_generation end),
        logical_generation_bytes: $logical_bytes,
        logical_generation_blobs: $logical_blobs,
        transport_delta_bytes: $transport_delta_bytes,
        transport_delta_blobs: $transport_delta_blobs,
        finalize: {
          eligible: $finalize_eligible,
          already_ready: $finalize_already_ready,
          materialized: $finalize_materialized,
          failed: $finalize_failed,
          required_blobs: $finalize_required_blobs,
          seconds: (if $finalize_seconds == "" then null else ($finalize_seconds | tonumber) end),
          retention_policy: $retention_policy,
          content_gc_applied: $content_gc_applied,
          content_gc_duration_ms: $content_gc_duration_ms,
          records_before_gc: $records_before_gc,
          records_after_gc: $records_after_gc
        },
        content_gc_seconds: (if $content_gc_seconds == "" then null else ($content_gc_seconds | tonumber) end),
        mount_cache: $mount_cache
      },
      tool_cache: $tool_cache,
      checks: {
        summary_valid: $summary_valid,
        tool_cache_valid: $tool_cache_valid,
        managed_builder_destroyed: $cleanup_valid,
        phase_expectation_valid: $expectation_valid,
        current_head_only: $current_head_only
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
fi

write_combined_result
trap - EXIT
jq -e '.success == true' "$artifact_dir/canary-result.json" >/dev/null || {
  echo "BuildKit state current-set/growth contract failed" >&2
  exit 1
}
