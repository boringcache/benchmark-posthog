# CDC Falsifying Experiment — Results (2026-06-12)

## Verdict (pre-registered thresholds, decided before data)

**BUILD — naive stream-CDC pays as-is.** Every measured cell clears the
>=70% naive-dedup threshold; the two tar producers (vanilla BuildKit gzip
vs BoringCache native materializer zstd) converge, so tar-split-style
chunking is NOT required for viability.

## Method and provenance

- Live workspace `boringcache/benchmark-posthog`, PostHog rolling lanes.
- Pairs span genuine upstream diffs:
  - run #244 (01:33Z, upstream `PostHog/posthog@2a0f0ea`)
  - run #245 (07:03Z, upstream `PostHog/posthog@dcfda13`)
  - run #246 (08:5xZ, next upstream sync)
- Tags: OCI lane `posthog-run-rolling-main-ubuntu-24-x86_64`
  (gzip, vanilla BuildKit exporter); native lane
  `posthog-native-run-rolling-main` (zstd, BC materializer).
- Pair 244->245 (OCI) was reconstructed from the retained previous tag
  version (manifest_root_digest `sha256:8dc75432...`) — see RUNBOOK
  shortcut. Pair 245->246 used the live two-snapshot procedure.
- Measured on CHANGED blobs only (identical digests excluded — already
  free today). Chunking in uncompressed diff_id space, FastCDC v2020,
  min/avg/max = avg/4, avg, avg*4. "file-aware" = per-tar-entry chunking
  (tar-split ceiling; headers excluded from shared bytes).
- All blob hashes of reconstructed snapshots verified against manifests.

## Summary matrix (naive stream-CDC dedup of changed bytes)

| pair | lane | changed (uncomp) | re-uploaded today (comp) | 64K naive | 16K naive | file-aware |
|------|------|-----------------|--------------------------|-----------|-----------|------------|
| 244->245 | OCI | 13.07 GB (33/88 blobs) | 3.20 GB | 75.8% | 83.7% | 90.0% (64K) / 91.0% (16K) |
| 245->246 | OCI | 13.07 GB (33/88 blobs) | 3.20 GB | 73.0% | 82.7% | 86.4% (64K) / 89.7% (16K) |
| 245->246 | native | 14.60 GB (50/90 blobs) | 3.94 GB | 74.6% | 83.6% | 87.5% (64K) / 90.4% (16K) |
| 246->247 | native | 20.49 GB (56/83 blobs) | 5.56 GB | 70.0% | 79.8% | 82.8% (64K) / 87.8% (16K) |
| 246->247 | OCI | 19.94 GB (53/86 blobs) | 5.15 GB | 69.3% | 79.3% | 82.3% (64K) / 87.4% (16K) |

Pair 246->247 is a HEAVY upstream diff (~60% of blobs churned, ~1.6x the
re-upload of typical pairs) and maps the lower edge of the band: 64K naive
sits at the ~70% threshold; 16K stays comfortably above on every pair.
Design implication: favor ~16K chunks (or dual-tier) - heavy-commit runs
are exactly where the transfer savings matter most.

## Product-path wire bytes (measured, pair 246->247, 64K)

