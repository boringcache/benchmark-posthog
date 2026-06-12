#!/bin/bash
# Chunking compute-cost benchmark over a pair's CHANGED blobs (the product
# save-path set). Configs: drain (decompress-only baseline), chunk 64K,
# chunk 16K, novel 64K (chunk + store lookup + zstd-3 of novel = full
# save-path work). Reports wall seconds and uncompressed MB/s per config.
# Single-threaded per blob, sequential - worst case; the product can
# parallelize across blobs.
# usage: time_cost.sh <dirA> <dirB>
set -euo pipefail
A="$1"; B="$2"
TOOL="$(dirname "$(readlink -f "$0")")/target/release/cdc-tool"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

is_layer() {
  local m; m=$(od -A n -t x1 -N 4 "$1" | tr -d ' \n')
  [[ "$m" == 28b52ffd* || "$m" == 1f8b* ]]
}

CHANGED=()
for f in "$B"/blobs/sha256/*; do
  [ -f "$A/blobs/sha256/$(basename "$f")" ] && continue
  is_layer "$f" && CHANGED+=("$f")
done
echo "changed layer blobs: ${#CHANGED[@]}"

# store for novel mode (the product persists the previous run's index, so
# this cost is restore-side-free; reported separately for completeness)
t0=$(date +%s.%N)
for f in "$A"/blobs/sha256/*; do
  is_layer "$f" || continue
  "$TOOL" chunk "$f" 65536 | awk '$1=="C"{print $2}'
done | sort -u > "$WORK/store64.txt"
t1=$(date +%s.%N)
echo "$t0 $t1" | awk '{printf "store-build (all A blobs, 64K, single-thread): %.1fs\n", $2-$1}'
echo "store chunks: $(wc -l < "$WORK/store64.txt")"

run_drain()   { "$TOOL" drain "$1"; }
run_chunk64() { "$TOOL" chunk "$1" 65536 | tail -1; }
run_chunk16() { "$TOOL" chunk "$1" 16384 | tail -1; }
run_novel64() { "$TOOL" novel "$1" 65536 "$WORK/store64.txt"; }

bench() {
  local name="$1" fn="$2" t0 t1 bytes=0 out b
  t0=$(date +%s.%N)
  for f in "${CHANGED[@]}"; do
    out=$($fn "$f" | tail -1)
    b=$(echo "$out" | grep -o 'T [0-9]*' | head -1 | awk '{print $2}')
    bytes=$((bytes + ${b:-0}))
  done
  t1=$(date +%s.%N)
  echo "$t0 $t1 $bytes" | awk -v n="$name" \
    '{d=$2-$1; printf "%-10s wall=%6.1fs uncomp=%5.1fGB throughput=%5.0fMB/s\n", n, d, $3/1e9, ($3/1e6)/d}'
}

bench drain    run_drain
bench chunk64K run_chunk64
bench chunk16K run_chunk16
bench novel64K run_novel64
