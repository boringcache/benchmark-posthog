#!/usr/bin/env bash
set -euo pipefail

index_path="${1:-}"
expected_platform="${2:-}"

[[ -s "$index_path" ]] || {
  echo "BuildKit image index is missing: ${index_path:-unspecified}" >&2
  exit 1
}
[[ "$expected_platform" =~ ^linux/(amd64|arm64)$ ]] || {
  echo "Unsupported BuildKit image platform: ${expected_platform:-unspecified}" >&2
  exit 1
}

jq -e '
  (.schemaVersion == 2)
  and (.mediaType == "application/vnd.oci.image.index.v1+json"
    or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json")
  and (.manifests | type == "array")
' "$index_path" >/dev/null || {
  echo "BuildKit image digest must resolve to an OCI image index or Docker manifest list" >&2
  exit 1
}

expected_os="${expected_platform%/*}"
expected_arch="${expected_platform#*/}"
selected_digest="$(jq -r \
  --arg os "$expected_os" \
  --arg arch "$expected_arch" \
  '[.manifests[] | select(.platform.os == $os and .platform.architecture == $arch)][0].digest // empty' \
  "$index_path")"
[[ "$selected_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "BuildKit image index does not contain ${expected_platform}" >&2
  exit 1
}

printf '%s\n' "$selected_digest"
