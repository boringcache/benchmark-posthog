#!/usr/bin/env bash
#
# Canonical sum-boringcache-check-sizes.sh
#
# Consolidates the four forks previously found across benchmark repos:
#
#   - 55-line variant (n8n, opentelemetry-java, spring-ai, storybook)
#       no dedupe; default archive tag resolution; soft about misses.
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
#   - Set BORINGCACHE_EXACT_TAGS=<csv> to check proxy/native tags with
#     `--no-platform --exact` while checking archive tags with default
#     restore-style resolution.
#   - Set BORINGCACHE_CHECK_STRICT=1 to enable `--no-platform --exact`
#     for every tag and hard-fail on misses (grpc behavior).
#   - Set BORINGCACHE_STORAGE_MISSING_PATH=<file> to enable the soft
#     warning + missing-tag-list + inspect-fallback flow (hugo-go).
#     This implies strict resolution flags but does not hard-fail.
#   - Set BORINGCACHE_STORAGE_BREAKDOWN_PATH=<file> to also write a JSON
#     breakdown of hit entries by storage component. This keeps stdout
#     backward-compatible: stdout remains only the total byte count.
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

tmp_file="$(mktemp)"
stderr_file="$(mktemp)"
tmp_dir="$(mktemp -d)"
trap 'rm -f "$tmp_file" "$stderr_file"; rm -rf "$tmp_dir"' EXIT

run_check() {
  local output_file="$1"
  shift

  if ! boringcache "$@" > "$output_file" 2>> "$stderr_file"; then
    echo "boringcache check failed while measuring remote storage for tags: ${tags_csv}" >&2
    cat "$stderr_file" >&2
    exit 1
  fi
}

to_num() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo "0"
  fi
}

component_type_for() {
  local storage_mode="$1"
  local tag="$2"
  local primary_tag="$3"
  local combined="${tag} ${primary_tag}"

  case "$storage_mode" in
    cas)
      echo "remote_cas"
      ;;
    archive)
      if [[ "$combined" == *"-mise-"* || "$combined" == *"runtime"* ]]; then
        echo "tool_runtime_archive"
      else
        echo "dependency_archive"
      fi
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

component_label_for() {
  local component_type="$1"
  local tag="$2"

  case "$component_type" in
    remote_cas)
      echo "remote CAS"
      ;;
    tool_runtime_archive)
      echo "tool runtime archive"
      ;;
    dependency_archive)
      echo "dependency archive"
      ;;
    *)
      echo "${tag:-unknown}"
      ;;
  esac
}

