#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from itertools import pairwise
from pathlib import Path
from typing import Any


def objects_in(bucket: str, prefix: str) -> list[dict]:
    objects = []
    continuation = None
    while True:
        command = ["aws", "s3api", "list-objects-v2", "--bucket", bucket, "--prefix", prefix, "--output", "json", "--no-paginate"]
        if continuation:
            command.extend(["--continuation-token", continuation])
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        page = json.loads(result.stdout)
        objects.extend(page.get("Contents", []))
        continuation = page.get("NextContinuationToken")
        if not continuation:
            return objects


def size_of(objects: list[dict]) -> int:
    return sum(item["Size"] for item in objects)


def metrics_shape(bucket: str, key: str) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "metrics.jsonl"
        subprocess.run(
            ["aws", "s3api", "get-object", "--bucket", bucket, "--key", key, str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        fields: set[str] = set()
        nested_fields: dict[str, set[str]] = {}
        kinds: set[str] = set()
        metric_shapes: dict[str, list[str]] = {}
        network_samples: list[dict] = []
        sampled = 0
        with path.open() as source:
            for line in source:
                if sampled == 500:
                    break
                record = json.loads(line)
                if not isinstance(record, dict):
                    continue
                sampled += 1
                fields.update(record)
                for name, value in record.items():
                    if isinstance(value, dict):
                        nested_fields.setdefault(name, set()).update(value)
                    elif name in ("name", "metric", "type") and isinstance(value, str):
                        kinds.add(value)
                for resource in record.get("resourceMetrics", []):
                    for scope in resource.get("scopeMetrics", []):
                        for metric in scope.get("metrics", []):
                            metric_shapes[metric["name"]] = sorted(metric)
                            if metric["name"] == "system.network.io" and not network_samples:
                                network_sum = metric.get("sum", {})
                                for point in network_sum.get("dataPoints", [])[:4]:
                                    network_samples.append(
                                        {
                                            "unit": metric.get("unit"),
                                            "temporality": network_sum.get("aggregationTemporality"),
                                            "monotonic": network_sum.get("isMonotonic"),
                                            "value": point.get("asInt", point.get("asDouble")),
                                            "time_unix_nano": point.get("timeUnixNano"),
                                            "attributes": {
                                                attribute["key"]: attribute.get("value")
                                                for attribute in point.get("attributes", [])
                                            },
                                        }
                                    )
        return {
            "sampled_records": sampled,
            "fields": sorted(fields),
            "nested_fields": {name: sorted(values) for name, values in nested_fields.items()},
            "kinds": sorted(kinds)[:50],
            "metric_shapes": metric_shapes,
            "network_samples": network_samples,
        }


def network_usage(bucket: str, key: str) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "metrics.jsonl"
        subprocess.run(
            ["aws", "s3api", "get-object", "--bucket", bucket, "--key", key, str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        samples: dict[tuple[str, str], dict[int, int]] = {}
        with path.open() as source:
            for line in source:
                record = json.loads(line)
                for resource in record.get("resourceMetrics", []):
                    for scope in resource.get("scopeMetrics", []):
                        for metric in scope.get("metrics", []):
                            if metric.get("name") != "system.network.io":
                                continue
                            for point in metric.get("sum", {}).get("dataPoints", []):
                                attributes = {
                                    attribute["key"]: attribute.get("value", {}).get("stringValue")
                                    for attribute in point.get("attributes", [])
                                }
                                device = attributes.get("device")
                                direction = attributes.get("direction")
                                if not device or direction not in ("receive", "transmit"):
                                    continue
                                value = point.get("asInt", point.get("asDouble"))
                                if value is None:
                                    continue
                                samples.setdefault((device, direction), {})[int(point["timeUnixNano"])] = int(value)

    devices: dict[str, dict[str, dict]] = {}
    for (device, direction), values in samples.items():
        ordered = sorted(values.items())
        if len(ordered) < 2:
            continue
        transferred = sum(max(0, current[1] - previous[1]) for previous, current in pairwise(ordered))
        peak_mbps = max(
            8 * max(0, current[1] - previous[1]) / ((current[0] - previous[0]) / 1e9) / 1e6
            for previous, current in pairwise(ordered)
            if current[0] > previous[0]
        )
        devices.setdefault(device, {})[direction] = {
            "bytes": transferred,
            "peak_sample_mbps": round(peak_mbps, 1),
            "first_time_unix_nano": ordered[0][0],
            "last_time_unix_nano": ordered[-1][0],
        }

    if not devices:
        return {"instance_id": key.split("/")[-2], "status": "no_network_samples"}
    primary = max(
        devices,
        key=lambda device: sum(values["bytes"] for values in devices[device].values()),
    )
    directions = devices[primary]
    start = min(values["first_time_unix_nano"] for values in directions.values())
    end = max(values["last_time_unix_nano"] for values in directions.values())
    seconds = (end - start) / 1e9
    received = directions.get("receive", {}).get("bytes", 0)
    transmitted = directions.get("transmit", {}).get("bytes", 0)
    return {
        "instance_id": key.split("/")[-2],
        "status": "available",
        "device": primary,
        "observed_seconds": round(seconds, 1),
        "receive_bytes": received,
        "transmit_bytes": transmitted,
        "average_total_mbps": round(8 * (received + transmitted) / seconds / 1e6, 1) if seconds else None,
        "peak_receive_sample_mbps": directions.get("receive", {}).get("peak_sample_mbps"),
        "peak_transmit_sample_mbps": directions.get("transmit", {}).get("peak_sample_mbps"),
    }


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("before", "after"):
        print("Usage: report-runs-on-s3.py before|after OUTPUT.json", file=sys.stderr)
        return 2

    run_id = os.environ.get("INSPECT_RUN_ID") or os.environ["GITHUB_RUN_ID"]
    bucket = os.environ.get("RUNS_ON_S3_BUCKET_CACHE", "")
    repo_prefix = os.environ.get("RUNS_ON_S3_CACHE_REPO_PREFIX", "")
    prefix = repo_prefix.rstrip("/") + "/" if repo_prefix else ""
    report: dict[str, Any] = {
        "snapshot": sys.argv[1],
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "run_id": run_id,
        "observation_run_id": os.environ["GITHUB_RUN_ID"],
        "bucket": bucket,
        "cache_prefix": prefix,
    }

    if not bucket or not prefix:
        report["cache_status"] = "unavailable"
        report["cache_reason"] = "RunsOn did not provide the cache bucket and repository prefix"
        report["metrics_status"] = "unavailable"
        Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        return 0

    try:
        cache_objects = objects_in(bucket, prefix)
    except (OSError, subprocess.CalledProcessError, ValueError):
        report["cache_status"] = "unavailable"
        report["cache_reason"] = "S3 ListObjectsV2 did not return a cache inventory"
    else:
        run_objects = [item for item in cache_objects if re.search(rf"r{re.escape(run_id)}-a\d+", item["Key"])]
        report.update(
            cache_status="available",
            cache_objects=len(cache_objects),
            cache_bytes=size_of(cache_objects),
            run_key_objects=len(run_objects),
            run_key_bytes=size_of(run_objects),
        )

    metrics_prefix = f"cache/metrics/v1/boringcache/benchmark-posthog/{run_id}/"
    try:
        metric_objects = objects_in(bucket, metrics_prefix)
    except (OSError, subprocess.CalledProcessError, ValueError):
        report["metrics_status"] = "unavailable"
    else:
        report.update(
            metrics_status="available",
            metrics_objects=len(metric_objects),
            metrics_bytes=size_of(metric_objects),
        )
        if metric_objects:
            try:
                report["metrics_shape"] = metrics_shape(bucket, metric_objects[0]["Key"])
            except (OSError, subprocess.CalledProcessError, ValueError):
                report["metrics_shape_status"] = "unavailable"
            network_jobs = []
            for item in metric_objects:
                try:
                    network_jobs.append(network_usage(bucket, item["Key"]))
                except (OSError, subprocess.CalledProcessError, ValueError):
                    network_jobs.append({"instance_id": item["Key"].split("/")[-2], "status": "unavailable"})
            report["network_jobs"] = network_jobs

    try:
        cache_tree = objects_in(bucket, "cache/")
    except (OSError, subprocess.CalledProcessError, ValueError):
        report["cache_tree_status"] = "unavailable"
    else:
        groups: dict[str, dict[str, int]] = {}
        for item in cache_tree:
            group = "/".join(item["Key"].split("/")[:4])
            totals = groups.setdefault(group, {"objects": 0, "bytes": 0})
            totals["objects"] += 1
            totals["bytes"] += item["Size"]
        report.update(
            cache_tree_status="available",
            cache_tree_objects=len(cache_tree),
            cache_tree_bytes=size_of(cache_tree),
            cache_tree_largest_prefixes=[
                {"prefix": group, **totals}
                for group, totals in sorted(groups.items(), key=lambda pair: pair[1]["bytes"], reverse=True)[:25]
            ],
        )

    try:
        bucket_objects = objects_in(bucket, "")
    except (OSError, subprocess.CalledProcessError, ValueError):
        report["bucket_status"] = "unavailable"
    else:
        groups: dict[str, dict[str, int]] = {}
        for item in bucket_objects:
            group = "/".join(item["Key"].split("/")[:4])
            totals = groups.setdefault(group, {"objects": 0, "bytes": 0})
            totals["objects"] += 1
            totals["bytes"] += item["Size"]
        report.update(
            bucket_status="available",
            bucket_objects=len(bucket_objects),
            bucket_bytes=size_of(bucket_objects),
            largest_prefixes=[
                {"prefix": group, **totals}
                for group, totals in sorted(groups.items(), key=lambda pair: pair[1]["bytes"], reverse=True)[:25]
            ],
        )

    Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
