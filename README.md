# benchmark-posthog

Public PostHog benchmark runner for BoringCache vs GitHub Actions cache.

This repo exists separately from [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) so the benchmark can keep:

- one pinned upstream source commit
- isolated GitHub Actions cache usage
- one shared BoringCache workspace name: `boringcache/benchmarks`
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

BoringCache uses the outer BuildKit registry/OCI cache path only. It does not call BoringCache inside Dockerfile `RUN` steps, and upstream Dockerfile cache mounts stay native to BuildKit.

Rolling runs record only the first build after upstream sync against the stable rolling cache tags. They do not run a separate `warm1` follow-up.

The story this benchmark is meant to show is:

- speed on cold and warm paths
- storage footprint in each backend
- whether the OCI registry cache behaves as a simple outer Docker cache backend
- whether cache reuse stays understandable instead of turning into opaque blob growth

## Token Model

This repo uses split BoringCache tokens as the standard CI shape:

- `BORINGCACHE_RESTORE_TOKEN` for read-only restore and proxy access
- `BORINGCACHE_SAVE_TOKEN` for trusted write paths
- `BORINGCACHE_API_TOKEN` only where a single bearer variable is still required for compatibility

## Repo Layout

- [`scripts/prepare-source.sh`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/scripts/prepare-source.sh)
- [`.github/workflows/posthog-boringcache.yml`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/.github/workflows/posthog-boringcache.yml)
- [`.github/workflows/posthog-actions-cache.yml`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/.github/workflows/posthog-actions-cache.yml)

## Output

Each workflow uploads:

- machine-readable benchmark JSON
- markdown summary

Those artifacts are intended to be ingested later by the central [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) publisher.
