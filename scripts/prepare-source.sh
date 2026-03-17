#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scenario="${1:-base}"

git -C "${repo_root}/upstream" reset --hard
git -C "${repo_root}/upstream" clean -fdx

case "${scenario}" in
  base|warm1|warm2|layer_miss)
    ;;
  stale-low)
    git -C "${repo_root}/upstream" apply "${repo_root}/scenarios/stale-low.patch"
    ;;
  stale-mid)
    git -C "${repo_root}/upstream" apply "${repo_root}/scenarios/stale-mid.patch"
    ;;
  *)
    echo "Unknown scenario: ${scenario}" >&2
    exit 1
    ;;
esac

git -C "${repo_root}/upstream" status --short
