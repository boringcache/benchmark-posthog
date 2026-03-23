# benchmark-posthog

Public PostHog benchmark runner for BoringCache vs GitHub Actions cache.

This repo exists separately from [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) so the benchmark can keep:

- one pinned upstream source commit
- isolated GitHub Actions cache usage
- one shared BoringCache workspace name: `boringcache/benchmarks`
- independent workflow history and nightly runs

## Source Model

- Upstream app source lives in the pinned `upstream/` submodule.
- `Dockerfile.benchmark` is benchmark-owned and committed in this repo.
- `scenarios/stale-low.patch` and `scenarios/stale-mid.patch` are the only source mutations applied during scenario runs.

The current pinned upstream source is:

- `PostHog/posthog@5ddbe2c9f8cf4877fa1739605aae1f05325ab4bb`

## What It Measures

Each backend runs the same scenario set:

- `cold`: empty remote cache, empty local Docker cache
- `warm1`
- `warm2`
- `stale-low`: one real source-only Python code change
- `stale-mid`: one scoped frontend `package.json` metadata change
- `layer-miss`: `--no-cache` Docker rebuild with the same pinned source tree

The story this benchmark is meant to show is:

- speed on cold, warm, stale, and layer-miss paths
- storage footprint in each backend
- whether BoringCache internal archives help when Docker layers rerun
- whether cache reuse stays understandable instead of turning into opaque blob growth

## Token Model

This repo uses split BoringCache tokens as the standard CI shape:

- `BORINGCACHE_RESTORE_TOKEN` for read-only restore and proxy access
- `BORINGCACHE_SAVE_TOKEN` for trusted write paths
- `BORINGCACHE_API_TOKEN` only where a single bearer variable is still required for compatibility

## Repo Layout

- [`Dockerfile.benchmark`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/Dockerfile.benchmark)
- [`scenarios/stale-low.patch`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/scenarios/stale-low.patch)
- [`scenarios/stale-mid.patch`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/scenarios/stale-mid.patch)
- [`scripts/prepare-source.sh`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/scripts/prepare-source.sh)
- [`.github/workflows/posthog-boringcache.yml`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/.github/workflows/posthog-boringcache.yml)
- [`.github/workflows/posthog-actions-cache.yml`](/Users/gaurav/boringcache/benchmark-repos/benchmark-posthog/.github/workflows/posthog-actions-cache.yml)

## Output

Each workflow uploads:

- machine-readable benchmark JSON
- markdown summary

Those artifacts are intended to be ingested later by the central [`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) publisher.