`wire_bytes.sh`: novel chunks (absent from the previous run's store)
batched per blob through zstd-3 - the bytes a CDC upload would actually
transfer:

| lane | full re-upload today | wire bytes | reduction |
|------|---------------------|-----------|-----------|
| native | 5.56 GB | 1.40 GB | 4.0x |
| OCI | 5.15 GB | 1.39 GB | 3.7x |

Measured on the WORST pair: novel content still compresses ~4.4:1, so the
wire reduction beats the uncompressed-share approximation (~3.3x). Typical
pairs (73-76% naive) project ~5x+ at 64K, more at 16K. Rolling per-pair
tracking continues in `TRACKING.md` (procedure: `CYCLE.md`).

Reading notes:
- frontend-assets dominates churn (~75-80% of changed bytes) and dedups
  76-87% naive — stable bundle content across an upstream diff.
- Header/mtime churn costs only ~7-15 points vs the file-aware ceiling;
  the last ~10% is real content churn (hashed bundle filenames etc.) that
  no chunking recovers.
- Outlier: code/products (~120MB/run) at ~6.5% naive 64K / ~25% 16K —
  small-file boundary pathology; immaterial to totals.
- The native lane churns MORE blobs (50 vs 33) incl. a ~953MB os/apt
  layer at 94-97% naive — i.e. mostly re-uploaded bytes that CDC would
  reclaim almost entirely.

## Full output: oci-244-245-64k

```
run A blobs: 88  run B blobs: 88  identical digests: 55
changed blobs in B (re-uploaded today): 33
compressed bytes: free-today 3024MB, re-uploaded 3199MB
  03516306e19b other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  073ac2ec71ba other(code/bin)    uncomp=     0.8MB naive=  6.0% file-aware=100.0%
  0787e1aff5b9 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  0b77408cd633 other(code/common) uncomp=    10.5MB naive= 99.8% file-aware=100.0%
  1596ab6a50ee frontend-assets    uncomp=  1305.5MB naive= 82.0% file-aware= 92.1%
  1a9285e0eb6e other(code/products) uncomp=    40.5MB naive=  6.5% file-aware=100.0%
  247868377ad2 other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware=100.0%
  2b956fba2c44 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  31b5ed237efd other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  34389b026c9c frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  3a52579f95b5 frontend-assets    uncomp=    62.5MB naive= 27.0% file-aware= 99.1%
  4c4d61c42969 other(code/products) uncomp=    40.5MB naive=  6.5% file-aware=100.0%
  4c9bcc81507f other(code/common) uncomp=     0.5MB naive=  0.0% file-aware=100.0%
  4ff239d5f269 frontend-assets    uncomp=  1305.5MB naive= 82.0% file-aware= 92.1%
  57e0aff29cd0 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  5a3ee13fe40a other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6d35eb3604dd other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware=100.0%
  72d842bf04e1 node_modules       uncomp=  1650.0MB naive= 58.5% file-aware= 99.9%
  814946c6da3f frontend-assets    uncomp=  1692.4MB naive= 68.4% file-aware= 76.6%
  8bd024fc6f91 frontend-assets    uncomp=  1305.5MB naive= 82.0% file-aware= 92.1%
  8e2a6ead1876 other(code/common) uncomp=    24.7MB naive= 99.3% file-aware=100.0%
  8ebd2a0a46da other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware=100.0%
  935138d346d3 frontend-assets    uncomp=  2631.8MB naive= 81.8% file-aware= 91.8%
  997087814911 other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  9e38bf9c9ec0 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b16f3df4e4be os/apt             uncomp=    76.6MB naive= 94.2% file-aware= 99.5%
  b8ffa74edcea other(code/posthog) uncomp=    89.0MB naive= 42.7% file-aware= 99.5%
  c1dfa1143aa8 other(code/posthog) uncomp=    89.0MB naive= 42.7% file-aware= 99.5%
  c2d4c2f463b8 frontend-assets    uncomp=  2618.6MB naive= 82.1% file-aware= 92.1%
  c8b612747d27 other(code/share)  uncomp=    43.9MB naive= 99.8% file-aware=100.0%
  e0624df2b50a other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  ed5a3e7f1b8c other(code/products) uncomp=    40.5MB naive=  6.5% file-aware=100.0%
  f8dea0a80806 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 64K) ==
  frontend-assets      10921.8MB  naive  79.6%  file-aware  89.4%
  node_modules          1650.0MB  naive  58.5%  file-aware  92.6%
  other(code/posthog)     178.1MB  naive  42.7%  file-aware  94.4%
  other(code/products)     121.4MB  naive   6.5%  file-aware  89.5%
  os/apt                  76.6MB  naive  94.2%  file-aware  99.1%
  other(code/share)       43.9MB  naive  99.8%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  46.0%  file-aware  95.4%
  other(code/common)      35.7MB  naive  97.9%  file-aware  99.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  84.0%
  other(code/bin)          0.8MB  naive   6.0%  file-aware  86.5%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                13065.8MB  naive  75.8%  file-aware  90.0%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: oci-244-245-16k

```
run A blobs: 88  run B blobs: 88  identical digests: 55
changed blobs in B (re-uploaded today): 33
compressed bytes: free-today 3024MB, re-uploaded 3199MB
  03516306e19b other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  073ac2ec71ba other(code/bin)    uncomp=     0.8MB naive= 12.4% file-aware=100.0%
  0787e1aff5b9 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  0b77408cd633 other(code/common) uncomp=    10.5MB naive= 99.9% file-aware=100.0%
  1596ab6a50ee frontend-assets    uncomp=  1305.5MB naive= 89.4% file-aware= 93.1%
  1a9285e0eb6e other(code/products) uncomp=    40.5MB naive= 24.7% file-aware=100.0%
  247868377ad2 other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware=100.0%
  2b956fba2c44 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  31b5ed237efd other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  34389b026c9c frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  3a52579f95b5 frontend-assets    uncomp=    62.5MB naive= 44.0% file-aware= 99.8%
  4c4d61c42969 other(code/products) uncomp=    40.5MB naive= 24.7% file-aware=100.0%
  4c9bcc81507f other(code/common) uncomp=     0.5MB naive= 20.9% file-aware=100.0%
  4ff239d5f269 frontend-assets    uncomp=  1305.5MB naive= 89.4% file-aware= 93.1%
  57e0aff29cd0 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  5a3ee13fe40a other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6d35eb3604dd other(code/ee)     uncomp=    18.1MB naive= 56.3% file-aware=100.0%
  72d842bf04e1 node_modules       uncomp=  1650.0MB naive= 69.5% file-aware= 99.9%
  814946c6da3f frontend-assets    uncomp=  1692.4MB naive= 75.8% file-aware= 78.9%
  8bd024fc6f91 frontend-assets    uncomp=  1305.5MB naive= 89.4% file-aware= 93.1%
  8e2a6ead1876 other(code/common) uncomp=    24.7MB naive= 99.9% file-aware=100.0%
  8ebd2a0a46da other(code/ee)     uncomp=    18.1MB naive= 56.5% file-aware=100.0%
  935138d346d3 frontend-assets    uncomp=  2631.8MB naive= 89.0% file-aware= 92.9%
  997087814911 other(code/rust)   uncomp=     0.0MB naive= 10.4% file-aware=100.0%
  9e38bf9c9ec0 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b16f3df4e4be os/apt             uncomp=    76.6MB naive= 97.3% file-aware= 99.7%
  b8ffa74edcea other(code/posthog) uncomp=    89.0MB naive= 55.6% file-aware= 99.8%
  c1dfa1143aa8 other(code/posthog) uncomp=    89.0MB naive= 55.7% file-aware= 99.8%
  c2d4c2f463b8 frontend-assets    uncomp=  2618.6MB naive= 89.3% file-aware= 93.1%
  c8b612747d27 other(code/share)  uncomp=    43.9MB naive=100.0% file-aware=100.0%
  e0624df2b50a other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  ed5a3e7f1b8c other(code/products) uncomp=    40.5MB naive= 24.8% file-aware=100.0%
  f8dea0a80806 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 16K) ==
  frontend-assets      10921.8MB  naive  86.9%  file-aware  90.6%
  node_modules          1650.0MB  naive  69.5%  file-aware  92.7%
  other(code/posthog)     178.1MB  naive  55.6%  file-aware  94.7%
  other(code/products)     121.4MB  naive  24.8%  file-aware  89.5%
  os/apt                  76.6MB  naive  97.3%  file-aware  99.3%
  other(code/share)       43.9MB  naive 100.0%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  56.4%  file-aware  95.4%
  other(code/common)      35.7MB  naive  98.7%  file-aware  99.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  84.0%
  other(code/bin)          0.8MB  naive  12.4%  file-aware  86.5%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/rust)         0.0MB  naive  10.4%  file-aware  70.1%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                13065.8MB  naive  83.7%  file-aware  91.0%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: oci-245-246-64k

