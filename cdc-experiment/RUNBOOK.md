# CDC Falsifying Experiment

Measures cross-run chunk-level dedup on real PostHog BuildKit cache layer
blobs, to decide whether CDC chunked packs are worth building.
Pre-registered verdict: naive >=70% dedup on changed blobs -> CDC pays as-is;
naive <40% with file-aware high -> needs tar-aware (tar-split) chunking;
both low -> CDC does not pay for this workload.

## Requirements
- Rust toolchain; network to api.boringcache.com and *.t3.storage.dev
- BORINGCACHE_RESTORE_TOKEN for workspace boringcache/benchmark-posthog
- boringcache CLI (debug build is fine)

## Steps
```bash
cd cdc-experiment && cargo build --release && cd ..

# 1. Find the rolling tags (native zstd lane and OCI lane)
curl -s -H "Authorization: Bearer $BORINGCACHE_RESTORE_TOKEN" \
  "https://api.boringcache.com/v2/workspaces/boringcache/benchmark-posthog/tags?per_page=100" | jq -r '.tags[]?.name // .[]?.name' | grep rolling

# 2. Restore current version (run A) of both lanes (tags are platform-suffixed;
#    use --no-platform if passing the full suffixed name)
boringcache restore boringcache/benchmark-posthog "<native-rolling-tag>:runA-native"
boringcache restore boringcache/benchmark-posthog "<oci-rolling-tag>:runA-oci"

# 3. After the next rolling dispatch completes (~30-90 min), restore as run B
boringcache restore boringcache/benchmark-posthog "<native-rolling-tag>:runB-native"
boringcache restore boringcache/benchmark-posthog "<oci-rolling-tag>:runB-oci"

# 4. Analyze (both lanes, two chunk-size sensitivities)
python3 cdc-experiment/analyze.py runA-native runB-native 65536
python3 cdc-experiment/analyze.py runA-native runB-native 16384
python3 cdc-experiment/analyze.py runA-oci runB-oci 65536
```

Validity controls: identical-digest blobs are excluded (already free today);
both tar producers measured (BoringCache native materializer zstd vs vanilla
BuildKit exporter gzip); per-blob class output so outliers are inspectable;
naive vs file-aware separates header churn from real content churn.
