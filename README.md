# benchmark-posthog

Public PostHog Docker benchmark runner for BoringCache versus GitHub Actions
Cache.

This repository stays separate from
[`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) so it can
keep a pinned upstream source commit, isolated cache usage, its own BoringCache
workspace, and independent workflow history.

## Product lanes

The benchmark has four lanes:

- **BoringCache** uses the CLI-managed BuildKit builder and the native
  `type=boringcache` cache backend. This is the product baseline for the
  tool-cache comparison.
- **BoringCache + toolcache** uses the same managed builder and cache backend,
  with the CLI's native Turbo tool-cache integration enabled.
- **BoringCache + mountcache** uses the same managed builder and cache backend,
  with CLI-owned cache-mount offload enabled for PostHog's real pnpm and uv
  cache mounts.
- **GHA** is the GitHub Actions Cache comparison lane.

All lanes build the pinned `upstream/Dockerfile` with `upstream/` as the build
context. The mount-cache lane exercises the Dockerfile's existing package
manager mounts without patching the upstream build. The optional
`scenarios/posthog-turbo-cache-mounts.patch` remains available for focused
experiments but is not part of the default rolling lane.

Stable fresh and rolling workflows install the verified BoringCache CLI
`v1.16.4` release. Canary dispatches must provide an exact immutable CLI tag.

The amd64 lane preserves the existing `posthog` cache scope and benchmark
history. A native arm64 BoringCache lane uses an `arm-` prefix so it cannot
disturb that scope.

## What it measures

Rolling runs build the newly pinned upstream commit against the stable branch
cache. They record build time, cache import/export time, cached BuildKit steps,
storage footprint, and cache observability. They do not run a synthetic second
warm build.

The intended product story is straightforward: compare normal PostHog commit
builds through BoringCache's managed builder with Turbo tool-cache on and off,
alongside the equivalent GHA cache build, while keeping cache reuse and storage
growth visible.

## Token model

- `BORINGCACHE_RESTORE_TOKEN` authorizes reads.
- `BORINGCACHE_SAVE_TOKEN` authorizes trusted writes.

## BoringBuild EC2 shape sweep

[`scripts/run-boringbuild-ec2-shape-sweep.sh`](scripts/run-boringbuild-ec2-shape-sweep.sh)
runs private cold-plus-rolling checks across EC2 runner sizes. It stages the
pinned PostHog source and local Linux CLI, uses the same managed BuildKit cache
path, and returns results under `boringbuild/ec2-shape-sweep/`.

```bash
scripts/run-boringbuild-ec2-shape-sweep.sh --shapes 4c
scripts/run-boringbuild-ec2-shape-sweep.sh --shapes 8c,16c --parallel
```

## Repository layout

- [`scripts/prepare-source.sh`](scripts/prepare-source.sh) resets and prepares
  the pinned upstream source.
- [`scripts/run-boringcache-buildkit-benchmark.sh`](scripts/run-boringcache-buildkit-benchmark.sh)
  runs the managed BoringCache lane.
- [`.github/workflows/posthog-benchmark.yml`](.github/workflows/posthog-benchmark.yml)
  runs the BoringCache, BoringCache tool-cache, BoringCache mount-cache, and
  GHA rolling lanes.
- [`.github/workflows/posthog-benchmark.yml`](.github/workflows/posthog-benchmark.yml)
  runs the rolling product lanes when an upstream sync updates `main`.
- [`.github/workflows/sync.yml`](.github/workflows/sync.yml) checks for newer
  pinned upstream source commits.

Each benchmark uploads machine-readable JSON and a Markdown summary for the
central benchmark publisher.
