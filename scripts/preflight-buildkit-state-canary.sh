#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 2
  fi
}

for name in \
  BORINGCACHE_STATE_CANARY_API_ORIGIN \
  BORINGCACHE_STATE_CANARY_LANE \
  BORINGCACHE_STATE_CANARY_CLI_RELEASE_TAG \
  BORINGCACHE_STATE_CANARY_CLI_VERSION \
  BORINGCACHE_STATE_CANARY_CLI_ASSET_SHA256 \
  BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE \
  BORINGCACHE_STATE_CANARY_ARTIFACT_DIR \
  BORINGCACHE_RESTORE_TOKEN; do
  require_env "$name"
done

api_origin="$BORINGCACHE_STATE_CANARY_API_ORIGIN"
lane="$BORINGCACHE_STATE_CANARY_LANE"
cli_release_tag="$BORINGCACHE_STATE_CANARY_CLI_RELEASE_TAG"
cli_version="$BORINGCACHE_STATE_CANARY_CLI_VERSION"
cli_asset_sha256="$BORINGCACHE_STATE_CANARY_CLI_ASSET_SHA256"
buildkit_image="$BORINGCACHE_STATE_CANARY_BUILDKIT_IMAGE"
artifact_dir="$BORINGCACHE_STATE_CANARY_ARTIFACT_DIR"
posthog_source="${BORINGCACHE_STATE_CANARY_POSTHOG_SOURCE:-}"
capabilities_path="$artifact_dir/backend-capabilities.json"
checklist_path="$artifact_dir/preflight-backend.json"

for tool in curl jq; do
  command -v "$tool" >/dev/null || {
    echo "Required preflight command is unavailable: ${tool}" >&2
    exit 2
  }
done

mkdir -p "$artifact_dir"

api_origin_exact=false
lane_supported=false
cli_release_immutable=false
cli_version_verified=false
cli_asset_pinned=false
buildkit_image_pinned=false
source_immutable=false

