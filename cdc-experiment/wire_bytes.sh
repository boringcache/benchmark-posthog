#!/bin/bash
# Product-path wire measurement: bytes a CDC upload would actually transfer.
# For each changed blob in B (digest absent from A), chunk in uncompressed
# diff_id space, keep only chunks NOT present in A's chunk store, batch the
# novel chunks per blob and zstd -3 them (what the wire would carry).
# usage: wire_bytes.sh <dirA> <dirB> <avg_chunk_size>
set -euo pipefail
A="$1"; B="$2"; AVG="${3:-65536}"
TOOL="$(dirname "$(readlink -f "$0")")/target/release/cdc-tool"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

is_layer() { # gzip or zstd magic
  local m; m=$(od -A n -t x1 -N 4 "$1" | tr -d ' \n')
  [[ "$m" == 28b52ffd* || "$m" == 1f8b* ]]
}

echo "== building chunk store from $A (avg ${AVG})" >&2
for f in "$A"/blobs/sha256/*; do
  is_layer "$f" || continue
  "$TOOL" chunk "$f" "$AVG" | awk '$1=="C"{print $2}'
done | sort -u > "$WORK/store.txt"
echo "store chunks: $(wc -l < "$WORK/store.txt")" >&2

total_full_compressed=0; total_wire=0; total_novel=0; total_uncomp=0; nblobs=0
for f in "$B"/blobs/sha256/*; do
  name=$(basename "$f")
  [ -f "$A/blobs/sha256/$name" ] && continue   # identical digest: free today
  is_layer "$f" || continue
  nblobs=$((nblobs+1))
  full=$(stat -c %s "$f")
  read -r _ wire _ novel _ uncomp < <("$TOOL" novel "$f" "$AVG" "$WORK/store.txt")
  total_full_compressed=$((total_full_compressed+full))
  total_wire=$((total_wire+wire))
  total_novel=$((total_novel+novel))
  total_uncomp=$((total_uncomp+uncomp))
  printf 'B %s full_comp=%d wire=%d novel_uncomp=%d uncomp=%d\n' "${name:0:12}" "$full" "$wire" "$novel" "$uncomp"
done

printf 'WIRE_TOTAL blobs=%d full_compressed=%d wire_bytes=%d novel_uncomp=%d changed_uncomp=%d reduction=%.1fx\n' \
  "$nblobs" "$total_full_compressed" "$total_wire" "$total_novel" "$total_uncomp" \
  "$(echo "$total_full_compressed $total_wire" | awk '{printf "%.1f", $1/$2}')"
