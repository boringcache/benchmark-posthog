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
buildkit_image="$BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE"
artifact_dir="$BORINGCACHE_STATE_CANARY_ARTIFACT_DIR"
api_origin="$BORINGCACHE_API_URL"
dockerfile_path="${BORINGCACHE_STATE_CANARY_DOCKERFILE:-upstream/Dockerfile}"
docker_context="${BORINGCACHE_STATE_CANARY_CONTEXT:-upstream}"
docker_platform="${BORINGCACHE_STATE_CANARY_PLATFORM:-linux/amd64}"
image_tag_prefix="${BORINGCACHE_STATE_CANARY_IMAGE_TAG:-posthog-state-canary}"
plateau_tolerance_percent="${BORINGCACHE_STATE_CANARY_PLATEAU_TOLERANCE_PERCENT:-2}"
replay_plan_path="${BORINGCACHE_STATE_CANARY_REPLAY_PLAN:-}"

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
if [[ "${BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER:-0}" =~ ^(1|true|yes|on)$ ]]; then
  echo "BuildKit mountcache offload is not part of the core state canary" >&2
  exit 2
fi
export BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER=0

for tool in boringcache docker git jq tar tee; do
  command -v "$tool" >/dev/null || {
    echo "Required command is unavailable: ${tool}" >&2
    exit 2
  }
done

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

file_size() {
  local path="$1"
  if stat -c %s "$path" >/dev/null 2>&1; then
    stat -c %s "$path"
  else
    stat -f %z "$path"
  fi
}

