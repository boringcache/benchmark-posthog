# benchmark-posthog

Public PostHog benchmark runner for BoringCache vs GitHub Actions cache.

This repo exists separately from [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) so the benchmark can keep:

- one pinned upstream source commit
- isolated GitHub Actions cache usage
- one per-repo BoringCache workspace name: `boringcache/benchmark-posthog`
- independent workflow history plus upstream-sync-driven benchmark runs and manual dispatches

## Source Model

- Upstream app source lives in the pinned `upstream/` submodule.
- Plain Docker cache lanes use the pinned upstream `upstream/Dockerfile`
  directly with `upstream/` as the build context.
- The BuildKit backend lane uses the pinned upstream `upstream/Dockerfile`
  with native BoringCache BuildKit mountcache offload enabled for the upstream
  cache mounts such as `pnpm` and `uv`, plus native BoringCache BuildKit
  tool-cache env injection for Turbo.
- The benchmark-only `scenarios/posthog-turbo-cache-mounts.patch` patch is kept
  for targeted mountcache experiments, but it is not part of the default rolling
  BuildKit lane. Turbo's local cache grows as a task-output store, so preserving
  it as a whole cache-mount archive can make every future restore slower.
- `scenarios/posthog-toolcache/Dockerfile` remains available for explicit Turbo
  toolcache experiments, but the default BuildKit lane does not use the local
  Dockerfile fixture.
- `scripts/prepare-source.sh` only resets the upstream checkout and applies named benchmark scenarios.

Pinned upstream source:

- see committed `upstream/` submodule on `main`

## What It Measures

Fresh runs use the scenario set:

- `cold`: empty remote cache, empty local Docker cache
- `warm1`

BoringCache lanes are split so product capabilities are visible instead of
mixed into one number: `BC OCI` and `BC BuildKit Backend`. Treat `BC BuildKit
Backend` as the current fast lane for the headline rolling signal: it uses the
managed BuildKit backend for layer cache bodies plus native cache-mount
offload and native Turbo tool-cache env injection against the upstream
Dockerfile. Turbo's local task cache stays out of BuildKit cache-mount archive
offload.
Benchmark-created BuildKit daemons default to the public mirror
`mirror.gcr.io/moby/buildkit:buildx-stable-1` so release measurements are not
blocked by Docker Hub anonymous pull limits.
The GitHub Actions workflow keeps the historical amd64 product lane matrix and
adds one BuildKit-backend-only native arm64 path on `ubuntu-24.04-arm`. The arm
path uses an `arm-` prefix so it does not disturb the historical amd64 rolling
scope.

Rolling runs record the upstream commit build as-is after upstream sync against the stable rolling cache tags. They do not run a separate `warm1` follow-up.

The story this benchmark is meant to show is:

- speed on fresh cold and warm paths
- commit-build behavior on normal upstream syncs in the rolling lane
- storage footprint in each backend
- whether the OCI registry cache behaves as a simple outer Docker cache backend
- whether cache reuse stays understandable instead of turning into opaque blob growth

## Token Model

This repo uses split BoringCache tokens as the standard CI shape:

- `BORINGCACHE_RESTORE_TOKEN` for read-only restore and proxy access
- `BORINGCACHE_SAVE_TOKEN` for trusted write paths
- `BORINGCACHE_API_TOKEN` only where a single bearer variable is still required for compatibility

## Maintainer BuildKit State Canary

[`state-sync-v13-cas.yml`](.github/workflows/state-sync-v13-cas.yml) is
the isolated pre-graduation path for the CLI `--backend state` product. It is
manual-only and does not alter the public GHA, ECR, BC OCI, or managed
`type=boringcache` lanes. It deliberately does not use `boringcache/one` or a
Docker cache importer/exporter.

Every dispatch requires an exact CLI release tag, an independently supplied
SHA256 for its native release asset, and an exact
`ghcr.io/boringcache/buildkit@sha256:...` image. The workflow verifies the CLI
against both the supplied digest and the release's `SHA256SUMS`, resolves the
exact BuildKit digest while retaining its raw manifest, and records the exact
PostHog commit before running. It also probes the exact configured API origin
before pulling or building with the managed image. The probe fails closed
unless the complete CAS publish protocol, `expected_tag_head_v1`, and
`buildkit_state_current_set_v1` are advertised. Both the early backend probe
and the complete pin/source checklist are uploaded as machine-readable JSON;
the state runner refuses to start unless both passed.
The CLI asset is downloaded and checksum-verified before that probe; its
normalized `--version` value supplies the one exact
`User-Agent: BoringCache-CLI/<version>` header, matching the real Rust API
client rather than inferring a version from the release tag.
After benchmark-owned disk cleanup, the complete checklist also requires at
least 80 GiB free for `replay-full` and 55 GiB for the shorter lanes. This
accounts for the live BuildKit root, direct state transfer, and normal Docker
working space rather than discovering runner exhaustion mid-sequence.

