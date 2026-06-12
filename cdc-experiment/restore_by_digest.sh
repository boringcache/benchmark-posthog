#!/bin/bash
# Reconstruct a snapshot by manifest_root_digest, hardlinking blobs present in a reference dir.
# usage: restore-by-digest.sh <sha256:digest> <dest_dir> <ref_dir>
set -euo pipefail
. /tmp/bc.env
API="https://api.boringcache.com/v2/workspaces/boringcache/benchmark-posthog"
UA="boringcache-cli/1.13.51"
AUTH="Authorization: Bearer $BORINGCACHE_RESTORE_TOKEN"
DIGEST="$1"; DEST="$2"; REF="$3"
TAGFILE="/tmp/$(basename "$DEST")"

mkdir -p "$DEST/blobs/sha256"

echo "== lookup $DIGEST"
curl -sf --max-time 30 -A "$UA" -H "$AUTH" "$API/caches?manifest_root_digest=$DIGEST" > "$TAGFILE-lookup.json"
STATUS=$(jq -r '.[0].status' "$TAGFILE-lookup.json")
ENTRY_ID=$(jq -r '.[0].cache_entry_id' "$TAGFILE-lookup.json")
MANIFEST_URL=$(jq -r '.[0].manifest_url' "$TAGFILE-lookup.json")
echo "status=$STATUS entry_id=$ENTRY_ID"
[ "$STATUS" = "hit" ] || { echo "ABORT: status=$STATUS"; exit 1; }

curl -sf --max-time 60 "$MANIFEST_URL" > "$TAGFILE-manifest.json"
echo "blobs=$(jq -r '.blobs | length' "$TAGFILE-manifest.json")"
jq -r '.oci_layout_base64' "$TAGFILE-manifest.json" | base64 -d > "$DEST/oci-layout"
jq -r '.index_json_base64' "$TAGFILE-manifest.json" | base64 -d > "$DEST/index.json"

for d in $(jq -r '.blobs[].digest' "$TAGFILE-manifest.json"); do
  hex=${d#sha256:}
  [ -f "$DEST/blobs/sha256/$hex" ] && continue
  [ -f "$REF/blobs/sha256/$hex" ] && ln "$REF/blobs/sha256/$hex" "$DEST/blobs/sha256/$hex"
done
ls "$DEST/blobs/sha256" > "$TAGFILE-have.txt"
jq --rawfile have "$TAGFILE-have.txt" \
  '($have | split("\n") | map(select(length>0)) | map({(.): true}) | add // {}) as $h
   | {cache_entry_id: "'"$ENTRY_ID"'", blobs: [.blobs[] | select(($h[(.digest | ltrimstr("sha256:"))] // false) | not) | {digest, size_bytes}]}' \
  "$TAGFILE-manifest.json" > "$TAGFILE-dlreq.json"
NMISS=$(jq '.blobs | length' "$TAGFILE-dlreq.json")
echo "hardlinked=$(wc -l < "$TAGFILE-have.txt") to_download=$NMISS"

if [ "$NMISS" -gt 0 ]; then
  curl -sf --max-time 120 -A "$UA" -H "$AUTH" -H "Content-Type: application/json" \
    -d @"$TAGFILE-dlreq.json" "$API/caches/blobs/download-urls" > "$TAGFILE-dlurls.json"
  echo "urls=$(jq '.download_urls | length' "$TAGFILE-dlurls.json") storage_missing=$(jq '.missing | length' "$TAGFILE-dlurls.json")"
  jq -r '.download_urls[] | [.digest, .url] | @tsv' "$TAGFILE-dlurls.json" \
    | while IFS=$'\t' read -r d url; do printf '%s\0%s\0' "${d#sha256:}" "$url"; done \
    | xargs -0 -n2 -P8 bash -c "curl -sf --retry 2 --max-time 600 -o '$DEST/blobs/sha256/'\$0 \"\$1\""
fi

FAIL=0
for d in $(jq -r '.blobs[].digest' "$TAGFILE-manifest.json"); do
  hex=${d#sha256:}
  [ -f "$DEST/blobs/sha256/$hex" ] || { echo "MISSING $hex"; FAIL=1; continue; }
  got=$(sha256sum "$DEST/blobs/sha256/$hex" | awk '{print $1}')
  [ "$got" = "$hex" ] || { echo "HASH MISMATCH $hex"; FAIL=1; }
done
[ "$FAIL" = 0 ] && echo "VERIFIED OK: $(ls "$DEST/blobs/sha256" | wc -l) blobs" || { echo "VERIFY FAILED"; exit 1; }
