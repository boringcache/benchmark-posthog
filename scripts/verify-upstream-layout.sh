#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_root}/Dockerfile.benchmark"
upstream_root="${repo_root}/upstream"

if [[ ! -d "${upstream_root}" ]]; then
  echo "Missing upstream checkout at ${upstream_root}" >&2
  exit 1
fi

upstream_refs=()
while IFS= read -r ref; do
  upstream_refs+=("${ref}")
done < <(grep -oE 'upstream/[^,[:space:]\\]+' "${dockerfile}" | sort -u)

if [[ "${#upstream_refs[@]}" -eq 0 ]]; then
  echo "No upstream references found in ${dockerfile}" >&2
  exit 1
fi

missing_refs=()
for ref in "${upstream_refs[@]}"; do
  if [[ ! -e "${repo_root}/${ref}" ]]; then
    missing_refs+=("${ref}")
  fi
done

if [[ "${#missing_refs[@]}" -gt 0 ]]; then
  echo "Dockerfile.benchmark references upstream paths that no longer exist:" >&2
  printf '  - %s\n' "${missing_refs[@]}" >&2
  echo "Update Dockerfile.benchmark to match the new upstream layout before running benchmarks." >&2
  exit 1
fi
