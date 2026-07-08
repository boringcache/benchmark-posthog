# BuildKit Mountcache Planner Experiment

This note is the cheap test path for turning BuildKit cache demand into a planner signal.

## Current Benchmark Shape

PostHog's plain Docker cache lanes use the pinned upstream `upstream/Dockerfile`
directly. The BuildKit backend lane uses
`scenarios/posthog-toolcache/Dockerfile` so Turbo can talk to BoringCache's
remote-cache protocol inside the Docker build.

The upstream Dockerfile already uses BuildKit cache mounts for dependency stores:

- `id=pnpm,target=/tmp/pnpm-store-v24` in the frontend dependency install step.
- `id=pnpm,target=/tmp/pnpm-store-v24` in the plugin-transpiler dependency install step.
- `id=uv-libxmlsec1.2.37-2,target=/root/.cache/uv` in the Python dependency install step.

Turbo itself is not mounted as a first-class cache path in the upstream Dockerfile.
The frontend Turbo build is a plain `RUN bin/turbo --filter=@posthog/frontend build`.
The plugin-transpiler Turbo build shares the same `RUN` as the second pnpm install, so it can benefit from the pnpm store mount but not from a separate Turbo task-cache mount.

As of 2026-07-08, the rolling `BC BuildKit Backend` lane intentionally leaves
the benchmark-only Turbo cache-mount patch and mountcache offloader disabled.
Instead it uses `scenarios/posthog-toolcache/Dockerfile`, which injects the
stable `boringcache-tool-cache-env` secret around Turbo so the Docker build can
use BoringCache's Turbo remote-cache protocol. The raw `.turbo/cache` directory
accumulates task-output artifacts, and storing it as one BuildKit cache-mount
archive made later restores pay for old artifacts that the current build might
not need. Keep Turbo task-output caching on the protocol-aware remote-cache path
until mountcache has size guards and per-artifact demand behavior.

## Spike Reference

GitHub Actions run:
<https://github.com/boringcache/benchmark-posthog/actions/runs/28809459941>

The linked slow run checked out upstream commit:

`a0598d99ea23845630262be50f940fd49ec3f5fb`

That upstream commit is `feat: make the chatbox stay fixed (#68712)` and changed only:

`products/conversations/frontend/scenes/ticket/SupportTicketScene.tsx`

It did not change `uv.lock`, `pyproject.toml`, `pnpm-lock.yaml`, `package.json`, or `Dockerfile`.
So this specific spike should not be explained as Python lockfile invalidation.

## BC BuildKit vs ECR In That Run

Both lanes reported 27 cached BuildKit steps.

| Lane | Build seconds | Total seconds | Import | Export / prepare | Cache size |
| --- | ---: | ---: | ---: | ---: | ---: |
| BC BuildKit Backend | 745 | 756 | 0.2s | 60.2s export, including 59.1s prepare and 1.1s send | 6.52 GB |
| ECR | 827 | 838 | 0.4s | 452.7s export | 7.35 GB |

BC BuildKit also reported:

- 165 prewarm queue events.
- 23 body-prepared events.
- 43 committed bodies.
- 87 uploaded prewarm items.
- 47 remote body fetches.
- 1.00 GB remote body bytes.
- 16.6s remote body fetch duration.

The useful read is that cache manifest import was not the slow part.
ECR was slower overall, mostly due to registry cache export.
The unanswered question is which BuildKit vertices executed, which imported cache records were matched, and which cache-mount bodies were demanded.

## Native Planner Loop

The product experiment should stay on the final BuildKit path:

1. Import the previous BuildKit cache manifest through `type=boringcache`.
2. Let BuildKit solve the current LLB graph.
3. Trace native cache lookups and result walks before expensive execution.
4. Convert those trace events into proxy prefetch decisions.
5. Compare later vertex execution against the earlier cache-demand trace.

The first useful trace event shape is JSONL:

```json
{
  "event": "buildkit_cache_demand",
  "vertex": "RUN --mount=type=cache,id=uv-libxmlsec1.2.37-2 ...",
  "cache_key": "...",
  "lookup": "hit",
  "result_ids": ["..."],
  "descriptors": [{"digest": "sha256:...", "size": 123}],
  "mounts": [{"id": "uv-libxmlsec1.2.37-2", "target": "/root/.cache/uv"}]
}
```

The corresponding execution event should include vertex name, start time, end time, cached/executed status, and whether it waited for a remote body or mountcache body.

## Local Mac Experiment

Use the same upstream commit and compare one BuildKit-backend plus Turbo
toolcache run against the prior manifest:

```bash
cd /Users/gaurav/boringcache/benchmarks-repos/benchmark-posthog
git -C upstream fetch --depth 2 origin a0598d99ea23845630262be50f940fd49ec3f5fb
git -C upstream checkout --detach a0598d99ea23845630262be50f940fd49ec3f5fb
./scripts/prepare-source.sh base

POSTHOG_BORINGBUILD_LANE=buildkit \
POSTHOG_BORINGBUILD_SCOPE_SUFFIX=local-buildkit-toolcache \
BORINGCACHE_OBSERVABILITY_JSONL_PATH=/tmp/posthog-buildkit-toolcache.jsonl \
./scripts/run-boringbuild-docker-lane.sh full
```

Until BuildKit emits vertex-demand events, this only proves the high-level behavior.
The next backend change is to add env-gated native BuildKit trace events around cache record lookup, result walking, remote descriptor selection, cache loads, and vertex execution timing.
