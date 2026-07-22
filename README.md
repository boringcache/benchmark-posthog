# benchmark-posthog

Public PostHog Docker benchmark runner for BoringCache versus GitHub Actions
Cache.

This repository stays separate from
[`boringcache/benchmarks`](https://github.com/boringcache/benchmarks) so it can
keep a pinned upstream source commit, isolated cache usage, its own BoringCache
workspace, and independent workflow history.

## Product lanes

The benchmark has two lanes:

- **BoringCache** uses the CLI-managed BuildKit builder and the native
  `type=boringcache` cache backend. This is the sole BoringCache Docker cache
  product lane.
- **GHA** is the GitHub Actions Cache comparison lane.

Both lanes build the pinned `upstream/Dockerfile` with `upstream/` as the build
context. The BoringCache lane can also exercise managed BuildKit cache-mount
offload and Turbo tool-cache injection. The optional
`scenarios/posthog-turbo-cache-mounts.patch` remains available for focused
experiments but is not part of the default rolling lane.

The amd64 lane preserves the existing `posthog` cache scope and benchmark
history. A native arm64 BoringCache lane uses an `arm-` prefix so it cannot
disturb that scope.

## What it measures

Rolling runs build the newly pinned upstream commit against the stable branch
cache. They record build time, cache import/export time, cached BuildKit steps,
storage footprint, and cache observability. They do not run a synthetic second
warm build.

The intended product story is straightforward: compare normal PostHog commit
builds through BoringCache's managed builder with the equivalent GHA cache
build, while keeping cache reuse and storage growth visible.

## Token model

- `BORINGCACHE_RESTORE_TOKEN` authorizes reads.
- `BORINGCACHE_SAVE_TOKEN` authorizes trusted writes.
- `BORINGCACHE_API_TOKEN` is retained only where a single bearer environment
  variable is still required by a shared helper.

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
  runs the BoringCache and GHA rolling lanes.
- [`.github/workflows/rolling-dispatch.yml`](.github/workflows/rolling-dispatch.yml)
  dispatches the rolling benchmark after upstream sync.
- [`.github/workflows/sync.yml`](.github/workflows/sync.yml) checks for newer
  pinned upstream source commits.

Each benchmark uploads machine-readable JSON and a Markdown summary for the
central benchmark publisher.
