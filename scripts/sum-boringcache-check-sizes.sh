#!/usr/bin/env bash
#
# Canonical sum-boringcache-check-sizes.sh
#
# Consolidates the four forks previously found across benchmark repos:
#
#   - 55-line variant (n8n, opentelemetry-java, spring-ai, storybook)
#       no dedupe; tag-resolution defaults; soft about misses.
#
#   - 71-line variant (hugo, immich, mastodon, posthog, zed)
#       adds cache_entry_id-based dedupe so duplicate hits across tags
#       only count storage once.
#
#   - 86-line variant (grpc)
#       adds `--no-platform --exact` to strict-resolve tags and hard-fails
#       if any expected tag is a miss.
#
#   - 96-line variant (hugo-go)
#       same strict mode as grpc, but treats misses as warnings, optionally
#       writes them to BORINGCACHE_STORAGE_MISSING_PATH, and falls back to
#       `boringcache inspect` for hits with a zero compressed_size.
#
# Behavior preservation:
#   - Default mode == 71-line variant (the dedupe is universally correct
#     and was the most common fork). The 55-line callers gain dedupe.
#     Storage totals can only decrease or stay equal — never inflate.
#   - Set BORINGCACHE_CHECK_STRICT=1 to enable `--no-platform --exact`
#     and hard-fail on misses (grpc behavior).
#   - Set BORINGCACHE_STORAGE_MISSING_PATH=<file> to enable the soft
#     warning + missing-tag-list + inspect-fallback flow (hugo-go).
#     This implies strict resolution flags but does not hard-fail.
#
# Positional args (unchanged):
#   $1 = workspace
#   $2 = comma-separated tags
#
# Outputs the total compressed size in bytes on stdout.
#
set -euo pipefail

workspace="${1:-}"
tags_csv="${2:-}"

if [[ -z "$workspace" || -z "$tags_csv" ]]; then
  echo "0"
  exit 0
fi

strict_mode=0
soft_missing_mode=0
if [[ -n "${BORINGCACHE_STORAGE_MISSING_PATH:-}" ]]; then
  soft_missing_mode=1
  strict_mode=1
fi
if [[ "${BORINGCACHE_CHECK_STRICT:-0}" == "1" ]]; then
  strict_mode=1
fi

check_args=(check "$workspace" "$tags_csv" --no-git --json)
if (( strict_mode == 1 )); then
  check_args=(check "$workspace" "$tags_csv" --no-git --no-platform --exact --json)
fi

tmp_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$tmp_file" "$stderr_file"' EXIT

if ! boringcache "${check_args[@]}" > "$tmp_file" 2> "$stderr_file"; then
  echo "boringcache check failed while measuring remote storage for tags: ${tags_csv}" >&2
  cat "$stderr_file" >&2
  exit 1
fi

if ! jq -e '.results | type == "array"' "$tmp_file" >/dev/null 2>&1; then
  echo "boringcache check returned unexpected JSON while measuring remote storage" >&2
  cat "$tmp_file" >&2
  exit 1
fi

if (( strict_mode == 1 )); then
  miss_count="$(
    jq -r '
      [
        .results[]?
        | select((.status // "") != "hit")
      ] | length
    ' "$tmp_file"
  )"

  if [[ "$miss_count" != "0" ]]; then
    if (( soft_missing_mode == 1 )); then
      echo "warning: boringcache check did not find every expected storage tag: ${tags_csv}" >&2
      jq -r '.results[]? | "\(.tag // .entry // "unknown"): \(.status // "unknown")"' "$tmp_file" >&2
      jq -r '
        .results[]?
        | select((.status // "") != "hit")
        | .tag // .requested_tag // .requestedTag // "unknown"
      ' "$tmp_file" > "$BORINGCACHE_STORAGE_MISSING_PATH"
    else
      echo "boringcache check did not find every expected storage tag: ${tags_csv}" >&2
      jq -r '.results[]? | "\(.tag // .entry // "unknown"): \(.status // "unknown")"' "$tmp_file" >&2
      exit 1
    fi
  fi
fi

if (( soft_missing_mode == 1 )); then
  to_num() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "$value"
    else
      echo "0"
    fi
  }

  declare -A seen_entries=()
  total=0

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue

    key="$(jq -r '.cache_entry_id // .cacheEntryId // .manifest_root_digest // .manifestRootDigest // .requested_tag // .requestedTag // .tag // "unknown"' <<<"$row")"
    tag="$(jq -r '.tag // .requested_tag // .requestedTag // empty' <<<"$row")"
    size="$(jq -r '.compressed_size // .compressedSize // .size_bytes // .sizeBytes // .size // 0' <<<"$row")"
    size="$(to_num "$size")"

    if [[ "$size" == "0" && -n "$tag" ]]; then
      inspect_json="$(boringcache inspect "$workspace" "$tag" --json 2> "$stderr_file" || true)"
      if [[ -n "$inspect_json" ]]; then
        inspect_key="$(jq -r '.entry.id // empty' <<<"$inspect_json" 2>/dev/null || true)"
        if [[ -n "$inspect_key" ]]; then
          key="$inspect_key"
        fi
        inspected_size="$(jq -r '.entry.stored_size_bytes // .entry.compressed_size // .entry.archive_size // .entry.blob_total_size_bytes // .entry.uncompressed_size // 0' <<<"$inspect_json" 2>/dev/null || true)"
        size="$(to_num "$inspected_size")"
      else
        echo "boringcache inspect failed while measuring remote storage for tag: ${tag}" >&2
        cat "$stderr_file" >&2
        exit 1
      fi
    fi

    if [[ -z "${seen_entries[$key]+x}" ]]; then
      seen_entries[$key]=1
      total=$((total + size))
    fi
  done < <(jq -c '.results[]? | select((.status // "") == "hit")' "$tmp_file")
else
  total="$(
    jq -r '
      def to_num:
        if type == "number" then .
        elif type == "string" then (try (capture("(?<n>[0-9]+)").n | tonumber) catch 0)
        else 0 end;

      def dedupe_key:
        .cache_entry_id //
        .cacheEntryId //
        .manifest_root_digest //
        .manifestRootDigest //
        .requested_tag //
        .requestedTag //
        .tag //
        .entry //
        "unknown";

      [
        .results[]?
        | select((.status // "") == "hit")
        | {
            key: dedupe_key,
            size: (
              .compressed_size //
              .compressedSize //
              .size_bytes //
              .sizeBytes //
              .size
            ) | to_num
          }
      ]
      | group_by(.key)
      | map(max_by(.size) | .size)
      | add // 0
    ' "$tmp_file"
  )"
fi

if [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]]; then
  total=0
fi

echo "$total"