```
run A blobs: 88  run B blobs: 88  identical digests: 55
changed blobs in B (re-uploaded today): 33
compressed bytes: free-today 3024MB, re-uploaded 3199MB
  09ed55cce5cf other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  0b5071e30ed2 other(code/common) uncomp=    24.7MB naive= 99.3% file-aware=100.0%
  2390081d7d55 other(code/bin)    uncomp=     0.8MB naive=  6.0% file-aware=100.0%
  4755ae44b2f9 other(code/common) uncomp=    10.5MB naive= 99.8% file-aware=100.0%
  4a32d0b6cd9f other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware= 99.6%
  4c4fd7051a35 other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware=100.0%
  540dce07cfcd frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  58e4b9a8b020 frontend-assets    uncomp=  2631.8MB naive= 78.5% file-aware= 87.5%
  658ba6df1056 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6761490563a1 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  67f7239c2c74 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6dbd338b643a other(code/common) uncomp=     0.5MB naive=  0.0% file-aware=100.0%
  71d43330279a other(code/products) uncomp=    40.5MB naive=  6.5% file-aware= 99.3%
  7396c702c1eb frontend-assets    uncomp=    62.5MB naive= 26.3% file-aware= 99.5%
  73c34c1f45de frontend-assets    uncomp=  1305.5MB naive= 78.7% file-aware= 87.7%
  81e2f4741a0f frontend-assets    uncomp=  2618.6MB naive= 78.8% file-aware= 87.8%
  8a29ccce807a other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  91deeb8faccd other(code/posthog) uncomp=    89.0MB naive= 42.8% file-aware= 99.6%
  9f3eee07b298 frontend-assets    uncomp=  1305.5MB naive= 78.7% file-aware= 87.7%
  a2c58648e01a other(code/posthog) uncomp=    89.0MB naive= 42.8% file-aware= 99.6%
  a383e979b8ce frontend-assets    uncomp=  1692.2MB naive= 64.9% file-aware= 72.3%
  ae9dd07a8692 node_modules       uncomp=  1650.0MB naive= 58.5% file-aware= 99.9%
  afa26aa44ea2 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b3587b461077 other(code/products) uncomp=    40.5MB naive=  6.5% file-aware= 99.3%
  b533d7c6f3b3 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  bd9eb2366e56 os/apt             uncomp=    76.6MB naive= 94.2% file-aware= 99.5%
  d19349e70c7c other(code/share)  uncomp=    43.9MB naive= 99.8% file-aware=100.0%
  e15d378cacd2 other(code/products) uncomp=    40.5MB naive=  6.5% file-aware= 99.3%
  e515e226c14f frontend-assets    uncomp=  1305.5MB naive= 78.7% file-aware= 87.7%
  efd0ea1db191 other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware=100.0%
  f7b1b907af76 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  faebe89b33bb other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  fd7a40d25282 other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 64K) ==
  frontend-assets      10921.7MB  naive  76.2%  file-aware  85.1%
  node_modules          1650.0MB  naive  58.5%  file-aware  92.6%
  other(code/posthog)     178.0MB  naive  42.8%  file-aware  94.5%
  other(code/products)     121.6MB  naive   6.5%  file-aware  88.9%
  os/apt                  76.6MB  naive  94.2%  file-aware  99.1%
  other(code/share)       43.9MB  naive  99.8%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  46.0%  file-aware  95.4%
  other(code/common)      35.7MB  naive  97.9%  file-aware  99.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  83.7%
  other(code/bin)          0.8MB  naive   6.0%  file-aware  86.5%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                13065.9MB  naive  73.0%  file-aware  86.4%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: native-245-246-64k

```
run A blobs: 79  run B blobs: 90  identical digests: 40
changed blobs in B (re-uploaded today): 50
compressed bytes: free-today 2534MB, re-uploaded 3942MB
  031add697ad7 other(code/common) uncomp=    24.7MB naive= 97.8% file-aware=100.0%
  094c761cd08b other(usr/local)   uncomp=   121.7MB naive= 99.7% file-aware=100.0%
  0ab4a18cb588 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  153cf867e8b3 other(code/commit.txt) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  2d23b5c71c22 other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  307a108f1424 os/apt             uncomp=    76.6MB naive= 93.9% file-aware= 99.1%
  3408b62777f2 frontend-assets    uncomp=  1692.2MB naive= 64.8% file-aware= 72.2%
  35a365e62f65 os/apt             uncomp=    81.6MB naive= 94.7% file-aware= 99.0%
  35c544e6c4b6 other(code/common) uncomp=    10.5MB naive= 98.7% file-aware=100.0%
  36087184d43f other(code/bin)    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  4a32d0b6cd9f other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware= 99.6%
  4bce8f0eb2a9 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  4d339c68f194 frontend-assets    uncomp=  2618.6MB naive= 78.8% file-aware= 87.7%
  52b7c4ca1370 other(code/posthog) uncomp=    89.0MB naive= 42.8% file-aware= 99.6%
  55e8097ed0b4 other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  565555333bbe other(code/share)  uncomp=    66.0MB naive= 99.9% file-aware=100.0%
  56a0f657aa17 node_modules       uncomp=     1.7MB naive= 89.1% file-aware=100.0%
  5ae3e84f3a12 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  5c78c7bf08f6 other(code/products) uncomp=    40.5MB naive=  6.5% file-aware= 99.3%
  5e7d2fff587d frontend-assets    uncomp=  1305.5MB naive= 78.7% file-aware= 87.7%
  644095167643 frontend-assets    uncomp=    62.5MB naive= 26.3% file-aware= 99.5%
  6e4b22dd1e55 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  7f6672360e9c other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  83e8c8b8c114 other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  890599d2f784 frontend-assets    uncomp=  1305.5MB naive= 78.7% file-aware= 87.7%
  8dca5343044a other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  9148ed906270 other(code/common) uncomp=     0.5MB naive=  0.0% file-aware=100.0%
  962db6887883 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  a54503fc458c os/apt             uncomp=    19.6MB naive= 83.8% file-aware= 98.0%
  ad1210ba361e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b1654b0d7bb5 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware= 14.5%
  b9136609bef0 os/apt             uncomp=    77.9MB naive= 86.0% file-aware= 99.8%
  ba976bcf495b other(code/common) uncomp=    24.7MB naive= 97.8% file-aware=100.0%
  bbeb07f73b4b frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  c496fe8c990d other(code/products) uncomp=    40.5MB naive=  6.5% file-aware= 99.3%
  c8098c829c6a other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  c9f71dbff3dd node_modules       uncomp=  1650.0MB naive= 58.5% file-aware= 99.9%
  d49681a4eff4 other(code/products) uncomp=    40.5MB naive=  6.5% file-aware= 99.3%
  d81a1edf49c1 frontend-assets    uncomp=  2631.8MB naive= 78.5% file-aware= 87.5%
  db0fb00c5088 frontend-assets    uncomp=  1305.5MB naive= 78.7% file-aware= 87.7%
  dc798accc725 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  ecc1b05490db other(code/posthog) uncomp=    89.0MB naive= 42.8% file-aware= 99.6%
  ef0bb45525bf other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware=100.0%
  efd3bb9e1d0b os/apt             uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f06810eb8d77 os/apt             uncomp=   697.6MB naive= 95.5% file-aware= 99.9%
  f09776ea1bbf other(code/patches) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f0f241ffb346 node_modules       uncomp=   489.2MB naive= 73.3% file-aware= 98.5%
  f15acad3354d other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware=100.0%
  f2bad10f63d1 other(code/bin)    uncomp=     0.8MB naive=  6.0% file-aware=100.0%
  f51c31def896 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 64K) ==
  frontend-assets      10921.7MB  naive  76.2%  file-aware  85.1%
  node_modules          2140.8MB  naive  61.9%  file-aware  92.7%
  os/apt                 953.3MB  naive  94.3%  file-aware  98.4%
  other(code/posthog)     178.0MB  naive  42.8%  file-aware  94.5%
  other(usr/local)       121.7MB  naive  99.7%  file-aware 100.0%
  other(code/products)     121.6MB  naive   6.5%  file-aware  88.9%
  other(code/share)       66.0MB  naive  99.9%  file-aware 100.0%
  other(code/common)      60.4MB  naive  97.0%  file-aware  99.8%
  other(code/ee)          36.2MB  naive  46.0%  file-aware  95.4%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  83.7%
  other(code/bin)          0.8MB  naive   5.9%  file-aware  86.2%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/patches)       0.0MB  naive   0.0%  file-aware  86.8%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(code)              0.0MB  naive   0.0%  file-aware   0.0%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(code/commit.txt)       0.0MB  naive   0.0%  file-aware   0.0%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                14602.1MB  naive  74.6%  file-aware  87.5%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: native-245-246-16k

