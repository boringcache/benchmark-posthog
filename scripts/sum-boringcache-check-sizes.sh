#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-}"
tags_csv="${2:-}"

if [[ -z "$workspace" || -z "$tags_csv" ]]; then
  echo "0"
  exit 0
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

# Check all tags in one request so tag resolution/miss accounting is consistent.
if ! boringcache check "$workspace" "$tags_csv" --no-git --json > "$tmp_file" 2>/dev/null; then
  echo "0"
  exit 0
fi

if ! jq -e '.results | type == "array"' "$tmp_file" >/dev/null 2>&1; then
  echo "0"
  exit 0
fi

total="$(
  jq -r '
    def to_num:
      if type == "number" then .
      elif type == "string" then (try (capture("(?<n>[0-9]+)").n | tonumber) catch 0)
      else 0 end;

    [
      .results[]?
      | select((.status // "") == "hit")
      | (
          .compressed_size //
          .compressedSize //
          .size_bytes //
          .sizeBytes //
          .size
        )
      | to_num
    ] | add // 0
  ' "$tmp_file"
)"

if [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]]; then
  total=0
fi

echo "$total"
