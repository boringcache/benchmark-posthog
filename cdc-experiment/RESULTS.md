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
| 245->246 | OCI | 13.07 GB (33/88 blobs) | 3.20 GB | 73.0% | pending (pass running; filled in follow-up commit) | 86.4% (64K) |
| 245->246 | native | 14.60 GB (50/90 blobs) | 3.94 GB | 74.6% | 83.6% | 87.5% (64K) / 90.4% (16K) |

Sizing: naive CDC cuts re-uploaded bytes ~4x at 64K (~5-6x at 16K),
approximating compressed savings by uncompressed dedup share.

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