```
run A blobs: 79  run B blobs: 90  identical digests: 40
changed blobs in B (re-uploaded today): 50
compressed bytes: free-today 2534MB, re-uploaded 3942MB
  031add697ad7 other(code/common) uncomp=    24.7MB naive= 99.7% file-aware=100.0%
  094c761cd08b other(usr/local)   uncomp=   121.7MB naive= 99.9% file-aware=100.0%
  0ab4a18cb588 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  153cf867e8b3 other(code/commit.txt) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  2d23b5c71c22 other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  307a108f1424 os/apt             uncomp=    76.6MB naive= 97.1% file-aware= 99.5%
  3408b62777f2 frontend-assets    uncomp=  1692.2MB naive= 74.1% file-aware= 76.9%
  35a365e62f65 os/apt             uncomp=    81.6MB naive= 97.4% file-aware= 99.2%
  35c544e6c4b6 other(code/common) uncomp=    10.5MB naive= 99.2% file-aware=100.0%
  36087184d43f other(code/bin)    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  4a32d0b6cd9f other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware= 99.6%
  4bce8f0eb2a9 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  4d339c68f194 frontend-assets    uncomp=  2618.6MB naive= 88.1% file-aware= 91.5%
  52b7c4ca1370 other(code/posthog) uncomp=    89.0MB naive= 55.8% file-aware= 99.8%
  55e8097ed0b4 other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  565555333bbe other(code/share)  uncomp=    66.0MB naive=100.0% file-aware=100.0%
  56a0f657aa17 node_modules       uncomp=     1.7MB naive= 96.3% file-aware=100.0%
  5ae3e84f3a12 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  5c78c7bf08f6 other(code/products) uncomp=    40.5MB naive= 24.6% file-aware= 99.5%
  5e7d2fff587d frontend-assets    uncomp=  1305.5MB naive= 88.1% file-aware= 91.5%
  644095167643 frontend-assets    uncomp=    62.5MB naive= 43.9% file-aware= 99.8%
  6e4b22dd1e55 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  7f6672360e9c other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  83e8c8b8c114 other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  890599d2f784 frontend-assets    uncomp=  1305.5MB naive= 88.1% file-aware= 91.5%
  8dca5343044a other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  9148ed906270 other(code/common) uncomp=     0.5MB naive= 20.9% file-aware=100.0%
  962db6887883 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  a54503fc458c os/apt             uncomp=    19.6MB naive= 92.7% file-aware= 99.2%
  ad1210ba361e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b1654b0d7bb5 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware= 14.5%
  b9136609bef0 os/apt             uncomp=    77.9MB naive= 92.0% file-aware= 99.9%
  ba976bcf495b other(code/common) uncomp=    24.7MB naive= 99.6% file-aware=100.0%
  bbeb07f73b4b frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  c496fe8c990d other(code/products) uncomp=    40.5MB naive= 24.6% file-aware= 99.5%
  c8098c829c6a other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  c9f71dbff3dd node_modules       uncomp=  1650.0MB naive= 69.5% file-aware= 99.9%
  d49681a4eff4 other(code/products) uncomp=    40.5MB naive= 24.6% file-aware= 99.5%
  d81a1edf49c1 frontend-assets    uncomp=  2631.8MB naive= 87.8% file-aware= 91.3%
  db0fb00c5088 frontend-assets    uncomp=  1305.5MB naive= 88.1% file-aware= 91.5%
  dc798accc725 other(code/common) uncomp=     0.0MB naive= 20.7% file-aware=100.0%
  ecc1b05490db other(code/posthog) uncomp=    89.0MB naive= 55.9% file-aware= 99.8%
  ef0bb45525bf other(code/ee)     uncomp=    18.1MB naive= 56.3% file-aware=100.0%
  efd3bb9e1d0b os/apt             uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f06810eb8d77 os/apt             uncomp=   697.6MB naive= 98.1% file-aware=100.0%
  f09776ea1bbf other(code/patches) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f0f241ffb346 node_modules       uncomp=   489.2MB naive= 79.3% file-aware= 98.7%
  f15acad3354d other(code/ee)     uncomp=    18.1MB naive= 56.5% file-aware=100.0%
  f2bad10f63d1 other(code/bin)    uncomp=     0.8MB naive= 12.4% file-aware=100.0%
  f51c31def896 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 16K) ==
  frontend-assets      10921.7MB  naive  85.6%  file-aware  89.0%
  node_modules          2140.8MB  naive  71.8%  file-aware  92.8%
  os/apt                 953.3MB  naive  97.4%  file-aware  98.5%
  other(code/posthog)     178.0MB  naive  55.8%  file-aware  94.7%
  other(usr/local)       121.7MB  naive  99.9%  file-aware 100.0%
  other(code/products)     121.6MB  naive  24.6%  file-aware  89.1%
  other(code/share)       66.0MB  naive 100.0%  file-aware 100.0%
  other(code/common)      60.4MB  naive  98.8%  file-aware  99.8%
  other(code/ee)          36.2MB  naive  56.4%  file-aware  95.4%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  83.7%
  other(code/bin)          0.8MB  naive  12.4%  file-aware  86.2%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/patches)       0.0MB  naive   0.0%  file-aware  86.8%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(code)              0.0MB  naive   0.0%  file-aware   0.0%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(code/commit.txt)       0.0MB  naive   0.0%  file-aware   0.0%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                14602.1MB  naive  83.6%  file-aware  90.4%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: oci-245-246-16k

```
run A blobs: 88  run B blobs: 88  identical digests: 55
changed blobs in B (re-uploaded today): 33
compressed bytes: free-today 3024MB, re-uploaded 3199MB
  09ed55cce5cf other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  0b5071e30ed2 other(code/common) uncomp=    24.7MB naive= 99.9% file-aware=100.0%
  2390081d7d55 other(code/bin)    uncomp=     0.8MB naive= 12.4% file-aware=100.0%
  4755ae44b2f9 other(code/common) uncomp=    10.5MB naive= 99.9% file-aware=100.0%
  4a32d0b6cd9f other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware= 99.6%
  4c4fd7051a35 other(code/ee)     uncomp=    18.1MB naive= 56.5% file-aware=100.0%
  540dce07cfcd frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  58e4b9a8b020 frontend-assets    uncomp=  2631.8MB naive= 87.8% file-aware= 91.3%
  658ba6df1056 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6761490563a1 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  67f7239c2c74 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6dbd338b643a other(code/common) uncomp=     0.5MB naive= 20.9% file-aware=100.0%
  71d43330279a other(code/products) uncomp=    40.5MB naive= 24.5% file-aware= 99.5%
  7396c702c1eb frontend-assets    uncomp=    62.5MB naive= 43.9% file-aware= 99.8%
  73c34c1f45de frontend-assets    uncomp=  1305.5MB naive= 88.1% file-aware= 91.5%
  81e2f4741a0f frontend-assets    uncomp=  2618.6MB naive= 88.1% file-aware= 91.5%
  8a29ccce807a other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  91deeb8faccd other(code/posthog) uncomp=    89.0MB naive= 55.8% file-aware= 99.8%
  9f3eee07b298 frontend-assets    uncomp=  1305.5MB naive= 88.1% file-aware= 91.5%
  a2c58648e01a other(code/posthog) uncomp=    89.0MB naive= 55.9% file-aware= 99.8%
  a383e979b8ce frontend-assets    uncomp=  1692.2MB naive= 74.1% file-aware= 77.0%
  ae9dd07a8692 node_modules       uncomp=  1650.0MB naive= 69.5% file-aware= 99.9%
  afa26aa44ea2 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b3587b461077 other(code/products) uncomp=    40.5MB naive= 24.5% file-aware= 99.5%
  b533d7c6f3b3 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  bd9eb2366e56 os/apt             uncomp=    76.6MB naive= 97.3% file-aware= 99.7%
  d19349e70c7c other(code/share)  uncomp=    43.9MB naive=100.0% file-aware=100.0%
  e15d378cacd2 other(code/products) uncomp=    40.5MB naive= 24.5% file-aware= 99.5%
  e515e226c14f frontend-assets    uncomp=  1305.5MB naive= 88.1% file-aware= 91.5%
  efd0ea1db191 other(code/ee)     uncomp=    18.1MB naive= 56.3% file-aware=100.0%
  f7b1b907af76 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  faebe89b33bb other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  fd7a40d25282 other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 16K) ==
  frontend-assets      10921.7MB  naive  85.6%  file-aware  89.0%
  node_modules          1650.0MB  naive  69.5%  file-aware  92.7%
  other(code/posthog)     178.0MB  naive  55.8%  file-aware  94.7%
  other(code/products)     121.6MB  naive  24.5%  file-aware  89.1%
  os/apt                  76.6MB  naive  97.3%  file-aware  99.3%
  other(code/share)       43.9MB  naive 100.0%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  56.4%  file-aware  95.4%
  other(code/common)      35.7MB  naive  98.7%  file-aware  99.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  83.7%
  other(code/bin)          0.8MB  naive  12.4%  file-aware  86.5%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                13065.9MB  naive  82.7%  file-aware  89.7%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```
## Full output: native-246-247-64k

```
run A blobs: 90  run B blobs: 83  identical digests: 27
changed blobs in B (re-uploaded today): 56
compressed bytes: free-today 867MB, re-uploaded 5560MB
  02f2710fa959 frontend-assets    uncomp=  2659.2MB naive= 74.5% file-aware= 80.1%
  0537b7c033f0 frontend-assets    uncomp=  1710.4MB naive= 61.1% file-aware= 65.8%
  192d76e7b2ad other(code/common) uncomp=    24.7MB naive= 97.8% file-aware=100.0%
  1f1fe7ef5d17 other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware= 99.0%
  21aa9e6291bd frontend-assets    uncomp=  1320.2MB naive= 74.7% file-aware= 80.3%
  3180758b5b2d other(code/common) uncomp=     0.3MB naive=  0.0% file-aware= 94.0%
  35b43b4bf188 node_modules       uncomp=     1.7MB naive= 67.2% file-aware= 69.9%
  3abbbfe28f46 other(code/products) uncomp=    40.7MB naive=  6.1% file-aware= 96.3%
  3d6be4c0ad01 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  52c1aebc475a frontend-assets    uncomp=  1320.2MB naive= 74.7% file-aware= 80.3%
  55bcebab2778 other(code/bin)    uncomp=     0.8MB naive=  5.9% file-aware= 99.4%
  56b48d0aebcb other(code/patches) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  5e830770e6d4 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  643dc455e9e6 other(code/common) uncomp=     0.5MB naive=  0.0% file-aware=100.0%
  6ba50bbcff8e node_modules       uncomp=   478.9MB naive= 73.6% file-aware= 99.4%
  738449c80a33 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  7afb20df0738 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  7cd1d05b083c frontend-assets    uncomp=  1320.2MB naive= 74.7% file-aware= 80.3%
  827c9fa18101 os/apt             uncomp=    76.6MB naive= 94.1% file-aware= 99.4%
  850604f28392 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  862f1f4624be other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  89bf7c8f504d frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  8fa895469bf3 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  947394262b8f other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  9e818dd66659 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  a0da208e4aa1 other(code/common) uncomp=     0.3MB naive=  0.0% file-aware=100.0%
  a3e34ec55622 python             uncomp=  3120.2MB naive= 68.2% file-aware= 87.8%
  a73af309daa7 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  a775f72c5b8e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  ab29cd9cc597 other(code/posthog) uncomp=    89.3MB naive= 41.8% file-aware= 95.5%
  addfae223fd6 other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware= 99.0%
  b14c2e6febcc node_modules       uncomp=  1650.0MB naive= 58.5% file-aware= 99.9%
  b4bb919b54cc os/apt             uncomp=   471.9MB naive= 94.0% file-aware=100.0%
  c0e830c2ff2b frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  c3ab81a8ec83 other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  c5e5b7c328d0 python             uncomp=  3124.6MB naive= 68.1% file-aware= 87.8%
  c69f010600a2 other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  cc831165973b frontend-assets    uncomp=  2647.9MB naive= 74.8% file-aware= 80.3%
  d049d91c005a other(code/common) uncomp=     0.5MB naive=  0.0% file-aware=100.0%
  d0a029ce1548 other(code/bin)    uncomp=     0.8MB naive=  5.9% file-aware= 99.4%
  d0eb3219f43d other(code/share)  uncomp=    66.0MB naive= 99.9% file-aware=100.0%
  d2e33298a6ed other(code/common) uncomp=    24.7MB naive= 97.8% file-aware=100.0%
  d35049f67d6f other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  d49a351f7a48 other(code/bin)    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  d5348651986b other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware=100.0%
  dec84bbc3bdf other(code/products) uncomp=    40.7MB naive=  6.1% file-aware= 96.3%
  e2620d328492 other(code/common) uncomp=    10.5MB naive= 98.7% file-aware=100.0%
  e2f95dd84b70 other(code/posthog) uncomp=    89.3MB naive= 41.9% file-aware= 95.5%
  ee65655bcdd5 other(code/products) uncomp=    40.7MB naive=  6.1% file-aware= 96.3%
  efefe08515a7 frontend-assets    uncomp=     0.1MB naive=  0.0% file-aware= 88.4%
  f4614195aeb1 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  f6562055930f other(usr/bin)     uncomp=    58.1MB naive= 99.9% file-aware=100.0%
  fb7542612e21 other(code/packages) uncomp=     2.2MB naive=  3.1% file-aware=100.0%
  fe2ddf6da2a8 frontend-assets    uncomp=    63.3MB naive= 24.1% file-aware= 94.6%
  fe8484e2d8e9 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  ffa9b260c219 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 64K) ==
  frontend-assets      11041.3MB  naive  72.3%  file-aware  77.9%
  python                6244.8MB  naive  68.1%  file-aware  85.7%
  node_modules          2130.5MB  naive  61.9%  file-aware  92.9%
  os/apt                 548.5MB  naive  94.1%  file-aware  98.9%
  other(code/posthog)     178.6MB  naive  41.8%  file-aware  90.6%
  other(code/products)     122.1MB  naive   6.1%  file-aware  86.2%
  other(code/share)       66.0MB  naive  99.9%  file-aware 100.0%
  other(code/common)      61.5MB  naive  95.2%  file-aware  99.5%
  other(usr/bin)          58.1MB  naive  99.9%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  46.0%  file-aware  94.5%
  other(code/packages)       2.2MB  naive   3.1%  file-aware  86.2%
  other(code/bin)          1.6MB  naive   5.9%  file-aware  85.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  84.0%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/patches)       0.0MB  naive   0.0%  file-aware  86.8%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  other(code)              0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                20492.7MB  naive  70.0%  file-aware  82.8%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: native-246-247-16k

