#!/usr/bin/env bash
# Install one exact public BoringCache CLI release for benchmark workflows.
#
# The benchmark harness uses this instead of turning boringcache/one into a
# CLI-only setup Action. Cache policy remains in .boringcache.toml, while the
# Action is reserved for cache lifecycle and adapter orchestration.

set -euo pipefail

version="${1:-v1.16.3}"
platform="${2:-linux-amd64}"
version="${version#v}"
tag="v${version}"

case "${platform}" in
  linux-amd64|linux-arm64|linux-musl-amd64|linux-musl-arm64|macos-universal)
    asset="boringcache-${platform}"
    ;;
  windows-amd64|windows-arm64)
    asset="boringcache-${platform}.exe"
    ;;
  *)
    echo "Unsupported BoringCache CLI platform: ${platform}" >&2
    exit 2
    ;;
esac

release_url="https://github.com/boringcache/cli/releases/download/${tag}"
install_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/boringcache-bin"
download_dir="$(mktemp -d)"
trap 'rm -rf "${download_dir}"' EXIT

curl --fail --silent --show-error --location \
  --output "${download_dir}/${asset}" \
  "${release_url}/${asset}"
curl --fail --silent --show-error --location \
  --output "${download_dir}/SHA256SUMS" \
  "${release_url}/SHA256SUMS"

(
  cd "${download_dir}"
  grep -F "  ${asset}" SHA256SUMS | sha256sum --check --strict
)

mkdir -p "${install_dir}"
install -m 0755 "${download_dir}/${asset}" "${install_dir}/boringcache"
"${install_dir}/boringcache" --version

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${install_dir}" >> "${GITHUB_PATH}"
else
  export PATH="${install_dir}:${PATH}"
fi