- `fresh` uses one run-unique state tag for a cold build followed by 2, 4, or 8
  same-ref restores into newly created managed builders (`2` by default).
  Every warm phase uses the exact same source SHA. Cold-to-first-warm movement
  is recorded separately as bootstrap convergence, while positive growth is
  bounded. Every chronological transition is reported; the final warm-to-warm
  pair must plateau within tolerance. Intermediate movement remains evidence
  of convergence shape rather than an independent failure gate.
- `rolling` uses one stable tag scoped by BuildKit image digest, native
  platform, and source stream, then records a single commit build. The first
  run may bootstrap; later runs must report `restore.status=restored` to count
  as warm evidence.
- `replay-full` requires exactly 11 comma-separated immutable PostHog SHAs,
  verifies every SHA and first-parent edge, then advances one brand-new
  run/attempt-scoped state tag through all 11 generations in order.
- `replay-endpoints` validates and records the same exact 11-commit plan but
  measures only its base and target. This is the shorter smoke path; it is not
  presented as evidence for every intermediate generation.

Replay source checkout batches the exact commit set into one depth-one fetch
with Git auto-maintenance disabled. This avoids `.git/shallow` rewrite races
without relaxing per-commit identity or first-parent validation.

The artifact contains `buildkit-state-summary.v2`, wrapper/build and daemon
logs, observability JSONL, exact release/image/source provenance, transport
counters, timings, and a managed-resource cleanup check for every phase. The
hosted product lane uses BuildKit's cache-only output so it measures the real
state lifecycle without forcing a standalone OCI archive or timestamp rewrite.
Cold-versus-restored image semantics remain covered by the small local product
proof, where exporting both outputs is a cheap correctness regression rather
than PostHog-scale benchmark work.

