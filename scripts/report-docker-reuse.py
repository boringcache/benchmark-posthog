#!/usr/bin/env python3
"""Count observed BuildKit cache imports and cached vertices in rolling jobs."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

JOB_NAME = re.compile(r"rolling_step(\d\d) \((runs-on-cache|boringcache)\)")
CACHED_VERTEX = re.compile(r"#(\d+) CACHED\b")
IMPORTED_MANIFEST = re.compile(r"#\d+ importing cache manifest from (gha|boringcache):([^\s]+)")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def github_api(path: str) -> str:
    result = subprocess.run(
        ["gh", "api", "--allow-escape-sequences", path],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: report-docker-reuse.py RUN_ID OUTPUT_DIR")
    repository = os.environ["GITHUB_REPOSITORY"]
    run_id = sys.argv[1]
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)

    jobs_payload = json.loads(github_api(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100"))
    jobs = jobs_payload.get("jobs", [])
    observations: list[dict[str, Any]] = []
    for job in jobs:
        match = JOB_NAME.search(job["name"])
        if not match:
            continue
        log = ANSI.sub("", github_api(f"repos/{repository}/actions/jobs/{job['id']}/logs"))
        manifests = sorted(set(IMPORTED_MANIFEST.findall(log)))
        vertices = set(CACHED_VERTEX.findall(log))
        observations.append({
            "step": f"step{match.group(1)}",
            "provider": match.group(2),
            "job_id": job["id"],
            "job_url": job["html_url"],
            "conclusion": job["conclusion"],
            "imported_cache_manifests": len(manifests),
            "cache_manifest_backends": sorted({backend for backend, _ in manifests}),
            "cached_buildkit_vertices": len(vertices),
        })
    observations.sort(key=lambda item: (item["step"], item["provider"]))
    if len(observations) != 12:
        raise SystemExit(f"Expected 12 rolling build jobs, found {len(observations)}")

    (output_dir / "docker-reuse.json").write_text(json.dumps(observations, indent=2) + "\n")
    lines = [
        "### BuildKit reuse observed in job logs",
        "",
        "| Step | Provider | Imported cache manifests | Cached BuildKit vertices |",
        "| --- | --- | ---: | ---: |",
    ]
    for item in observations:
        lines.append(
            f"| {item['step']} | {item['provider']} | {item['imported_cache_manifests']} | {item['cached_buildkit_vertices']} |"
        )
    lines.extend(["", "Cached vertices are BuildKit log observations, not a compiler-cache hit rate or bytes transferred.", ""])
    section = "\n".join(lines)
    with (output_dir / "comparison.md").open("a") as report:
        report.write("\n" + section)
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a") as summary:
            summary.write("\n" + section)
    print(output_dir / "docker-reuse.json")


if __name__ == "__main__":
    main()