extract_oci_semantics() (
  set -euo pipefail
  local archive="$1"
  local output="$2"
  local layout index_path manifest_digest manifest_hex manifest_path manifest_size
  local config_digest config_hex config_path config_size digest size blob_path

  [[ -s "$archive" ]] || {
    echo "OCI output archive is missing: ${archive}" >&2
    exit 1
  }
  layout="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/buildkit-state-oci.XXXXXX")"
  trap 'rm -rf "$layout"' EXIT
  tar -xf "$archive" -C "$layout"
  index_path="$layout/index.json"
  [[ -s "$index_path" ]] || {
    echo "OCI output has no index.json: ${archive}" >&2
    exit 1
  }

  manifest_digest="$(jq -r '
    ([.manifests[] | select((.platform.os // "") != "unknown")][0].digest) //
    .manifests[0].digest // empty
  ' "$index_path")"
  [[ "$manifest_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "OCI output has no canonical image manifest digest" >&2
    exit 1
  }
  manifest_hex="${manifest_digest#sha256:}"
  manifest_path="$layout/blobs/sha256/$manifest_hex"
  [[ -s "$manifest_path" && "$(sha256_file "$manifest_path")" == "$manifest_hex" ]] || {
    echo "OCI image manifest is missing or has the wrong digest" >&2
    exit 1
  }
  manifest_size="$(jq -r --arg digest "$manifest_digest" '.manifests[] | select(.digest == $digest) | .size' "$index_path")"
  [[ "$manifest_size" =~ ^[0-9]+$ && "$(file_size "$manifest_path")" == "$manifest_size" ]] || {
    echo "OCI image manifest descriptor size is invalid" >&2
    exit 1
  }

  config_digest="$(jq -r '.config.digest // empty' "$manifest_path")"
  [[ "$config_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "OCI image manifest has no canonical config digest" >&2
    exit 1
  }
  config_hex="${config_digest#sha256:}"
  config_path="$layout/blobs/sha256/$config_hex"
  [[ -s "$config_path" && "$(sha256_file "$config_path")" == "$config_hex" ]] || {
    echo "OCI image config is missing or has the wrong digest" >&2
    exit 1
  }
  config_size="$(jq -r '.config.size // empty' "$manifest_path")"
  [[ "$config_size" =~ ^[0-9]+$ && "$(file_size "$config_path")" == "$config_size" ]] || {
    echo "OCI image config descriptor size is invalid" >&2
    exit 1
  }

  while IFS=$'\t' read -r digest size; do
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ ]] || {
      echo "OCI image has an invalid layer descriptor" >&2
      exit 1
    }
    blob_path="$layout/blobs/sha256/${digest#sha256:}"
    [[ -s "$blob_path" ]] || {
      echo "OCI image is missing layer ${digest}" >&2
      exit 1
    }
    [[ "$(sha256_file "$blob_path")" == "${digest#sha256:}" ]] || {
      echo "OCI layer digest mismatch for ${digest}" >&2
      exit 1
    }
    [[ "$(file_size "$blob_path")" == "$size" ]] || {
      echo "OCI layer size mismatch for ${digest}" >&2
      exit 1
    }
  done < <(jq -r '.layers[] | [.digest, .size] | @tsv' "$manifest_path")

  jq -S -n \
    --slurpfile manifest "$manifest_path" \
    --slurpfile config "$config_path" \
    --arg manifest_digest "$manifest_digest" \
    --arg config_digest "$config_digest" '
      {
        image_manifest_digest: $manifest_digest,
        config_digest: $config_digest,
        platform: {
          os: $config[0].os,
          architecture: $config[0].architecture,
          variant: ($config[0].variant // null)
        },
        layers: ($manifest[0].layers | map({
          media_type: .mediaType,
          digest: .digest,
          size: .size
        })),
        diff_ids: $config[0].rootfs.diff_ids,
        runtime: {
          entrypoint: ($config[0].config.Entrypoint // null),
          cmd: ($config[0].config.Cmd // null),
          working_dir: ($config[0].config.WorkingDir // null),
          env: ($config[0].config.Env // [])
        }
      }
    ' > "$output"
  jq -e '
    (.image_manifest_digest | test("^sha256:[0-9a-f]{64}$"))
    and (.config_digest | test("^sha256:[0-9a-f]{64}$"))
    and (.layers | type == "array")
    and (.diff_ids | type == "array")
    and ((.layers | length) > 0)
    and ((.layers | length) == (.diff_ids | length))
    and all(.layers[]; (.digest | test("^sha256:[0-9a-f]{64}$")) and (.size > 0))
    and all(.diff_ids[]; test("^sha256:[0-9a-f]{64}$"))
  ' "$output" >/dev/null
)

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
  '{
    schema_version: $schema_version,
    lane: $lane,
    workspace: $workspace,
    cache_tag: $cache_tag,
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
    mountcache_enabled: false
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

write_combined_result() {
  local result="$artifact_dir/canary-result.json"
  local phase_files=()
  while IFS= read -r path; do
    phase_files+=("$path")
  done < <(find "$artifact_dir" -maxdepth 1 -name '*.phase.json' -type f | LC_ALL=C sort)

  if ((${#phase_files[@]} == 0)); then
    jq -n \
      --slurpfile inputs "$artifact_dir/inputs.json" \
      '{schema_version: "buildkit-state-canary-result.v1", inputs: $inputs[0], success: false, phases: []}' \
      > "$result"
    return
  fi

  jq -s \
    --slurpfile inputs "$artifact_dir/inputs.json" \
    --arg lane "$lane" \
    --argjson tolerance "$plateau_tolerance_percent" \
    '{
      phases: .,
      all_phases_valid: (length > 0 and all(.[]; .success == true))
    }
    | . as $base
    | (if $lane == "fresh" then
        ($base.phases | map(select(.phase == "cold"))[0]) as $cold
        | ($base.phases | map(select(.phase == "same-ref-warm"))[0]) as $warm
        | (($warm.state.logical_generation_blobs // 0) - ($cold.state.logical_generation_blobs // 0)) as $blob_delta
        | (($warm.state.logical_generation_bytes // 0) - ($cold.state.logical_generation_bytes // 0)) as $byte_delta
        | (($blob_delta | if . < 0 then -. else . end) <= (((($cold.state.logical_generation_blobs // 0) * $tolerance / 100)) | ceil)) as $blob_plateau
        | (($byte_delta | if . < 0 then -. else . end) <= (((($cold.state.logical_generation_bytes // 0) * $tolerance / 100)) | ceil)) as $byte_plateau
        | {
            current_set_replacement: (
              $cold != null
              and $warm != null
              and $cold.state.logical_generation_blobs > 0
              and $cold.state.logical_generation_bytes > 0
              and $warm.state.parent_generation == $cold.state.generation
              and $warm.state.restored_generation == $cold.state.generation
              and $warm.state.head_generations_fetched == 1
              and $blob_plateau
              and $byte_plateau
            ),
            only_current_head_fetched: ($warm.state.head_generations_fetched == 1),
            same_ref_plateau: ($blob_plateau and $byte_plateau),
            same_ref_solver_reuse: (
              $warm.cached_steps > $cold.cached_steps
              and $warm.executed_steps < $cold.executed_steps
            ),
            same_ref_oci_semantics_equal: (
              $cold.oci.semantic_sha256 != null
              and $cold.oci.semantic_sha256 == $warm.oci.semantic_sha256
            ),
            growth: {
              tolerance_percent: $tolerance,
              logical_blob_delta: $blob_delta,
              logical_byte_delta: $byte_delta,
              blob_count_within_tolerance: $blob_plateau,
              bytes_within_tolerance: $byte_plateau
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
            same_ref_oci_semantics_equal: null,
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
              },
              oci: {
                semantic_sha256: $phase.oci.semantic_sha256,
                changed_from_previous: (
                  if $previous == null then null
                  else $phase.oci.semantic_sha256 != $previous.oci.semantic_sha256
                  end
                )
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
            same_ref_oci_semantics_equal: null,
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
    | {
        schema_version: "buildkit-state-canary-result.v1",
        inputs: $inputs[0],
        success: (
          $base.all_phases_valid
          and $current_set.current_set_replacement
          and $current_set.only_current_head_fetched
          and ($current_set.exact_source_sequence != false)
          and ($current_set.same_ref_solver_reuse != false)
          and ($current_set.same_ref_oci_semantics_equal != false)
        ),
        current_set: $current_set,
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
  local oci_archive_path="$artifact_dir/${phase}.oci.tar"
  local oci_semantics_path="$artifact_dir/${phase}.oci-semantics.json"
  local oci_semantic_sha_path="$artifact_dir/${phase}.oci-semantic.sha256"
  local oci_archive_sha_path="$artifact_dir/${phase}.oci-archive.sha256"
  local phase_result_path="$artifact_dir/${phase}.phase.json"
  local resources_after="$artifact_dir/${phase}.managed-resources.after.txt"
  local resources_leaked="$artifact_dir/${phase}.managed-resources.leaked.txt"
  local phase_image_tag="${image_tag_prefix}:${phase}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

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
    "$oci_archive_path" \
    "$oci_semantics_path" \
    "$oci_semantic_sha_path" \
    "$oci_archive_sha_path" \
    "$phase_result_path" \
    "$resources_after" \
    "$resources_leaked"

  local phase_started phase_finished command_status tee_status
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
        --tag "$phase_image_tag" \
        --platform "$docker_platform" \
        --build-arg SOURCE_DATE_EPOCH=0 \
        --progress plain \
        --output "type=oci,dest=${oci_archive_path},rewrite-timestamp=true" \
        "$docker_context" 2>&1 | tee "$log_path"
  command_statuses=("${PIPESTATUS[@]}")
  set -e
  command_status="${command_statuses[0]}"
  tee_status="${command_statuses[1]}"
  phase_finished="$(date +%s)"

  local oci_valid oci_semantic_sha oci_archive_sha oci_archive_bytes oci_validation_started oci_validation_seconds
  oci_valid=false
  oci_semantic_sha=""
  oci_archive_sha=""
  oci_archive_bytes="0"
  oci_validation_started="$(date +%s)"
  if [[ "$command_status" -eq 0 && "$tee_status" -eq 0 ]] && \
     extract_oci_semantics "$oci_archive_path" "$oci_semantics_path"; then
    oci_semantic_sha="$(sha256_file "$oci_semantics_path")"
    oci_archive_sha="$(sha256_file "$oci_archive_path")"
    oci_archive_bytes="$(file_size "$oci_archive_path")"
    printf '%s\n' "$oci_semantic_sha" > "$oci_semantic_sha_path"
    printf '%s\n' "$oci_archive_sha" > "$oci_archive_sha_path"
    oci_valid=true
  fi
  oci_validation_seconds="$(( $(date +%s) - oci_validation_started ))"

  snapshot_managed_resources > "$resources_after"
  comm -13 "$baseline_resources" "$resources_after" > "$resources_leaked"

  local cached_steps executed_steps state_overhead restore_status publish_status
  local restored_bytes restored_files logical_bytes logical_blobs transport_delta_bytes transport_delta_blobs
  local restored_generation generation parent_generation pruned_records pruned_bytes head_generations_fetched
  local summary_valid cleanup_valid expectation_valid current_head_only success
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
  pruned_records="0"
  pruned_bytes="0"
  head_generations_fetched="0"
  summary_valid=false
  cleanup_valid=false
  expectation_valid=false
  current_head_only=false

  if [[ -s "$state_summary_path" ]] && jq -e \
    --arg digest "$buildkit_digest" \
    --arg platform "$docker_platform" \
    '.schema_version == "buildkit-state-summary.v1"
      and .compatibility.image_digest == $digest
      and .compatibility.platform == $platform
      and .compatibility.state_format == "buildkit-state-v1"
      and .compatibility.rootless == false
      and .finalize.failed == 0
      and (.finalize.pruned_records | type == "number")
      and .finalize.pruned_records >= 0
      and (.finalize.pruned_bytes | type == "number")
      and .finalize.pruned_bytes >= 0
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
      and .total_state_overhead_seconds >= 0' \
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
    pruned_records="$(jq -r '.finalize.pruned_records' "$state_summary_path")"
    pruned_bytes="$(jq -r '.finalize.pruned_bytes' "$state_summary_path")"
    if [[ "$restore_status" == "restored" ]]; then
      head_generations_fetched=1
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
  if [[ "$command_status" -eq 0 && "$tee_status" -eq 0 && "$summary_valid" == true && "$cleanup_valid" == true && "$expectation_valid" == true && "$current_head_only" == true && "$oci_valid" == true ]]; then
    success=true
  fi

  jq -n \
    --arg schema_version "buildkit-state-canary-phase.v1" \
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
    --argjson pruned_records "$pruned_records" \
    --argjson pruned_bytes "$pruned_bytes" \
    --argjson head_generations_fetched "$head_generations_fetched" \
    --argjson summary_valid "$summary_valid" \
    --argjson cleanup_valid "$cleanup_valid" \
    --argjson expectation_valid "$expectation_valid" \
    --argjson current_head_only "$current_head_only" \
    --arg oci_semantic_sha "$oci_semantic_sha" \
    --arg oci_archive_sha "$oci_archive_sha" \
    --argjson oci_archive_bytes "$oci_archive_bytes" \
    --argjson oci_validation_seconds "$oci_validation_seconds" \
    --argjson oci_valid "$oci_valid" \
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
        pruned_records: $pruned_records,
        pruned_bytes: $pruned_bytes
      },
      checks: {
        summary_valid: $summary_valid,
        managed_builder_destroyed: $cleanup_valid,
        phase_expectation_valid: $expectation_valid,
        current_head_only: $current_head_only
      },
      oci: {
        valid: $oci_valid,
        archive_sha256: (if $oci_archive_sha == "" then null else $oci_archive_sha end),
        archive_bytes: $oci_archive_bytes,
        validation_seconds: $oci_validation_seconds,
        semantic_sha256: (if $oci_semantic_sha == "" then null else $oci_semantic_sha end)
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
  # volume. The second phase therefore proves remote restore into a new root.
  run_phase same-ref-warm warm warm1 "$source_sha" same-ref
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
