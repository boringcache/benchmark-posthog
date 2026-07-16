#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/state-sync-v13-cas.yml"
rolling_action="$repo_root/.github/actions/docker-rolling-benchmark/action.yml"
rolling_dispatch_workflow="$repo_root/.github/workflows/rolling-dispatch.yml"
sync_workflow="$repo_root/.github/workflows/sync.yml"
runner="$repo_root/scripts/run-buildkit-state-canary.sh"
preflight_runner="$repo_root/scripts/preflight-buildkit-state-canary.sh"
test_runner="$repo_root/scripts/test-buildkit-state-canary.sh"
rolling_dispatcher="$repo_root/scripts/dispatch-buildkit-state-rolling-canary.sh"
rolling_dispatcher_test="$repo_root/scripts/test-dispatch-buildkit-state-rolling-canary.sh"
rolling_benchmark_runner="$repo_root/scripts/run-boringcache-buildkit-benchmark.sh"
record_flow_summary_renderer="$repo_root/scripts/render-buildkit-state-record-flow-summary.sh"
fixture_renderer="$repo_root/scripts/render-posthog-toolcache-dockerfile.sh"
fixture_renderer_test="$repo_root/scripts/test-render-posthog-toolcache-dockerfile.sh"
image_index_verifier="$repo_root/scripts/verify-buildkit-image-index.sh"

bash -n "$runner"
bash -n "$preflight_runner"
bash -n "$test_runner"
bash -n "$rolling_dispatcher"
bash -n "$rolling_dispatcher_test"
bash -n "$rolling_benchmark_runner"
bash -n "$record_flow_summary_renderer"
bash -n "$fixture_renderer"
bash -n "$fixture_renderer_test"
bash -n "$image_index_verifier"

require_text() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "Missing required canary contract in ${file#"$repo_root"/}: ${text}" >&2
    exit 1
  fi
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    echo "Forbidden canary dependency in ${file#"$repo_root"/}: ${text}" >&2
    exit 1
  fi
}

