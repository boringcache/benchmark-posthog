# CDC rolling tracking — one row per lane per analyzed pair

Procedure: `CYCLE.md`. Naive/file-aware from `analyze.py` 64K totals;
`wire` and `reduction` from `wire_bytes.sh` (novel chunks batched per blob,
zstd-3). `bugs`: `clean` or comma-separated signatures (see CYCLE.md step 7).

| utc | pair | lane | changed blobs | changed uncomp MB | reupload comp MB | naive64K | file-aware64K | wire MB | reduction | bugs |
|---|---|---|---|---|---|---|---|---|---|---|
