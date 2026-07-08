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
- The BuildKit backend lane uses `scenarios/posthog-toolcache/Dockerfile`,
  which is the pinned upstream Dockerfile plus static
  `boringcache-tool-cache-env` secret mounts around the two Turbo build steps.
  That lets Turbo use the BoringCache remote-cache protocol inside the Docker
  build without preserving `.turbo/cache` as a whole directory archive.
- The benchmark-only `scenarios/posthog-turbo-cache-mounts.patch` patch is kept
  for targeted mountcache experiments, but it is not part of the default rolling
  BuildKit lane. Turbo's local cache grows as a task-output store, so preserving
  it as a whole cache-mount archive can make every future restore slower.
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
managed BuildKit backend for layer cache bodies plus the Turbo toolcache bridge
inside the Dockerfile. Turbo's local task cache stays out of BuildKit
cache-mount archive offload.
Benchmark-created BuildKit daemons default to the public mirror
`mirror.gcr.io/moby/buildkit:buildx-stable-1` so release measurements are not
blocked by Docker Hub anonymous pull limits.

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