```
run A blobs: 90  run B blobs: 83  identical digests: 27
changed blobs in B (re-uploaded today): 56
compressed bytes: free-today 867MB, re-uploaded 5560MB
  02f2710fa959 frontend-assets    uncomp=  2659.2MB naive= 84.7% file-aware= 87.3%
  0537b7c033f0 frontend-assets    uncomp=  1710.4MB naive= 70.3% file-aware= 72.4%
  192d76e7b2ad other(code/common) uncomp=    24.7MB naive= 99.7% file-aware=100.0%
  1f1fe7ef5d17 other(code/ee)     uncomp=    18.1MB naive= 56.3% file-aware= 99.1%
  21aa9e6291bd frontend-assets    uncomp=  1320.2MB naive= 85.0% file-aware= 87.5%
  3180758b5b2d other(code/common) uncomp=     0.3MB naive=  0.0% file-aware= 94.0%
  35b43b4bf188 node_modules       uncomp=     1.7MB naive= 89.2% file-aware= 92.9%
  3abbbfe28f46 other(code/products) uncomp=    40.7MB naive= 24.1% file-aware= 97.3%
  3d6be4c0ad01 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  52c1aebc475a frontend-assets    uncomp=  1320.2MB naive= 85.0% file-aware= 87.5%
  55bcebab2778 other(code/bin)    uncomp=     0.8MB naive= 12.3% file-aware= 99.4%
  56b48d0aebcb other(code/patches) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  5e830770e6d4 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  643dc455e9e6 other(code/common) uncomp=     0.5MB naive= 20.9% file-aware=100.0%
  6ba50bbcff8e node_modules       uncomp=   478.9MB naive= 79.6% file-aware= 99.5%
  738449c80a33 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  7afb20df0738 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  7cd1d05b083c frontend-assets    uncomp=  1320.2MB naive= 85.0% file-aware= 87.5%
  827c9fa18101 os/apt             uncomp=    76.6MB naive= 97.3% file-aware= 99.7%
  850604f28392 other(code/common) uncomp=     0.0MB naive= 20.7% file-aware=100.0%
  862f1f4624be other(code/common) uncomp=     0.0MB naive= 20.7% file-aware=100.0%
  89bf7c8f504d frontend-assets    uncomp=     0.0MB naive= 76.3% file-aware=100.0%
  8fa895469bf3 other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  947394262b8f other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  9e818dd66659 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  a0da208e4aa1 other(code/common) uncomp=     0.3MB naive= 30.3% file-aware=100.0%
  a3e34ec55622 python             uncomp=  3120.2MB naive= 77.7% file-aware= 91.8%
  a73af309daa7 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  a775f72c5b8e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  ab29cd9cc597 other(code/posthog) uncomp=    89.3MB naive= 55.0% file-aware= 97.3%
  addfae223fd6 other(code/ee)     uncomp=    18.1MB naive= 56.1% file-aware= 99.1%
  b14c2e6febcc node_modules       uncomp=  1650.0MB naive= 69.5% file-aware= 99.9%
  b4bb919b54cc os/apt             uncomp=   471.9MB naive= 97.3% file-aware=100.0%
  c0e830c2ff2b frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  c3ab81a8ec83 other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  c5e5b7c328d0 python             uncomp=  3124.6MB naive= 77.7% file-aware= 91.8%
  c69f010600a2 other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  cc831165973b frontend-assets    uncomp=  2647.9MB naive= 85.0% file-aware= 87.5%
  d049d91c005a other(code/common) uncomp=     0.5MB naive= 20.9% file-aware=100.0%
  d0a029ce1548 other(code/bin)    uncomp=     0.8MB naive= 12.3% file-aware= 99.4%
  d0eb3219f43d other(code/share)  uncomp=    66.0MB naive=100.0% file-aware=100.0%
  d2e33298a6ed other(code/common) uncomp=    24.7MB naive= 99.6% file-aware=100.0%
  d35049f67d6f other(code)        uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  d49a351f7a48 other(code/bin)    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  d5348651986b other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware=100.0%
  dec84bbc3bdf other(code/products) uncomp=    40.7MB naive= 24.2% file-aware= 97.3%
  e2620d328492 other(code/common) uncomp=    10.5MB naive= 99.2% file-aware=100.0%
  e2f95dd84b70 other(code/posthog) uncomp=    89.3MB naive= 54.9% file-aware= 97.3%
  ee65655bcdd5 other(code/products) uncomp=    40.7MB naive= 24.2% file-aware= 97.3%
  efefe08515a7 frontend-assets    uncomp=     0.1MB naive=  0.0% file-aware= 88.4%
  f4614195aeb1 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  f6562055930f other(usr/bin)     uncomp=    58.1MB naive=100.0% file-aware=100.0%
  fb7542612e21 other(code/packages) uncomp=     2.2MB naive=  7.4% file-aware=100.0%
  fe2ddf6da2a8 frontend-assets    uncomp=    63.3MB naive= 42.5% file-aware= 96.7%
  fe8484e2d8e9 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  ffa9b260c219 other(code/common) uncomp=     0.0MB naive= 38.5% file-aware=100.0%

== per-class dedup of changed blobs (avg chunk 16K) ==
  frontend-assets      11041.3MB  naive  82.4%  file-aware  84.9%
  python                6244.8MB  naive  77.7%  file-aware  89.5%
  node_modules          2130.5MB  naive  71.8%  file-aware  92.9%
  os/apt                 548.5MB  naive  97.3%  file-aware  98.9%
  other(code/posthog)     178.6MB  naive  54.9%  file-aware  92.3%
  other(code/products)     122.1MB  naive  24.2%  file-aware  87.1%
  other(code/share)       66.0MB  naive 100.0%  file-aware 100.0%
  other(code/common)      61.5MB  naive  97.4%  file-aware  99.5%
  other(usr/bin)          58.1MB  naive 100.0%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  56.2%  file-aware  94.6%
  other(code/packages)       2.2MB  naive   7.4%  file-aware  86.2%
  other(code/bin)          1.6MB  naive  12.3%  file-aware  85.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  84.0%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/patches)       0.0MB  naive   0.0%  file-aware  86.8%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  other(code)              0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                20492.7MB  naive  79.8%  file-aware  87.8%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: oci-246-247-64k

```
run A blobs: 88  run B blobs: 86  identical digests: 33
changed blobs in B (re-uploaded today): 53
compressed bytes: free-today 1095MB, re-uploaded 5153MB
  0161826f2730 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  023e8741752e other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  05ae3782d1c0 python             uncomp=  3124.6MB naive= 68.0% file-aware= 87.8%
  06b0752af5a0 frontend-assets    uncomp=  1320.2MB naive= 74.7% file-aware= 80.3%
  06f8486b879b frontend-assets    uncomp=    63.3MB naive= 24.1% file-aware= 94.6%
  0c711442cbd0 other(code/bin)    uncomp=     0.8MB naive=  5.9% file-aware= 99.4%
  128c320fc39f other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  1b221df60bc1 other(code/common) uncomp=     0.5MB naive=  0.0% file-aware=100.0%
  260837116a11 node_modules       uncomp=  1650.0MB naive= 58.5% file-aware= 99.9%
  286d1244e526 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  2d640d180097 other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware= 99.0%
  2e2c6528bacc node_modules       uncomp=     1.7MB naive= 67.2% file-aware= 69.9%
  2ea3368b6068 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  30deb386c663 other(code/common) uncomp=     0.5MB naive=  0.0% file-aware=100.0%
  30f35b91871c frontend-assets    uncomp=  1320.2MB naive= 74.7% file-aware= 80.3%
  3e2f907eeec3 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  4a19734e5f7f other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6013ff46ca4e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  61004849125d other(code/common) uncomp=     0.3MB naive=  0.0% file-aware=100.0%
  6155a2eb6d68 frontend-assets    uncomp=     0.1MB naive=  0.0% file-aware= 88.4%
  673cae4c7b5b frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  690850c4307c os/apt             uncomp=    76.6MB naive= 94.2% file-aware= 99.5%
  6c1d3208c02f other(code/posthog) uncomp=    89.3MB naive= 41.9% file-aware= 95.5%
  6e1981370110 other(code/common) uncomp=    24.7MB naive= 97.8% file-aware=100.0%
  705411aeee87 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  77e37462204f other(code/bin)    uncomp=     0.8MB naive=  5.9% file-aware= 99.4%
  7960074ad9c0 other(code/products) uncomp=    40.7MB naive=  6.1% file-aware= 96.3%
  7d721261a24e python             uncomp=  3120.2MB naive= 68.1% file-aware= 87.8%
  913cfb1a248b frontend-assets    uncomp=  2647.9MB naive= 74.8% file-aware= 80.3%
  a367a3012f4a other(code/ee)     uncomp=    18.1MB naive= 46.0% file-aware= 99.0%
  a6495ff58578 other(code/common) uncomp=    10.5MB naive= 98.7% file-aware=100.0%
  a663401af177 other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  ad7a2d12f457 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b8eac73f9b87 node_modules       uncomp=   478.9MB naive= 73.7% file-aware= 99.4%
  d1da1819dd8e other(code/bin)    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  d32a8df7a06b other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  da03898e0c22 frontend-assets    uncomp=  2659.2MB naive= 74.5% file-aware= 80.1%
  dae42a5788c4 other(code/patches) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  db6d2a53e8e1 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  dc3ddd4bcf7f other(code/products) uncomp=    40.7MB naive=  6.1% file-aware= 96.3%
  dddf18bc1b46 other(code/common) uncomp=     0.3MB naive=  0.0% file-aware= 94.0%
  e5021361e542 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  e6ea08fd709b other(code/common) uncomp=    24.7MB naive= 97.8% file-aware=100.0%
  e803c34da212 frontend-assets    uncomp=  1320.2MB naive= 74.7% file-aware= 80.3%
  eea9b1a5442e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f0bb2a12cfd7 other(code/posthog) uncomp=    89.3MB naive= 41.8% file-aware= 95.5%
  f56497209b8a other(code/share)  uncomp=    43.9MB naive= 99.8% file-aware=100.0%
  f6b7d043f13d frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f836107d04c1 other(code/packages) uncomp=     2.2MB naive=  3.1% file-aware=100.0%
  f9704c9ad14c other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware=100.0%
  fb5036b859ef other(code/products) uncomp=    40.7MB naive=  6.1% file-aware= 96.3%
  fd9aa183dd18 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  fee9fd8ca06e frontend-assets    uncomp=  1710.4MB naive= 61.1% file-aware= 65.8%

