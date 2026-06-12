# CDC rolling tracking — one row per lane per analyzed pair

Procedure: `CYCLE.md`. Naive/file-aware from `analyze.py` 64K totals;
`wire` and `reduction` from `wire_bytes.sh` (novel chunks batched per blob,
zstd-3). `bugs`: `clean` or comma-separated signatures (see CYCLE.md step 7).

| utc | pair | lane | changed blobs | changed uncomp MB | reupload comp MB | naive64K | file-aware64K | wire MB | reduction | bugs |
|---|---|---|---|---|---|---|---|---|---|---|
| 2026-06-12T08:48Z | 244->245 | oci | 33/88 | 13066 | 3199 | 75.8% | 90.0% | - | - | clean |
| 2026-06-12T09:45Z | 245->246 | oci | 33/88 | 13066 | 3199 | 73.0% | 86.4% | - | - | clean |
| 2026-06-12T09:45Z | 245->246 | native | 50/90 | 14602 | 3942 | 74.6% | 87.5% | - | - | clean |
| 2026-06-12T12:20Z | 246->247 | native | 56/83 | 20493 | 5560 | 70.0% | 82.8% | 1397 | 4.0x | clean |
| 2026-06-12T12:30Z | 246->247 | oci | 53/86 | 19941 | 5153 | 69.3% | 82.3% | 1391 | 3.7x | clean |
| 2026-06-12T13:25Z | 247->248 | native | 44/83 | 14126 | 3776 | 58.0% | 68.5% | 1133 | 3.3x | chronic-put-noise; #248 in_progress at measure |
| 2026-06-12T13:25Z | 247->248 | oci | 34/86 | 13105 | 3197 | 55.1% | 66.2% | 1122 | 2.9x | chronic-put-noise; #248 in_progress at measure |
| 2026-06-12T14:05Z | 248->249 | native | 56/83 | 20410 | 5517 | 73.2% | 89.1% | 1281 | 4.3x | chronic-put-noise |
| 2026-06-12T14:05Z | 248->249 | oci | 47/86 | 13612 | 3339 | 74.6% | 90.2% | 839 | 4.0x | chronic-put-noise |
| 2026-06-12T16:25Z | 249->250 | native | 49/85 | 20376 | 5578 | 73.4% | 88.9% | 1279 | 4.4x | chronic-put-noise |
| 2026-06-12T16:25Z | 249->250 | oci | 39/87 | 19355 | 4984 | 72.3% | 88.4% | 1267 | 3.9x | chronic-put-noise |
| 2026-06-12T16:58Z | 250->251 | native | 58/87 | 20428 | 5525 | 75.3% | 91.1% | 1156 | 4.8x | chronic-put-noise |
| 2026-06-12T16:58Z | 250->251 | oci | 46/89 | 19360 | 4985 | 74.8% | 90.8% | 1129 | 4.4x | chronic-put-noise |
