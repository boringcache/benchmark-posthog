# BoringCache PostHog benchmark

This repository contains the BoringCache benchmark for PostHog.

Benchmark workflows are in [`.github/workflows/`](.github/workflows/), with configuration in [`.boringcache.toml`](.boringcache.toml).

## Evidence contracts

The `BoringCache + mountcache` lane deliberately re-executes PostHog's
`node-scripts-build` stage because that stage consumes the shared pnpm cache
mount. A successful lane must then prove mountcache hydration, reliable write
tracking, and a terminal publish outcome from the structured session summary.
A fully cached OCI graph is not accepted as mountcache coverage.

## Reading byte counters

Benchmark counters describe different layers and must not be compared as if
they were all stored or restored bytes:

- `prewarm.owned_body_bytes` is exporter work before upload coalescing. Shared
  bodies can be counted more than once, so it is not unique stored size.
- `upload_body_bytes` is data handed to the upload path. It is not restore or
  pull traffic.
- `remote_body_bytes` is physical body data read from remote storage during
  restore.
- Unique stored size comes from the canonical manifest's distinct descriptors
  and their sizes (or another explicitly defined availability-byte measure).
