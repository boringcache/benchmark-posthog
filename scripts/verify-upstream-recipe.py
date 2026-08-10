#!/usr/bin/env python3
"""Verify PostHog's primary multi-platform image benchmark plan."""

import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def require(value: bool, message: str) -> None:
    if not value:
        raise RuntimeError(message)

def main() -> int:
    try:
        command = tomllib.loads((ROOT / ".boringcache.toml").read_text())["adapters"]["docker"]["command"]
        require(command[:4] == ["bash", "-euo", "pipefail", "-c"], "Docker plan must be argv-safe")
        for fragment in ("upstream/Dockerfile", "linux/arm64,linux/amd64", "COMMIT_HASH=${source_sha}"):
            require(fragment in command[4], f"Docker plan changed: {fragment}")
        upstream = (ROOT / "upstream/.github/workflows/container-images-cd.yml").read_text()
        for fragment in ("context: . # match the CI build's context", "push: true", "platforms: linux/arm64,linux/amd64", "COMMIT_HASH=${{ github.sha }}"):
            require(fragment in upstream, f"upstream image job changed: {fragment}")
        action = (ROOT / ".github/actions/posthog-docker-benchmark/action.yml").read_text()
        require(action.count("COMMIT_HASH=${{ steps.scope.outputs.source_sha }}") == 3, "provider commit arg drifted")
        rolling = (ROOT / ".github/workflows/posthog-benchmark.yml").read_text()
        require(rolling.count("platform: linux/arm64,linux/amd64") == 2, "primary rolling providers are not multi-platform")
        require("boringcache-arm64:" not in rolling, "split topology no longer matches upstream")
    except (KeyError, OSError, RuntimeError, tomllib.TOMLDecodeError) as error:
        print(f"PostHog recipe mismatch: {error}", file=sys.stderr)
        return 1
    print("Verified PostHog primary multi-platform image plan.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