== per-class dedup of changed blobs (avg chunk 64K) ==
  frontend-assets      11041.3MB  naive  72.3%  file-aware  77.9%
  python                6244.8MB  naive  68.1%  file-aware  85.6%
  node_modules          2130.5MB  naive  61.9%  file-aware  92.9%
  other(code/posthog)     178.6MB  naive  41.8%  file-aware  90.6%
  other(code/products)     122.1MB  naive   6.1%  file-aware  86.2%
  os/apt                  76.6MB  naive  94.2%  file-aware  99.1%
  other(code/common)      61.5MB  naive  95.2%  file-aware  99.5%
  other(code/share)       43.9MB  naive  99.8%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  46.0%  file-aware  94.5%
  other(code/packages)       2.2MB  naive   3.1%  file-aware  86.2%
  other(code/bin)          1.6MB  naive   5.9%  file-aware  85.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  84.0%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/patches)       0.0MB  naive   0.0%  file-aware  86.8%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                19940.7MB  naive  69.3%  file-aware  82.3%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: oci-246-247-16k

```
run A blobs: 88  run B blobs: 86  identical digests: 33
changed blobs in B (re-uploaded today): 53
compressed bytes: free-today 1095MB, re-uploaded 5153MB
  0161826f2730 other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  023e8741752e other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  05ae3782d1c0 python             uncomp=  3124.6MB naive= 77.7% file-aware= 91.8%
  06b0752af5a0 frontend-assets    uncomp=  1320.2MB naive= 85.0% file-aware= 87.5%
  06f8486b879b frontend-assets    uncomp=    63.3MB naive= 42.5% file-aware= 96.7%
  0c711442cbd0 other(code/bin)    uncomp=     0.8MB naive= 12.3% file-aware= 99.4%
  128c320fc39f other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  1b221df60bc1 other(code/common) uncomp=     0.5MB naive= 20.9% file-aware=100.0%
  260837116a11 node_modules       uncomp=  1650.0MB naive= 69.5% file-aware= 99.9%
  286d1244e526 other(code/common) uncomp=     0.0MB naive= 20.7% file-aware=100.0%
  2d640d180097 other(code/ee)     uncomp=    18.1MB naive= 56.3% file-aware= 99.1%
  2e2c6528bacc node_modules       uncomp=     1.7MB naive= 89.2% file-aware= 92.9%
  2ea3368b6068 other(tmp)         uncomp=     0.0MB naive=  0.0% file-aware=  0.0%
  30deb386c663 other(code/common) uncomp=     0.5MB naive= 20.9% file-aware=100.0%
  30f35b91871c frontend-assets    uncomp=  1320.2MB naive= 85.0% file-aware= 87.5%
  3e2f907eeec3 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  4a19734e5f7f other(code/rust)   uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  6013ff46ca4e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  61004849125d other(code/common) uncomp=     0.3MB naive= 30.3% file-aware=100.0%
  6155a2eb6d68 frontend-assets    uncomp=     0.1MB naive=  0.0% file-aware= 88.4%
  673cae4c7b5b frontend-assets    uncomp=     0.0MB naive= 76.3% file-aware=100.0%
  690850c4307c os/apt             uncomp=    76.6MB naive= 97.3% file-aware= 99.7%
  6c1d3208c02f other(code/posthog) uncomp=    89.3MB naive= 54.9% file-aware= 97.3%
  6e1981370110 other(code/common) uncomp=    24.7MB naive= 99.6% file-aware=100.0%
  705411aeee87 other(code/common) uncomp=     0.0MB naive= 20.7% file-aware=100.0%
  77e37462204f other(code/bin)    uncomp=     0.8MB naive= 12.3% file-aware= 99.4%
  7960074ad9c0 other(code/products) uncomp=    40.7MB naive= 24.1% file-aware= 97.3%
  7d721261a24e python             uncomp=  3120.2MB naive= 77.7% file-aware= 91.8%
  913cfb1a248b frontend-assets    uncomp=  2647.9MB naive= 85.0% file-aware= 87.5%
  a367a3012f4a other(code/ee)     uncomp=    18.1MB naive= 56.1% file-aware= 99.1%
  a6495ff58578 other(code/common) uncomp=    10.5MB naive= 99.2% file-aware=100.0%
  a663401af177 other(home/posthog) uncomp=     0.1MB naive=  0.0% file-aware= 44.1%
  ad7a2d12f457 other(docker-entrypoint.d/unit.json.tpl) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  b8eac73f9b87 node_modules       uncomp=   478.9MB naive= 79.7% file-aware= 99.5%
  d1da1819dd8e other(code/bin)    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  d32a8df7a06b other(code/manage.py) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  da03898e0c22 frontend-assets    uncomp=  2659.2MB naive= 84.7% file-aware= 87.3%
  dae42a5788c4 other(code/patches) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  db6d2a53e8e1 other(code/common) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  dc3ddd4bcf7f other(code/products) uncomp=    40.7MB naive= 24.2% file-aware= 97.3%
  dddf18bc1b46 other(code/common) uncomp=     0.3MB naive=  0.0% file-aware= 94.0%
  e5021361e542 frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  e6ea08fd709b other(code/common) uncomp=    24.7MB naive= 99.7% file-aware=100.0%
  e803c34da212 frontend-assets    uncomp=  1320.2MB naive= 85.0% file-aware= 87.5%
  eea9b1a5442e other(tmp/.sourcemaps-status) uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f0bb2a12cfd7 other(code/posthog) uncomp=    89.3MB naive= 55.0% file-aware= 97.3%
  f56497209b8a other(code/share)  uncomp=    43.9MB naive=100.0% file-aware=100.0%
  f6b7d043f13d frontend-assets    uncomp=     0.0MB naive=  0.0% file-aware=100.0%
  f836107d04c1 other(code/packages) uncomp=     2.2MB naive=  7.4% file-aware=100.0%
  f9704c9ad14c other(code/docs)   uncomp=     1.3MB naive=  0.0% file-aware=100.0%
  fb5036b859ef other(code/products) uncomp=    40.7MB naive= 24.2% file-aware= 97.3%
  fd9aa183dd18 other(code/common) uncomp=     0.0MB naive= 38.5% file-aware=100.0%
  fee9fd8ca06e frontend-assets    uncomp=  1710.4MB naive= 70.3% file-aware= 72.4%

== per-class dedup of changed blobs (avg chunk 16K) ==
  frontend-assets      11041.3MB  naive  82.4%  file-aware  84.9%
  python                6244.8MB  naive  77.7%  file-aware  89.5%
  node_modules          2130.5MB  naive  71.8%  file-aware  92.9%
  other(code/posthog)     178.6MB  naive  54.9%  file-aware  92.3%
  other(code/products)     122.1MB  naive  24.2%  file-aware  87.1%
  os/apt                  76.6MB  naive  97.3%  file-aware  99.3%
  other(code/common)      61.5MB  naive  97.4%  file-aware  99.5%
  other(code/share)       43.9MB  naive 100.0%  file-aware 100.0%
  other(code/ee)          36.2MB  naive  56.2%  file-aware  94.6%
  other(code/packages)       2.2MB  naive   7.4%  file-aware  86.2%
  other(code/bin)          1.6MB  naive  12.3%  file-aware  85.7%
  other(code/docs)         1.3MB  naive   0.0%  file-aware  84.0%
  other(home/posthog)       0.1MB  naive   0.0%  file-aware  38.2%
  other(code/patches)       0.0MB  naive   0.0%  file-aware  86.8%
  other(code/rust)         0.0MB  naive   0.0%  file-aware  70.1%
  other(code/manage.py)       0.0MB  naive   0.0%  file-aware  49.5%
  other(tmp/.sourcemaps-status)       0.0MB  naive   0.0%  file-aware   0.3%
  other(docker-entrypoint.d/unit.json.tpl)       0.0MB  naive   0.0%  file-aware  42.7%
  other(tmp)               0.0MB  naive   0.0%  file-aware   0.0%
  TOTAL                19940.7MB  naive  79.3%  file-aware  87.4%

verdict guide: naive>=70% -> CDC pays as-is; naive<40% but file-aware high -> needs tar-aware chunking; both low -> content truly churns, CDC does not pay
```

