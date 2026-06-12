# Hourly CDC tracking cycle — procedure

Run by a recurring loop. One iteration = check for a new rolling run; if
present, measure CDC on the new pair (naive analyze + product-path wire
bytes), record, rotate, push. State lives in `/home/user/snapshots/STATE`
(two lines: `<native_digest> <oci_digest>` of the last-analyzed B side and
their dir names).

Constants: workspace `boringcache/benchmark-posthog`; tags
`posthog-native-run-rolling-main` (native) and
`posthog-run-rolling-main-ubuntu-24-x86_64` (oci); CLI `/tmp/bin/boringcache`
(rebuild from monorepo `cli/` if missing); token env `/tmp/bc.env`;
snapshots under `/home/user/snapshots`.

## Steps

1. `. /tmp/bc.env && /tmp/bin/boringcache tags boringcache/benchmark-posthog --limit 50 --json`
   → current `manifest_root_digest` + `uploaded_at` for both tags.
2. Compare against STATE. If either unchanged → append nothing, end
   iteration silently. Both changed → proceed (a half-published run: retry
   next cycle).
3. Reconstruct the new pair B-side per lane with
   `cdc-experiment/restore_by_digest.sh <digest> /home/user/snapshots/<new_dir> <prev_dir>`
   (hardlinks unchanged blobs; downloads only churned ones; verifies all
   sha256). `<new_dir>` naming: `runD-native`, `runE-native`, ... advance a
   letter per cycle; prev dir comes from STATE.
4. Analyze (naive + file-aware, per class), 64K only on the hourly cadence:
   `python3 cdc-experiment/analyze.py <prev> <new> 65536` per lane.
   (Run 16K opportunistically at most once a day; sensitivity is
   established: 16K ≈ +8 points.)
5. Product-path wire bytes per lane:
   `cdc-experiment/wire_bytes.sh <prev> <new> 65536` → `WIRE_TOTAL` line.
6. Append one row per lane to `cdc-experiment/TRACKING.md` (columns
   documented there). Commit + push to `claude/adoring-ride-o0ulnu`
   (`git push -u origin claude/adoring-ride-o0ulnu`, retry x4 backoff).
7. Regression watch (record `clean` or signatures in the `bugs` column):
   - GitHub MCP: latest completed "Benchmark Rolling" run conclusion; if
     failed, failing job names.
   - `boringcache sessions ... --period 1h --json`: sessions with
     `error_count > 0`; flag signatures matching known classes
     (pointer/manifest 403/500, `no-local-snapshot`, KV tag-conflict spam,
     hang/timeout).
8. Rotate: delete the snapshot generation older than `<prev>` (its results
   are recorded). Keep >= 6GB free; if tight also `rm -rf` stale /tmp
   artifacts. Never delete `<prev>`/`<new>`.
9. Update STATE to the new pair.
10. Notify the user ONLY if: any lane naive 64K < 70% (verdict threat), a
    bug signature appeared, push failed, or reconstruction/verification
    failed. Otherwise stay silent.