if [[ "$api_origin" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
  api_origin_exact=true
fi

case "$lane" in
  fresh|rolling|replay-full|replay-endpoints)
    lane_supported=true
    ;;
esac

if [[ -n "$cli_release_tag" && ! "$cli_release_tag" =~ [[:space:]] ]] && \
   [[ "$cli_release_tag" != "latest" && "$cli_release_tag" != "canary" && "$cli_release_tag" != "vcli-canary" ]]; then
  cli_release_immutable=true
fi
if [[ "$cli_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  cli_version_verified=true
fi
if [[ "$cli_asset_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  cli_asset_pinned=true
fi
if [[ "$buildkit_image" =~ ^ghcr\.io/boringcache/buildkit@sha256:[0-9a-f]{64}$ ]]; then
  buildkit_image_pinned=true
fi

case "$lane" in
  fresh|rolling)
    if [[ -z "$posthog_source" || "$posthog_source" =~ ^[0-9a-f]{40}$ ]]; then
      source_immutable=true
    fi
    ;;
  replay-full|replay-endpoints)
    IFS=',' read -r -a replay_commits <<< "$posthog_source"
    if ((${#replay_commits[@]} == 11)); then
      source_immutable=true
      for commit in "${replay_commits[@]}"; do
        if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
          source_immutable=false
          break
        fi
      done
    fi
    ;;
esac

http_status="000"
curl_status=0
if [[ "$api_origin_exact" == true && "$cli_version_verified" == true ]]; then
  set +e
  http_status="$(curl \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time 30 \
    --output "$capabilities_path" \
    --write-out '%{http_code}' \
    --header "Authorization: Bearer ${BORINGCACHE_RESTORE_TOKEN}" \
    --header "User-Agent: BoringCache-CLI/${cli_version}" \
    --header 'Accept: application/json' \
    "${api_origin}/v2/capabilities")"
  curl_status=$?
  set -e
fi
[[ -s "$capabilities_path" ]] || printf '{}\n' > "$capabilities_path"

capabilities_json=false
api_version_v2=false
entry_create_v2=false
blob_stage_v2=false
tag_publish_v2=false
upload_sessions_v2=false
upload_receipts_v2=false
expected_tag_head_v1=false
buildkit_state_current_set_v1=false
bootstrap_if_match=false

if jq -e 'type == "object"' "$capabilities_path" >/dev/null 2>&1; then
  capabilities_json=true
  [[ "$(jq -r '.api_version == "v2"' "$capabilities_path")" == true ]] && api_version_v2=true
  [[ "$(jq -r '.features.entry_create_v2 == true' "$capabilities_path")" == true ]] && entry_create_v2=true
  [[ "$(jq -r '.features.blob_stage_v2 == true' "$capabilities_path")" == true ]] && blob_stage_v2=true
  [[ "$(jq -r '.features.tag_publish_v2 == true' "$capabilities_path")" == true ]] && tag_publish_v2=true
  [[ "$(jq -r '.features.upload_sessions_v2 == true' "$capabilities_path")" == true ]] && upload_sessions_v2=true
  [[ "$(jq -r '.features.upload_receipts_v2 == true' "$capabilities_path")" == true ]] && upload_receipts_v2=true
  [[ "$(jq -r '.features.expected_tag_head_v1 == true' "$capabilities_path")" == true ]] && expected_tag_head_v1=true
  [[ "$(jq -r '.features.buildkit_state_current_set_v1 == true' "$capabilities_path")" == true ]] && buildkit_state_current_set_v1=true
  [[ "$(jq -r '.features.cas_publish_bootstrap_if_match == "0"' "$capabilities_path")" == true ]] && bootstrap_if_match=true
fi

jq -n \
  --arg schema_version "buildkit-state-canary-preflight.v1" \
  --arg api_origin "$api_origin" \
  --arg lane "$lane" \
  --arg posthog_source "$posthog_source" \
  --arg cli_release_tag "$cli_release_tag" \
  --arg cli_version "$cli_version" \
  --arg cli_asset_sha256 "$cli_asset_sha256" \
  --arg buildkit_image "$buildkit_image" \
  --arg required_state_layout "buildkit-state-v1" \
  --arg user_agent "BoringCache-CLI/${cli_version}" \
  --arg http_status "$http_status" \
  --argjson curl_status "$curl_status" \
  --argjson api_origin_exact "$api_origin_exact" \
  --argjson lane_supported "$lane_supported" \
  --argjson cli_release_immutable "$cli_release_immutable" \
  --argjson cli_version_verified "$cli_version_verified" \
  --argjson cli_asset_pinned "$cli_asset_pinned" \
  --argjson buildkit_image_pinned "$buildkit_image_pinned" \
  --argjson source_immutable "$source_immutable" \
  --argjson capabilities_json "$capabilities_json" \
  --argjson api_version_v2 "$api_version_v2" \
  --argjson entry_create_v2 "$entry_create_v2" \
  --argjson blob_stage_v2 "$blob_stage_v2" \
  --argjson tag_publish_v2 "$tag_publish_v2" \
  --argjson upload_sessions_v2 "$upload_sessions_v2" \
  --argjson upload_receipts_v2 "$upload_receipts_v2" \
  --argjson expected_tag_head_v1 "$expected_tag_head_v1" \
  --argjson buildkit_state_current_set_v1 "$buildkit_state_current_set_v1" \
  --argjson bootstrap_if_match "$bootstrap_if_match" '
    {
      schema_version: $schema_version,
      api_origin: $api_origin,
      lane: $lane,
      pins: {
        cli_release_tag: $cli_release_tag,
        cli_version: $cli_version,
        cli_asset_sha256: $cli_asset_sha256,
        buildkit_image: $buildkit_image,
        posthog_source: $posthog_source
      },
      state_contract: {
        required_layout: $required_state_layout,
        required_capability: "buildkit_state_current_set_v1"
      },
      backend_probe: {
        http_status: $http_status,
        curl_status: $curl_status,
        user_agent: $user_agent
      },
      checks: {
        api_origin_exact: $api_origin_exact,
        lane_supported: $lane_supported,
        cli_release_immutable: $cli_release_immutable,
        cli_version_verified: $cli_version_verified,
        cli_asset_pinned: $cli_asset_pinned,
        buildkit_image_pinned: $buildkit_image_pinned,
        source_immutable: $source_immutable,
        backend_http_ok: ($curl_status == 0 and $http_status == "200"),
        capabilities_json: $capabilities_json,
        api_version_v2: $api_version_v2,
        entry_create_v2: $entry_create_v2,
        blob_stage_v2: $blob_stage_v2,
        tag_publish_v2: $tag_publish_v2,
        upload_sessions_v2: $upload_sessions_v2,
        upload_receipts_v2: $upload_receipts_v2,
        expected_tag_head_v1: $expected_tag_head_v1,
        buildkit_state_current_set_v1: $buildkit_state_current_set_v1,
        cas_publish_bootstrap_if_match_zero: $bootstrap_if_match
      }
    }
    | .all_passed = all(.checks[]; . == true)
  ' > "$checklist_path"

if ! jq -e '.all_passed == true' "$checklist_path" >/dev/null; then
  echo "BuildKit state backend preflight failed for ${api_origin}" >&2
  jq -r '.checks | to_entries[] | select(.value != true) | "  failed: \(.key)"' "$checklist_path" >&2
  exit 1
fi

echo "BuildKit state backend preflight passed for ${api_origin}."
