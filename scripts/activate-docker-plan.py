#!/usr/bin/env python3
"""Resolve a PostHog benchmark case into the committed Docker plan."""

import argparse
import json
import tomllib
from pathlib import Path, PurePosixPath

PLAN = Path(__file__).resolve().parents[1] / ".boringcache.toml"


def quoted(value: str) -> str:
    return json.dumps(value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dockerfile", required=True)
    parser.add_argument("--platform", choices=("linux/amd64", "linux/arm64"), required=True)
    parser.add_argument("--tool-cache", choices=("true", "false"), required=True)
    parser.add_argument("--mount-cache", choices=("true", "false"), required=True)
    parser.add_argument("--no-cache", choices=("true", "false"), required=True)
    parser.add_argument("--sourcemap-secret", choices=("true", "false"), required=True)
    parser.add_argument("--push", choices=("true", "false"), required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--plan", type=Path, default=PLAN)
    args = parser.parse_args()

    dockerfile = PurePosixPath(args.dockerfile)
    if dockerfile.is_absolute() or ".." in dockerfile.parts:
        raise SystemExit("Dockerfile must stay inside the benchmark checkout")
    expected_dockerfile = (
        PurePosixPath(".benchmark/PostHog.Dockerfile")
        if args.tool_cache == "true"
        else PurePosixPath("upstream/Dockerfile")
    )
    if dockerfile != expected_dockerfile:
        raise SystemExit(f"expected Dockerfile {expected_dockerfile} for this cache profile")

    current = tomllib.loads(args.plan.read_text())
    workspace = current["workspace"]
    docker_tag = current["adapters"]["docker"]["tag"]
    turbo_tag = current["adapters"]["turbo"]["tag"]
    output_image = args.image if args.push == "true" else "posthog-benchmark:local"
    command = [
        "docker", "buildx", "build",
        "--file", str(dockerfile),
        "--platform", args.platform,
        "--provenance", "false",
    ]
    if args.sourcemap_secret == "true":
        command.extend([
            "--secret",
            "id=posthog_upload_sourcemaps_cli_api_key,env=POSTHOG_SOURCEMAP_API_KEY",
        ])
    if args.no_cache == "true":
        command.append("--no-cache")
    command.extend(["--tag", output_image])
    if args.push == "true":
        command.append("--push")
    command.append("upstream")

    rendered = (
        f"workspace = {quoted(workspace)}\n\n"
        "[adapters.docker]\n"
        f"tag = {quoted(docker_tag)}\n"
        'metadata-hints = ["benchmark=posthog", "upstream-job=build-image-amd64"]\n'
    )
    if args.tool_cache == "true":
        rendered += 'tool-cache = ["turbo"]\n'
    if args.mount_cache == "true":
        rendered += "mount-cache = true\n"
    rendered += (
        "command = [\n"
        + "".join(f"  {quoted(value)},\n" for value in command)
        + "]\n\n"
        + "[adapters.turbo]\n"
        + f"tag = {quoted(turbo_tag)}\n"
    )
    tomllib.loads(rendered)
    args.plan.write_text(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