write_storage_breakdown() {
  local output_path="${BORINGCACHE_STORAGE_BREAKDOWN_PATH:-}"
  [[ -n "$output_path" ]] || return 0

  local components_file
  components_file="$(mktemp)"
  local breakdown_stderr
  breakdown_stderr="$(mktemp)"

  declare -A seen_breakdown_entries=()

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue

    local key tag requested_tag inspect_target inspect_json
    key="$(jq -r '.cache_entry_id // .cacheEntryId // .manifest_root_digest // .manifestRootDigest // .requested_tag // .requestedTag // .tag // "unknown"' <<<"$row")"
    if [[ -n "${seen_breakdown_entries[$key]+x}" ]]; then
      continue
    fi
    seen_breakdown_entries[$key]=1

    tag="$(jq -r '.tag // .requested_tag // .requestedTag // empty' <<<"$row")"
    requested_tag="$(jq -r '.requested_tag // .requestedTag // .tag // empty' <<<"$row")"
    [[ -n "$tag" ]] || continue
    inspect_target="$(jq -r '.cache_entry_id // .cacheEntryId // empty' <<<"$row")"
    inspect_target="${inspect_target:-$tag}"

    inspect_json="$(boringcache inspect "$workspace" "$inspect_target" --json 2> "$breakdown_stderr" || true)"
    if [[ -z "$inspect_json" ]]; then
      echo "boringcache inspect failed while writing storage breakdown for tag: ${tag}" >&2
      cat "$breakdown_stderr" >&2
      rm -f "$components_file" "$breakdown_stderr"
      exit 1
    fi

    local entry_id primary_tag storage_mode stored_size archive_size blob_total_size component_type component_label
    entry_id="$(jq -r '.entry.id // empty' <<<"$inspect_json")"
    primary_tag="$(jq -r '.entry.primary_tag // empty' <<<"$inspect_json")"
    storage_mode="$(jq -r '.entry.storage_mode // "unknown"' <<<"$inspect_json")"
    stored_size="$(jq -r '.entry.stored_size_bytes // .entry.compressed_size // .entry.blob_total_size_bytes // 0' <<<"$inspect_json")"
    archive_size="$(jq -r '.entry.archive_size // .entry.compressed_size // 0' <<<"$inspect_json")"
    blob_total_size="$(jq -r '.entry.blob_total_size_bytes // 0' <<<"$inspect_json")"
    stored_size="$(to_num "$stored_size")"
    archive_size="$(to_num "$archive_size")"
    blob_total_size="$(to_num "$blob_total_size")"
    component_type="$(component_type_for "$storage_mode" "$tag" "$primary_tag")"
    component_label="$(component_label_for "$component_type" "$tag")"

    jq -c -n \
      --arg tag "$tag" \
      --arg requested_tag "$requested_tag" \
      --arg entry_id "$entry_id" \
      --arg primary_tag "$primary_tag" \
      --arg storage_mode "$storage_mode" \
      --arg component_type "$component_type" \
      --arg component_label "$component_label" \
      --argjson bytes "$stored_size" \
      --argjson archive_size_bytes "$archive_size" \
      --argjson blob_total_size_bytes "$blob_total_size" \
      '{
        tag: $tag,
        requested_tag: $requested_tag,
        cache_entry_id: $entry_id,
        primary_tag: (if $primary_tag == "" then null else $primary_tag end),
        storage_mode: $storage_mode,
        component_type: $component_type,
        component_label: $component_label,
        bytes: $bytes,
        archive_size_bytes: $archive_size_bytes,
        blob_total_size_bytes: $blob_total_size_bytes
      }' >> "$components_file"
  done < <(jq -c '.results[]? | select((.status // "") == "hit")' "$tmp_file")

  mkdir -p "$(dirname "$output_path")"
  jq -s --arg workspace "$workspace" --arg tags_csv "$tags_csv" '
    def sum_type($type):
      map(select(.component_type == $type) | .bytes) | add // 0;

    {
      workspace: $workspace,
      tags: ($tags_csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
      total_bytes: (map(.bytes) | add // 0),
      summary: {
        remote_cas_bytes: sum_type("remote_cas"),
        dependency_archive_bytes: sum_type("dependency_archive"),
        tool_runtime_archive_bytes: sum_type("tool_runtime_archive"),
        unknown_bytes: sum_type("unknown")
      },
      components: .
    }
  ' "$components_file" > "$output_path"

  rm -f "$components_file" "$breakdown_stderr"
}

if (( strict_mode == 1 )); then
  run_check "$tmp_file" check "$workspace" "$tags_csv" --no-git --no-platform --exact --json
elif [[ -n "${BORINGCACHE_EXACT_TAGS:-}" ]]; then
  exact_lookup=",${BORINGCACHE_EXACT_TAGS//[[:space:]]/},"
  archive_tags=()
  exact_tags=()

  IFS=',' read -r -a tag_list <<< "$tags_csv"
  for raw_tag in "${tag_list[@]}"; do
    tag="${raw_tag//[[:space:]]/}"
    [[ -n "$tag" ]] || continue

    if [[ "$exact_lookup" == *",$tag,"* ]]; then
      exact_tags+=("$tag")
    else
      archive_tags+=("$tag")
    fi
  done

  check_files=()
  if [[ ${#archive_tags[@]} -gt 0 ]]; then
    archive_tags_csv="$(IFS=,; echo "${archive_tags[*]}")"
    archive_json="${tmp_dir}/archive.json"
    run_check "$archive_json" check "$workspace" "$archive_tags_csv" --json
    check_files+=("$archive_json")
  fi

  if [[ ${#exact_tags[@]} -gt 0 ]]; then
    exact_tags_csv="$(IFS=,; echo "${exact_tags[*]}")"
    exact_json="${tmp_dir}/exact.json"
    run_check "$exact_json" check "$workspace" "$exact_tags_csv" --no-git --no-platform --exact --json
    check_files+=("$exact_json")
  fi

  jq -s '
    def all_results: [.[].results[]?];
    {
      schema_version: (.[0].schema_version // 1),
      workspace: (.[0].workspace // ""),
      results: all_results
    }
  ' "${check_files[@]}" > "$tmp_file"
else
  run_check "$tmp_file" check "$workspace" "$tags_csv" --json
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

write_storage_breakdown
echo "$total"