require_text "$workflow" "workflow_dispatch:"
require_text "$workflow" "cli_asset_sha256:"
require_text "$workflow" "ghcr.io/boringcache/buildkit@sha256"
require_text "$workflow" "latest|canary|vcli-canary"
require_text "$workflow" "if: always()"
require_text "$workflow" "replay-full"
require_text "$workflow" "replay-endpoints"
require_text "$workflow" "posthog_source:"
require_text "$workflow" "warm_generations:"
require_text "$workflow" "composition_mode:"
require_text "$workflow" "BORINGCACHE_STATE_CANARY_COMPOSITION_MODE: \${{ inputs.composition_mode }}"
require_text "$workflow" "BORINGCACHE_STATE_CANARY_WARM_GENERATIONS: \${{ inputs.warm_generations }}"
require_text "$workflow" "replay-plan.json"
require_text "$workflow" "first parent of"
require_text "$workflow" "fetch --no-tags --depth 1 origin \"\${replay_commits[@]}\""
require_text "$workflow" "maintenance.auto=false"
require_text "$workflow" "preflight-checklist.json"
require_text "$workflow" "runner_disk_capacity"
require_text "$workflow" "verify-buildkit-image-index.sh"
require_text "$workflow" "buildkit-image-platform-manifest.sha256"
require_text "$workflow" 'bash scripts/render-buildkit-state-record-flow-summary.sh "$result"'
require_text "$workflow" "Resolve verified CLI version"
require_text "$workflow" "BORINGCACHE_STATE_CANARY_CLI_VERSION"
require_text "$rolling_dispatch_workflow" "state_canary:"
require_text "$rolling_dispatch_workflow" "vars.POSTHOG_STATE_CANARY_ENABLED == 'true'"
require_text "$rolling_dispatch_workflow" "vars.POSTHOG_STATE_CANARY_CLI_RELEASE_TAG"
require_text "$rolling_dispatch_workflow" "vars.POSTHOG_STATE_CANARY_CLI_AMD64_SHA256"
require_text "$rolling_dispatch_workflow" "vars.POSTHOG_STATE_CANARY_CLI_ARM64_SHA256"
require_text "$rolling_dispatch_workflow" "vars.POSTHOG_STATE_CANARY_BUILDKIT_AMD64_IMAGE"
require_text "$rolling_dispatch_workflow" "vars.POSTHOG_STATE_CANARY_BUILDKIT_ARM64_IMAGE"
require_text "$rolling_dispatch_workflow" "./scripts/dispatch-buildkit-state-rolling-canary.sh"
require_text "$sync_workflow" 'cron: "*/30 * * * *"'
require_text "$rolling_dispatcher" "git ls-tree HEAD upstream"
require_text "$rolling_dispatcher" "STATE_CANARY_BUILDKIT_IMAGE must be an exact managed image digest"
require_text "$rolling_dispatcher" "-f cache_lane=rolling"
require_text "$rolling_dispatcher" "-f composition_mode=mount"
require_text "$rolling_dispatcher" "-f run_mode=build-only"
require_text "$rolling_dispatcher" '-f "posthog_source=${source_sha}"'
require_text "$rolling_dispatcher" '-f "rolling_scope=${rolling_scope}"'
require_text "$preflight_runner" "expected_tag_head_v1"
require_text "$preflight_runner" "buildkit_state_current_set_v1"
require_text "$preflight_runner" "cas_publish_bootstrap_if_match"
require_text "$preflight_runner" "\${api_origin}/v2/capabilities"
require_text "$preflight_runner" "--header \"User-Agent: BoringCache-CLI/\${cli_version}\""
require_text "$preflight_runner" "user_agent: \$user_agent"
require_text "$test_runner" "user_agent_count"
require_text "$test_runner" "User-Agent: BoringCache-CLI/\${BORINGCACHE_STATE_CANARY_CLI_VERSION}"
require_text "$runner" "--backend state"
require_text "$runner" "--fail-on-cache-error"
require_text "$runner" "BORINGCACHE_STATE_SUMMARY_PATH"
require_text "$runner" "same-ref-warm"
require_text "$runner" "same-ref-repeat"
require_text "$runner" "managed_builder_destroyed"
require_text "$runner" "logical_generation_bytes"
require_text "$runner" "current_set_replacement"
require_text "$runner" "only_current_head_fetched"
require_text "$runner" "same_ref_solver_reuse"
require_text "$runner" "BuildKit state warm generations must be 2, 4, or 8"
require_text "$runner" "BORINGCACHE_STATE_CANARY_COMPOSITION_MODE must be off or fixture"
require_text "$runner" '--tool-cache "turbo:${tool_cache_tag}"'
require_text "$runner" '.mount_cache.generation_archives == .mount_cache.selected_archives'
require_text "$runner" 'toolcache_exercised'
require_text "$runner" "warm_generations_planned"
require_text "$runner" "transitions: \$transitions"
require_text "$runner" "final_convergence_pair"
require_text "$runner" "bootstrap_blob_growth_within_tolerance"
require_text "$runner" "required_blob_count_stable"
require_text "$runner" "all_warm_content_counts_stable"
require_text "$runner" "mount_cache_valid"
require_text "$runner" '$blob_delta == 0'
require_text "$test_runner" "Expected one new logical blob on the final warm generation to fail the canary"
require_text "$test_runner" "Expected one new required BuildKit body on the final warm generation to fail the canary"
require_text "$test_runner" "Expected one new logical blob on an intermediate warm generation to fail the canary"
require_text "$test_runner" "Expected one new required BuildKit body on an intermediate warm generation to fail the canary"
require_text "$test_runner" "Expected terminal mount-cache hydration errors to fail the composition canary"
require_text "$test_runner" "Expected same-ref BuildKit record growth to block graduation"
require_text "$test_runner" "Expected invalid clean-start evidence"
require_text "$test_runner" "Expected a terminal clean-start without a restoring product phase to remain pending"
require_text "$test_runner" "Expected a clean-start followed by the wrong generation to fail continuity"
require_text "$test_runner" "Expected a single rolling clean-start to remain pending until a later product restore"
require_text "$workflow" "active-window stable content counts"
require_text "$workflow" "> **NOT READY:** this rolling phase published a clean-start root"
require_text "$runner" "same_ref_replacement_uploaded_bytes"
require_text "$runner" "fully_state_cached_short_circuit"
require_text "$runner" "bootstrap_only"
require_text "$runner" "run_terminal_mount_probe"
require_text "$runner" "--read-only"
require_text "$runner" "--no-cache-filter boringcache-state-mount-probe"
require_text "$runner" '.mount_cache.hydrate_hits == 1'
require_text "$runner" '.mount_cache.hydrate_skips == 0'
require_text "$runner" 'zero_eager_mount_restore'
require_text "$runner" 'deferred_publish_lifecycle'
require_text "$runner" 'and $all_warm_record_counts_stable'
require_text "$workflow" 'turbo-rolling-${rolling_slug}'
require_text "$workflow" 'platforms: ${{ steps.state.outputs.docker_platform }}'
require_text "$workflow" 'platform_key=arm64'
require_text "$workflow" 'expected_runner_arch=ARM64'
require_text "$rolling_benchmark_runner" 'state_restore_status="$(jq -r '\''.restore.status // empty'\'' "$BORINGCACHE_STATE_SUMMARY_PATH" 2>/dev/null || true)"'
require_text "$rolling_benchmark_runner" 'echo "bootstrap_miss"'
require_text "$fixture_renderer" 'AS boringcache-state-mount-probe'
require_text "$fixture_renderer" 'AS posthog-runtime'
require_text "$runner" 'render-posthog-toolcache-dockerfile.sh" "$dockerfile_path"'
require_text "$workflow" 'posthog-toolcache.Dockerfile'
require_text "$runner" 'product_target_args+=(--target posthog-runtime)'
require_text "$test_runner" "composition-short-circuit"
require_text "$test_runner" "rolling-bootstrap-composition"
require_text "$runner" "exact_source_sequence"
require_text "$runner" "all_successors_within_tolerance"
require_text "$runner" 'restore_status == "clean_start"'
require_text "$runner" "candidate_generation"
require_text "$runner" "state_window_rebase_reason"
require_text "$runner" "has_zero_number"
require_text "$runner" '.save.generation != .restore.candidate_generation'
require_text "$runner" 'clean_start_followup_pending'
require_text "$runner" 'and ($audited_current_set.clean_start_followup_pending != true)'
require_text "$runner" 'ready_for_graduation'
require_text "$runner" "clean_start_followup_proven"
require_text "$runner" "plateau_window_start_sequence"
require_text "$runner" "replay-successor"
require_text "$runner" "replay-repeat-"
require_text "$runner" "preflight-checklist.json"
require_text "$runner" ".save.logical_generation_blobs"
require_text "$runner" ".save.logical_generation_bytes"
require_text "$runner" 'buildkit-state-summary.v3'
require_text "$runner" '.restore.lazy_content_blobs'
require_text "$runner" '.save.lazy_content_runtime_status == "recorded"'
require_text "$runner" '.save.lazy_content_hydration_failures == 0'
require_text "$runner" '.save.logical_generation_blobs == (.save.reused_blobs + .save.uploaded_blobs)'
require_text "$runner" 'state-window-scaffold-clean-v1'
require_text "$runner" '.finalize.retention_source == "post-clean-measured"'
require_text "$runner" '.finalize.retention_disk_usage_baseline_bytes > 0'
require_text "$runner" '.finalize.prune_applied == true'
require_text "$runner" '.finalize.prune_target_satisfied == true'
require_text "$runner" '.finalize.prune_all == true'
require_text "$runner" '.finalize.prune_filter_count == 2'
require_text "$runner" 'post_clean_baselines_valid'
require_text "$runner" 'scaffold_prune_observed'
require_text "$runner" 'growth_observation'
require_text "$runner" 'clean_start_free'
require_text "$runner" 'replay_min_cached_steps=68'
require_text "$runner" 'all_restored_successors_hit_contract'
require_text "$runner" 'changed_source_telemetry'
require_text "$runner" 'correctness_gate: false'
require_text "$runner" 'repeat_state_contract'
require_text "$runner" 'repeat_solver_reuse'
require_text "$runner" 'buildkit-state-backend-current-set.v1'
require_text "$runner" 'boringcache inspect "$workspace" "$cache_tag" --json'
require_text "$runner" '.versions.version_count == 1'
require_text "$runner" '.versions.total_storage_bytes == .entry.stored_size_bytes'
require_text "$runner" 'backend_current_head_set'
require_text "$runner" 'retention_converged'
require_text "$runner" '.finalize.content_gc_applied == true'
require_text "$runner" '.finalize.records_after_prune == .finalize.records_before_gc'
require_text "$runner" '.finalize.records_before_gc == .finalize.records_after_gc'
require_text "$runner" '.finalize.records_after_gc >= .finalize.eligible'
require_text "$runner" '.content_gc_seconds'
require_text "$runner" 'state_record_flow_valid'
require_text "$runner" '$flow.status == "recorded"'
require_text "$runner" '$flow.local_sources_created_during_build == 3'
require_text "$runner" 'test("^same-ref-(warm|repeat)")'
require_text "$runner" '($flow.created_local_sources | map(.record_id) | unique | length) == 3'
require_text "$runner" "--output type=cacheonly"
require_text "$runner" "buildkit-state-canary-result.v2"
require_text "$runner" "buildkit-state-canary-phase.v2"
require_text "$test_runner" "Expected a single-manifest document to fail the image-index gate"
require_text "$test_runner" "Expected invalid BuildKit state record flow"
require_text "$test_runner" "Expected extra same-ref records created during the user build to fail closed"
require_text "$test_runner" "Expected a replay without per-build scaffold cleanup to fail graduation"
require_text "$test_runner" "replay-oversized-logical-core"
require_text "$test_runner" "Expected an unsafe scaffold-clean retention report to fail closed"
require_text "$test_runner" "Expected a same-source replay repeat below the solver-reuse floor to fail graduation"
require_text "$test_runner" "Expected same-source replay state growth to fail the correctness contract"
require_text "$test_runner" "Expected same-source replay required-body growth to fail the correctness contract"
require_text "$test_runner" "Expected a replay whose exact backend head is not current to fail"
require_text "$workflow" "BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER: \${{ inputs.composition_mode == 'fixture' && '1' || '0' }}"
require_text "$workflow" "BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER: \${{ inputs.composition_mode != 'off' && '1' || '' }}"
require_text "$workflow" "uses: boringcache/one@one-canary-4a8b54452cfb"
require_text "$workflow" "diagnostics-artifact-name:"
require_text "$workflow" "diagnostics-artifact-retention-days: \"14\""
require_text "$workflow" "cache-backend: state"
require_text "$workflow" "managed-buildkit-image: \${{ inputs.buildkit_image }}"
require_text "$workflow" "cache-tag: \${{ steps.state.outputs.cache_tag }}"
require_text "$workflow" "Observed BuildKit state record flow"
require_text "$workflow" "Lazy immutable content"
require_text "$workflow" "changed-source solver floor"
require_text "$rolling_action" "inputs.buildkit_backend == 'state' && 'always'"