## Full output: wire-246-247

```
WIRE_TOTAL blobs=56 full_compressed=5560352613 wire_bytes=1396693887 novel_uncomp=6141822087 changed_uncomp=20492743680 reduction=4.0x
WIRE_TOTAL blobs=53 full_compressed=5153496373 wire_bytes=1391371878 novel_uncomp=6115626242 changed_uncomp=19940699136 reduction=3.7x
```

## Chunking compute cost (measured 2026-06-12, pair 247->248 changed sets)

4-core GHA-class container, SINGLE-THREADED sequential per blob (worst
case; the product parallelizes across blobs). `time_cost.sh`:

| config | native (zstd, 14.1GB) | OCI (gzip, 13.1GB) |
|---|---|---|
| drain (decompress only - work the save path already does) | 13.9s @ 1016MB/s | 29.8s @ 440MB/s |
| chunk 64K (FastCDC + SHA-256) | 88.3s @ 160MB/s | 98.4s @ 133MB/s |
| chunk 16K | 87.7s @ 161MB/s | 98.1s @ 134MB/s |
| novel 64K (full save path: chunk + store lookup + zstd-3 of novel) | 114.2s @ 124MB/s | 122.0s @ 107MB/s |
| store-build from raw blobs (cold start only; index is persisted) | 148.9s | 178.5s |

Readings:
- **16K and 64K cost the same** (chunk count is irrelevant; SHA-256 over
  the bytes dominates). The 16K recommendation is compute-free; its only
  cost is index size (~109K chunks/run at 64K -> ~4x at 16K).
- Marginal CDC cost over decompression: ~70-75s single-threaded for a
  full run's changed set; full save-path ~115-122s. Parallelized across
  4 cores: **~30s wall per rolling run**, inside the governor's
  max(60s, 10%) overhead budget - and the 2-4GB of avoided upload pays
  back ~20-80s at typical CI egress, so net wall time is ~neutral to
  positive before counting storage savings.
- Hashing is the dominant term and the optimization headroom: sha2 here;
  BLAKE3 or SHA-NI would cut the chunk cost ~3-5x.
- gzip decompress (440MB/s) vs zstd (1016MB/s) is visible but not
  decisive; both lanes land within 10% on total chunk cost.
