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

boringcache() {
  if [[ "${1:-}" == "--version" ]]; then
    echo "boringcache mock-state-canary"
    return 0
  fi

  local phase restore_status restored_generation parent generation logical_blobs logical_bytes
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
      transport_blobs=100
      transport_bytes=100000
      ;;
    *same-ref-warm.state-summary.json)
      phase=same-ref-warm
      restore_status=restored
      restored_generation="$cold_generation"
      parent="$cold_generation"
      generation="$warm_generation"
      logical_blobs=$((100 + ${MOCK_STATE_GROWTH_PERCENT:-1}))
      logical_bytes=$((100000 + (${MOCK_STATE_GROWTH_PERCENT:-1} * 1000)))
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
    --argjson transport_blobs "$transport_blobs" \
    --argjson transport_bytes "$transport_bytes" \
    --argjson include_logical_generation "$(if [[ "${MOCK_OMIT_LOGICAL_GENERATION:-0}" == 1 ]]; then echo false; else echo true; fi)" \
    '{
      schema_version: "buildkit-state-summary.v1",
      restore: {
        status: $restore_status,
        generation: (if $restored_generation == "" then null else $restored_generation end),
        bytes: (if $restore_status == "restored" then $logical_bytes else 0 end),
        files: (if $restore_status == "restored" then $logical_blobs else 0 end)
      },
      daemon_ready_seconds: 0.1,
      finalize: {failed: 0, pruned_records: 2, pruned_bytes: 2000},
      prune_seconds: 0.1,
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
      total_state_overhead_seconds: 0.4
    }
    | if $include_logical_generation then
        .save.logical_generation_blobs = $logical_blobs
        | .save.logical_generation_bytes = $logical_bytes
      else . end' > "$BORINGCACHE_STATE_SUMMARY_PATH"

  saw_cacheonly=0
  for arg in "$@"; do
    [[ "$arg" == type=cacheonly ]] && saw_cacheonly=1
  done
  [[ "$saw_cacheonly" -eq 1 ]] || {
    echo "Mock canary command omitted its cache-only product output" >&2
    return 1
  }

  printf 'mock daemon %s\n' "$phase" > "$BORINGCACHE_MANAGED_BUILDKIT_LOG_PATH"
  printf '{"phase":"%s"}\n' "$phase" > "$BORINGCACHE_OBSERVABILITY_JSONL_PATH"
  echo '#1 [mock] build'
  if [[ "$phase" == cold || "$phase" == replay-001-* ]]; then
    echo '#1 DONE 1.0s'
  else
    echo '#1 CACHED'
    echo '#2 CACHED'
  fi
}

export -f git docker boringcache
export source_sha image_digest cold_generation warm_generation rolling_parent rolling_generation

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
  write_mock_preflight "$artifact_dir"
  if [[ "$lane" == replay-full || "$lane" == replay-endpoints ]]; then
    write_mock_replay_plan "$lane" "$artifact_dir"
  fi
  MOCK_CURRENT_SHA="$source_sha"
  BORINGCACHE_STATE_CANARY_LANE="$lane" \
    BORINGCACHE_STATE_CANARY_WORKSPACE=boringcache/benchmark-posthog \
    BORINGCACHE_STATE_CANARY_TAG="mock-${lane}" \
    BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE="ghcr.io/boringcache/buildkit@${image_digest}" \
    BORINGCACHE_STATE_CANARY_ARTIFACT_DIR="$artifact_dir" \
    BORINGCACHE_STATE_CANARY_REPLAY_PLAN="$artifact_dir/replay-plan.json" \
    BORINGCACHE_STATE_CANARY_PLATFORM=linux/amd64 \
    BORINGCACHE_STATE_CANARY_PLATEAU_TOLERANCE_PERCENT=2 \
    BORINGCACHE_API_URL="$mock_api_origin" \
    BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER=0 \
    "$runner"
}

fresh_dir="$test_root/fresh"
run_mock fresh "$fresh_dir" >/dev/null
command jq -e '
  .schema_version == "buildkit-state-canary-result.v2"
  and .success == true
  and all(.phases[]; .schema_version == "buildkit-state-canary-phase.v2")
  and .current_set.current_set_replacement == true
  and .current_set.same_ref_plateau == true
  and .current_set.same_ref_solver_reuse == true
  and (.phases | length) == 2
  and (.phases[0].state.logical_generation_blobs > 0)
  and (.phases[1].state.parent_generation == .phases[0].state.generation)
  and (.phases[1].state.head_generations_fetched == 1)
' "$fresh_dir/canary-result.json" >/dev/null

rolling_dir="$test_root/rolling"
run_mock rolling "$rolling_dir" >/dev/null
command jq -e '
  .success == true
  and .current_set.current_set_replacement == true
  and .current_set.only_current_head_fetched == true
  and (.phases[0].state.transport_delta_blobs == 4)
  and (.phases[0].state.pruned_records == 2)
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

schema_dir="$test_root/schema-failure"
if MOCK_OMIT_LOGICAL_GENERATION=1 run_mock fresh "$schema_dir" >/dev/null 2>&1; then
  echo "Expected missing logical-generation summary fields to fail closed" >&2
  exit 1
fi
command jq -e '.success == false' "$schema_dir/canary-result.json" >/dev/null

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