Run [`29259506166`](https://github.com/boringcache/benchmark-posthog/actions/runs/29259506166)
proved why this boundary matters. The old harness spent `133.1s` exporting
layers, `144.9s` rewriting their timestamps, and `9.7s` writing the OCI tar.
Its generated image-config body then remained in the raw content CAS even
though it was absent from the retained main-namespace inventory, so the strict
state inventory refused publication. Source tracing points to exporter/build
history retention as the likely owner; the focused compatibility fix is to
drain and discard excluded history before terminal GC and checkpointing. That
run is exporter-compatibility evidence, not a state speed sample, and does not
justify weakening retained-content checks.

The canary requires explicit `save.logical_generation_blobs` and
`save.logical_generation_bytes` summary fields and fails closed when they are
absent. CAS upload bytes/counts remain explicitly labeled as transport delta;
they are not presented as an exact parent-set difference. The artifact also
records parent/restored/current generation lineage, the
`state-window-scaffold-clean-v1` policy, its `post-clean-measured` baseline,
two scoped local-source selectors, terminal content-GC application and timing,
and before/after scaffold-removal counts. A phase is invalid if a size or age
policy appears, the post-clean baseline disagrees with measured BuildKit DU, or
GC changes the remaining non-scaffold record set. Changed-source growth is
reported rather than disguised as a fixed backend size bound; signed restore
window rebases are accepted only when a following phase restores the new root.
The reported 0/1 head-fetch count is derived from the state summary's single
exact restored-generation field; it is not a packet counter. Fresh canaries
only pass when the final same-ref warm pair plateaus within the selected
provisional tolerance (2% by default), which guards against accidentally
publishing parent-plus-current unions. Every warm generation must also restore
exactly the preceding head into a new builder, fetch one head, leave no managed
resources behind, and show more cached steps plus fewer executed steps than the
cold build. The result records lineage, solver reuse, logical deltas,
percentages, and tolerance status for every transition so 4- and 8-warm runs
can show whether convergence is monotonic, oscillating, or still moving. The
backend audit fails closed unless the tag resolves to the exact just-published
generation and size. Superseded untagged versions are recorded separately as
asynchronous retention telemetry: they do not affect restore correctness or
stop later generations, but they must converge through server compaction and a
post-settle storage audit before release. The core canary forces BuildKit
mountcache off so archive growth cannot be mistaken for state-generation
growth.

Replay artifacts add the exact source plan and, for every measured generation,
the committed/restored/parent lineage, logical current-set bytes and blobs,
delta and percent change from the previous measured generation, transport
bytes and blobs, and cleanup result. Cross-commit plateau
is reported against the selected provisional tolerance for diagnosis; it is
not a correctness failure because a real source change may legitimately alter
the logical state size. Exact ordered source replay, one-head restore, CAS
lineage continuity, state-summary validity, and cleanup remain hard gates.

## BoringBuild EC2 Shape Sweep

Use [`scripts/run-boringbuild-ec2-shape-sweep.sh`](scripts/run-boringbuild-ec2-shape-sweep.sh) for private EC2 cold-plus-rolling checks across runner sizes. It generates ignored BoringBuild configs under `boringbuild/ec2-shape-sweep/`, stages a tiny source snapshot plus the local Linux `boringcache` binary, and runs the pinned PostHog `upstream/` commit window on AWS M-family general-purpose instances.

```bash
scripts/run-boringbuild-ec2-shape-sweep.sh --shapes 4c
scripts/run-boringbuild-ec2-shape-sweep.sh --shapes 8c,16c --parallel
```

Defaults are 10 first-parent commits ending at the current `upstream` HEAD, 50 GB EBS, on-demand purchase, M-family spec resolution (`m7i,m6i`), and `BENCHMARK_WORKSPACE=boringcache/monolith` for the private EC2 cache scope. The first commit is a cold `seed-cache` build; later commits are rolling `full` builds against the same cache scope. The runner fails fast after a failed phase because rolling results are not meaningful after a failed seed; pass `--keep-going` to collect later failures anyway. Results come back in `benchmark-results/ec2-.../` inside the exported tar under `boringbuild/ec2-shape-sweep/`. If a remote build fails before artifact export, inspect the per-run `boringbuild.log` and the matching `~/.boringbuild/remote/runs/run-*.log`.

The runner needs AWS CLI v2 on `PATH` because BoringBuild verifies EC2 credentials and key pairs with `aws sts`/`aws ec2` before launch. It sources `/Users/gaurav/boringcache/monorepo/.env`, resolves `BENCHMARK_WORKSPACE` after that file is loaded, then asks `bin/boringbuild-builders-env --provider aws` for AWS builder credentials. If credentials are missing or the helper emits warnings, check `boringbuild/ec2-shape-sweep/builders-env-*.log`. T-class families are rejected by the script; use M-family or another general-purpose family.

## Repo Layout

- [`scripts/prepare-source.sh`](scripts/prepare-source.sh)
- [`scripts/check-posthog-toolcache-dockerfile.sh`](scripts/check-posthog-toolcache-dockerfile.sh) verifies the toolcache Dockerfile stays equal to the pinned upstream Dockerfile plus the static Turbo remote-cache secret hooks.
- [`scripts/run-boringbuild-ec2-shape-sweep.sh`](scripts/run-boringbuild-ec2-shape-sweep.sh)
- [`docs/buildkit-mountcache-planner-experiment.md`](docs/buildkit-mountcache-planner-experiment.md) records the BuildKit mountcache planner experiment and the BC BuildKit vs ECR comparison for the July 6, 2026 spike run.
- [`.github/workflows/posthog-benchmark.yml`](.github/workflows/posthog-benchmark.yml) runs GitHub Actions Cache, ECR, and explicit BoringCache OCI and BuildKit-backend product lanes side by side.
- [`.github/workflows/rolling-dispatch.yml`](.github/workflows/rolling-dispatch.yml) runs the rolling lane after upstream sync.
- [`.github/workflows/sync.yml`](.github/workflows/sync.yml) keeps the pinned upstream source current.

## Output

Each workflow uploads:

- machine-readable benchmark JSON
- markdown summary

Those artifacts are intended to be ingested later by the central [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) publisher.

## Notes

- [2026-07-07 larger-runner accounting](docs/larger-runner-accounting-2026-07-07.md) records the 8c vs 16c GitHub larger-runner seed runs and a Depot runner-cost comparison.
