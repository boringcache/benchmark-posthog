# CDC Falsifying Experiment — Agent Handoff Runbook

## Mission (read first)

Decide with data whether CDC (content-defined chunking) of BuildKit layer
blobs is worth building for BoringCache. Today, a changed Docker layer is
re-uploaded whole: PostHog rolling runs re-upload ~3.5–5GB and re-read ~3GB
per run for small upstream diffs. CDC would dedup changed blobs at chunk
granularity against the previous run's chunks — in **uncompressed diff_id
space** (chunking compressed bytes would burst on any early change; the
diff_id/canonical-rewrite machinery already shipped is what makes serving
reassembled blobs to vanilla BuildKit possible).

The decision context lives in `boringcache/monorepo` branch
`claude/affectionate-dirac-6oqdtt`,
`.planning/features/docker-cache-solid-a-consolidation.md` (Phase 3, item 17).
Record the experiment outcome there when done.

**Pre-registered verdict thresholds (decided before seeing data — do not move
them after):** on the *changed* blobs only:
- naive stream-CDC dedup >= ~70% -> CDC pays as-is; record the
  transfer-reduction number for sizing.
- naive < ~40% but file-aware high -> CDC pays only with tar-aware
  (tar-split-style) chunking: header churn (fresh mtimes on rebuilt layers)
  is the blocker, not content. That is a bigger build; record both numbers.
- both low -> content genuinely churns; CDC does not pay for this workload.

Known foreshadowing from a synthetic worst case (50KB random files, all
mtimes touched between runs): naive 3%, file-aware 99.5%. Real layers have
many large files, so naive should land much higher — measure, don't assume.

## Prerequisites

- Environment network egress must allow `api.boringcache.com` and
  `t3.storage.dev` **including subdomains** (presigned URLs hit
  `workspace-<uuid>.t3.storage.dev`). If restore fails with
  "Host not in allowlist: workspace-...", the allowlist lacks subdomain
  matching — fix that first.
- `BORINGCACHE_RESTORE_TOKEN` for workspace `boringcache/benchmark-posthog`
  (read-only restore is enough; ask the user, do not expect it in the repo).
- Rust toolchain; ~25GB free disk; python3.
- `boringcache` CLI >= 1.13.51: either install the released CLI from the
  public `boringcache/cli` instructions, or `cargo build` from monorepo
  `cli/` if that repo is in the session (debug binary is fine).

## Steps

```bash
export BORINGCACHE_RESTORE_TOKEN=...   # from the user
cd cdc-experiment && cargo build --release && cd ..

# 1. Discover the rolling tag names (lanes use scope + platform suffix).
curl -s -H "Authorization: Bearer $BORINGCACHE_RESTORE_TOKEN" \
  "https://api.boringcache.com/v2/workspaces/boringcache/benchmark-posthog/tags?per_page=200" \
  > /tmp/tags.json
jq -r '..|.name? // empty' /tmp/tags.json | grep -i rolling | sort -u
# Known live example (BC OCI lane): posthog-run-rolling-main-ubuntu-24-x86_64
# Scope patterns from the workflow: ${BENCHMARK_ID}-run-rolling-${ref_slug}
# and ${BENCHMARK_ID}-rolling-${ref_slug}; native lanes have their own scopes
# (look for "native" in the tag list). Pick: one NATIVE rolling tag (zstd,
# BoringCache materializer) and one OCI rolling tag (gzip, vanilla BuildKit).

# 2. Snapshot run A (current version). Tags from the API are full names, so
#    disable automatic suffixing:
boringcache restore --no-platform --no-git boringcache/benchmark-posthog \
  "<native-rolling-tag>:runA-native,<oci-rolling-tag>:runA-oci"
# Each target dir must contain oci-layout + blobs/sha256/* (raw layer blobs).

# 3. Wait for the NEXT rolling run to overwrite the tag. Rolling dispatches
#    fire after upstream sync (every ~30-90 min). Poll the pointer until the
#    ETag/version changes (every 5 min):
curl -s -D- -o/dev/null -H "Authorization: Bearer $BORINGCACHE_RESTORE_TOKEN" \
  "https://api.boringcache.com/v2/workspaces/boringcache/benchmark-posthog/caches/tags/<native-rolling-tag>/pointer" \
  | grep -i etag
# (If that path 404s, find the tag-pointer route in the web app's routes, or
# just re-restore to a scratch dir and compare blob digests.)
# Alternatively watch the benchmark-posthog Actions for the next green
# "Benchmark Rolling" run, then proceed.

# 4. Snapshot run B:
boringcache restore --no-platform --no-git boringcache/benchmark-posthog \
  "<native-rolling-tag>:runB-native,<oci-rolling-tag>:runB-oci"

# 5. Analyze (both lanes; 64K and 16K chunk-size sensitivity):
python3 cdc-experiment/analyze.py runA-native runB-native 65536
python3 cdc-experiment/analyze.py runA-native runB-native 16384
python3 cdc-experiment/analyze.py runA-oci runB-oci 65536
```

## Validity controls (why the result can be trusted)

- Identical-digest blobs are excluded — they are already free today
  (BuildKit/CAS skip them); only genuinely re-uploaded bytes are measured.
- Both tar producers measured: BoringCache native materializer (zstd) and
  vanilla BuildKit exporter (gzip). If their churn differs, it shows up as a
  lane divergence instead of being averaged away.
- Naive vs file-aware mode separates tar-header churn (mtimes) from real
  content churn; per-blob class output makes outliers inspectable.
- If run A and run B show ~all identical digests, no rolling run happened in
  between (or the build was fully cached) — wait another cycle; do not
  conclude from an empty changed set.

## Wrap-up

1. Paste the per-class table + totals in chat.
2. Apply the pre-registered verdict; update
   `.planning/features/docker-cache-solid-a-consolidation.md` in the
   monorepo branch with the numbers and the go/no-go.
3. Tell the user to rotate the tokens used.
