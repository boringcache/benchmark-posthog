#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scenario="${1:-base}"

git -C "${repo_root}/upstream" reset --hard
git -C "${repo_root}/upstream" clean -fdx

case "${scenario}" in
  base|warm1)
    if [[ "${POSTHOG_TURBO_CACHE_MOUNTS:-}" == "1" ]]; then
      git -C "${repo_root}/upstream" apply --unidiff-zero "${repo_root}/scenarios/posthog-turbo-cache-mounts.patch"
    fi
    ;;
  *)
    echo "Unknown scenario: ${scenario}" >&2
    exit 1
    ;;
esac

git -C "${repo_root}/upstream" status --short