for file in "$runner" "$preflight_runner"; do
  reject_text "$file" "boringcache/one"
  reject_text "$file" "docker/setup-buildx"
  reject_text "$file" "--cache-from"
  reject_text "$file" "--cache-to"
  reject_text "$file" "rewrite-timestamp"
done
reject_text "$workflow" "boringcache/one@v1"
reject_text "$workflow" "--tool-cache"
reject_text "$preflight_runner" "--tool-cache"
reject_text "$runner" 'buildkit-state-summary.v1'
reject_text "$runner" 'buildkit-state-summary.v2'
reject_text "$runner" '36507222016'
reject_text "$runner" 'max-used-space-main-cache-v1'

cli_version_line="$(grep -n -m1 'name: Resolve verified CLI version' "$workflow" | cut -d: -f1)"
capability_probe_line="$(grep -n -m1 'name: Probe exact backend state capabilities' "$workflow" | cut -d: -f1)"
image_manifest_line="$(grep -n -m1 'name: Verify exact BuildKit image manifest' "$workflow" | cut -d: -f1)"
if ! ((cli_version_line < capability_probe_line && capability_probe_line < image_manifest_line)); then
  echo "CLI checksum/version must resolve before capability probe and managed image access" >&2
  exit 1
fi

"$rolling_dispatcher_test"
"$fixture_renderer_test"
"$test_runner"

echo "BuildKit state canary contract is valid."
