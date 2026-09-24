# BoringCache PostHog benchmark

This repository contains the BoringCache benchmark for PostHog.

Benchmark workflows are in [`.github/workflows/`](.github/workflows/), with configuration in [`.boringcache.toml`](.boringcache.toml).

## RunsOn cache comparison

The [RunsOn cache comparison](.github/workflows/posthog-runs-on-cache.yml) runs PostHog's Docker build with RunsOn Magic Cache and BoringCache in parallel. Each provider uses a fresh 16 vCPU, 64 GiB Flex runner in `us-east-1` for three builds: cold, same-revision warm, and changed-source warm. The default source revisions are adjacent; the second changes `products/tasks`, which the Dockerfile copies into the image. Both providers push and verify an image and publish the updated cache after each build.

Select `s3` to compare the providers with their cache data in same-region S3. Select `managed` to compare RunsOn Magic Cache with BoringCache managed storage. The report keeps setup, build, and workflow durations separate. Inspect the RunsOn job logs for Magic Cache startup or fallback warnings before treating a run as a Magic Cache result.

The [connection workflow](.github/workflows/connect-runs-on-s3.yml) requests the GitHub Actions OIDC connection for the S3 workspace. Run it once and approve that repository binding before starting an S3 comparison.
