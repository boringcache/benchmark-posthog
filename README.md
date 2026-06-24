# benchmark-posthog

Public PostHog benchmark runner for BoringCache vs GitHub Actions cache.

This repo exists separately from [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) so the benchmark can keep:

- one pinned upstream source commit
- isolated GitHub Actions cache usage
- one per-repo BoringCache workspace name: `boringcache/benchmark-posthog`
- independent workflow history plus upstream-sync-driven benchmark runs and manual dispatches

## Source Model

- Upstream app source lives in the pinned `upstream/` submodule.
- Docker builds use the unmodified upstream `upstream/Dockerfile` with `upstream/` as the build context.
- `scripts/prepare-source.sh` only resets the upstream checkout and applies named benchmark scenarios.

Pinned upstream source:

- see committed `upstream/` submodule on `main`

## What It Measures

Fresh runs use the scenario set:

- `cold`: empty remote cache, empty local Docker cache
- `warm1`

BoringCache lanes are split so product capabilities are visible instead of
mixed into one number: `BC OCI`, `BC Native`, `BC Native gzip`,
`BC Native + toolcache`, and `BC OCI + toolcache`.
Native lanes use the managed native BuildKit path. Tool-cache uses PostHog's
Turbo build steps while BoringCache still runs outside the Dockerfile; the
native tool-cache lane keeps the managed native builder instead of selecting a
separate Buildx builder. Mount-cache lanes remain script-level diagnostics, but
they are not part of the routine product benchmark matrix because recent
PostHog evidence showed high publish/export tail variance and sidecar release
coupling.
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

## Repo Layout

- [`scripts/prepare-source.sh`](scripts/prepare-source.sh)
- [`.github/workflows/posthog-benchmark.yml`](.github/workflows/posthog-benchmark.yml) runs GitHub Actions Cache plus explicit BoringCache OCI/native/tool-cache product lanes side by side.
- [`.github/workflows/rolling-dispatch.yml`](.github/workflows/rolling-dispatch.yml) runs the rolling lane after upstream sync.
- [`.github/workflows/sync.yml`](.github/workflows/sync.yml) keeps the pinned upstream source current.

## Output

Each workflow uploads:

- machine-readable benchmark JSON
- markdown summary

Those artifacts are intended to be ingested later by the central [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) publisher.
