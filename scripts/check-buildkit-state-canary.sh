#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/state-sync-v13-cas.yml"
runner="$repo_root/scripts/run-buildkit-state-canary.sh"
preflight_runner="$repo_root/scripts/preflight-buildkit-state-canary.sh"
test_runner="$repo_root/scripts/test-buildkit-state-canary.sh"
image_index_verifier="$repo_root/scripts/verify-buildkit-image-index.sh"

bash -n "$runner"
bash -n "$preflight_runner"
bash -n "$test_runner"
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
require_text "$workflow" "Resolve verified CLI version"
require_text "$workflow" "BORINGCACHE_STATE_CANARY_CLI_VERSION"
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
require_text "$test_runner" "Expected mount-cache hydration errors to fail the composition canary"
require_text "$workflow" "all-warm stable content counts"
require_text "$runner" "same_ref_replacement_uploaded_bytes"
require_text "$runner" "fully_state_cached_short_circuit"
require_text "$test_runner" "composition-short-circuit"
require_text "$runner" "exact_source_sequence"
require_text "$runner" "all_successors_within_tolerance"
require_text "$runner" "replay-successor"
require_text "$runner" "preflight-checklist.json"
require_text "$runner" ".save.logical_generation_blobs"
require_text "$runner" ".save.logical_generation_bytes"
require_text "$runner" 'buildkit-state-summary.v2'
require_text "$runner" 'complete-main-cache-v1'
require_text "$runner" '.finalize.content_gc_applied == true'
require_text "$runner" '.finalize.records_before_gc == .finalize.records_after_gc'
require_text "$runner" '.finalize.records_after_gc >= .finalize.eligible'
require_text "$runner" '.content_gc_seconds'
require_text "$runner" "--output type=cacheonly"
require_text "$runner" "buildkit-state-canary-result.v2"
require_text "$runner" "buildkit-state-canary-phase.v2"
require_text "$test_runner" "Expected a single-manifest document to fail the image-index gate"
require_text "$workflow" "BORINGCACHE_BUILDKIT_MOUNTCACHE_OFFLOADER: \${{ inputs.composition_mode == 'fixture' && '1' || '0' }}"

for file in "$workflow" "$runner" "$preflight_runner"; do
  reject_text "$file" "boringcache/one"
  reject_text "$file" "docker/setup-buildx"
  reject_text "$file" "--cache-from"
  reject_text "$file" "--cache-to"
  reject_text "$file" "rewrite-timestamp"
done
reject_text "$workflow" "--tool-cache"
reject_text "$preflight_runner" "--tool-cache"
reject_text "$runner" ".save.reused_blobs"
reject_text "$runner" ".save.reused_bytes"
reject_text "$runner" 'buildkit-state-summary.v1'
reject_text "$runner" 'prune_seconds'
reject_text "$runner" 'pruned_records'
reject_text "$runner" 'pruned_bytes'

cli_version_line="$(grep -n -m1 'name: Resolve verified CLI version' "$workflow" | cut -d: -f1)"
capability_probe_line="$(grep -n -m1 'name: Probe exact backend state capabilities' "$workflow" | cut -d: -f1)"
image_manifest_line="$(grep -n -m1 'name: Verify exact BuildKit image manifest' "$workflow" | cut -d: -f1)"
if ! ((cli_version_line < capability_probe_line && capability_probe_line < image_manifest_line)); then
  echo "CLI checksum/version must resolve before capability probe and managed image access" >&2
  exit 1
fi

"$test_runner"

echo "BuildKit state canary contract is valid."
