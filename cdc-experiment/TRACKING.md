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
