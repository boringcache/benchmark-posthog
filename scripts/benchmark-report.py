#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

SCHEMA_VERSION = 1
PRODUCT_REF_FIELDS = (
    "schema_version",
    "cli_version",
    "action_ref",
    "action_sha",
    "web_revision",
    "api_url",
)

PROVIDER_LABELS = {
    "actions-cache": "GitHub Actions",
    "boringcache": "BoringCache",
    "boringcache-mountcache": "BoringCache mountcache",
    "boringcache-native": "BoringCache native",
    "boringcache-toolcache": "BoringCache toolcache",
    "boringcache-turbo": "BoringCache Turbo",
    "buildbuddy": "BuildBuddy",
    "buildbuddy-cache": "BuildBuddy",
    "ecr-cache": "Amazon ECR",
}

BASELINE_STRATEGY = "actions-cache"
CANDIDATE_STRATEGY = "boringcache"

PHASE_LABELS = {
    "cold": "Cold build",
    "warm": "Warm build",
    "commit": "Commit build",
}

LANE_PHASES = {
    "fresh": ("cold", "warm"),
    "rolling": ("commit",),
}

PHASE_RUN_FIELDS = {
    "cold": ("cold_seconds", "cold_build_seconds", "cold_restore_or_setup_seconds"),
    "warm": ("warm1_seconds", "warm1_build_seconds", "warm1_restore_or_setup_seconds"),
    "commit": ("rolling_first_build_seconds", None, None),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    phase = subparsers.add_parser("phase")
    phase.add_argument("--benchmark", required=True)
    phase.add_argument("--strategy", required=True)
    phase.add_argument("--lane", required=True, choices=sorted(LANE_PHASES))
    phase.add_argument("--phase", required=True, choices=sorted(PHASE_LABELS))
    phase.add_argument("--mode", required=True)
    phase.add_argument("--variant", default="")
    phase.add_argument("--build-seconds", type=int, required=True)
    phase.add_argument("--restore-or-setup-seconds", type=int, default=0)
    phase.add_argument("--workflow-seconds", type=int, default=0)
    phase.add_argument("--cache-hit", default="")
    phase.add_argument("--cache-import-ready", default="")
    phase.add_argument("--cache-import-refs", default="")
    phase.add_argument("--cache-tag", default="")
    phase.add_argument("--workspace", default="")
    phase.add_argument("--storage-key", default="")
    phase.add_argument("--source-repository", default="")
    phase.add_argument("--source-sha", default="")
    phase.add_argument("--evidence")
    phase.add_argument("--output-dir", default="benchmark-results")

    summarize = subparsers.add_parser("summarize")
    summarize.add_argument("--title", required=True)
    summarize.add_argument("--input-dir", required=True)
    summarize.add_argument("--output-dir", default="benchmark-results")

    return parser.parse_args()


def variant_slug(variant: str) -> str:
    return "".join(character if character.isalnum() else "-" for character in variant).strip("-").lower()


def optional_bool(value: str) -> bool | None:
    normalized = value.strip().lower()
    if normalized in ("true", "1", "yes"):
        return True
    if normalized in ("false", "0", "no"):
        return False
    return None


def load_evidence(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    evidence_path = Path(path)
    if not evidence_path.is_file():
        return None
    return json.loads(evidence_path.read_text())


def github_identity() -> dict[str, Any]:
    return {
        "repository": os.environ.get("GITHUB_REPOSITORY"),
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "job": os.environ.get("GITHUB_JOB"),
        "workflow": os.environ.get("GITHUB_WORKFLOW"),
        "ref_name": os.environ.get("GITHUB_REF_NAME"),
        "runner_os": os.environ.get("RUNNER_OS"),
        "runner_arch": os.environ.get("RUNNER_ARCH"),
        "runner_name": os.environ.get("RUNNER_NAME"),
        "runner_environment": os.environ.get("RUNNER_ENVIRONMENT"),
        "runner_image": os.environ.get("ImageOS"),
        "runner_image_version": os.environ.get("ImageVersion"),
    }


def run_uid() -> str | None:
    run_id = os.environ.get("GITHUB_RUN_ID")
    if not run_id:
        return None
    return f"gh-{run_id}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"


def evidence_action_versions(evidence: dict[str, Any] | None) -> dict[str, Any]:
    if not evidence:
        return {}
    phases = evidence.get("phases") or {}
    restore = phases.get("restore") or {}
    return {
        "resolved_mode": restore.get("mode"),
        "resolved_tags": restore.get("resolved_tags"),
        "trust_state": (restore.get("trust_state") or {}).get("policy"),
        "diagnostics_level": restore.get("diagnostics_level"),
    }


def evidence_product_refs(evidence: dict[str, Any] | None) -> dict[str, Any]:
    if not evidence:
        return {}
    product_refs = evidence.get("product_refs")
    if not isinstance(product_refs, dict):
        return {}
    return {
        key: product_refs[key]
        for key in PRODUCT_REF_FIELDS
        if product_refs.get(key) not in (None, "")
    }


def string_values(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []

    return [item.strip() for item in value if isinstance(item, str) and item.strip()]


def integer_value(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float):
        return int(value) if value >= 0 and value.is_integer() else None
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def cache_identity(evidence: dict[str, Any] | None) -> dict[str, Any]:
    if not evidence:
        return {}

    phases = evidence.get("phases")
    if not isinstance(phases, dict):
        return {}
    restore = phases.get("restore")
    if not isinstance(restore, dict):
        return {}

    workspace = restore.get("workspace")
    cache_tag = restore.get("cache_tag")
    tags = list(dict.fromkeys(string_values(restore.get("resolved_tags"))))
    if not tags and isinstance(cache_tag, str) and cache_tag.strip():
        tags = [cache_tag.strip()]

    return {
        "workspace": workspace.strip() if isinstance(workspace, str) else None,
        "cache_tag": cache_tag.strip() if isinstance(cache_tag, str) else None,
        "tags": tags,
    }


def phase_cache_identity(args: argparse.Namespace, evidence: dict[str, Any] | None) -> dict[str, Any]:
    identity = cache_identity(evidence)
    workspace = args.workspace.strip() or identity.get("workspace")
    cache_tag = args.cache_tag.strip() or identity.get("cache_tag")
    tags = identity.get("tags") or [tag.strip() for tag in args.cache_tag.split(",") if tag.strip()]

    return {
        "workspace": workspace or None,
        "cache_tag": cache_tag or None,
        "tags": tags,
    }


def docker_cache_plan(evidence: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(evidence, dict):
        return None
    restore = (evidence.get("phases") or {}).get("restore") or {}
    mode_evidence = restore.get("mode_evidence") or {}
    plan = mode_evidence.get("buildkit_cache") or {}
    if not isinstance(plan, dict) or not plan:
        return None
    return {
        "import_tags": string_values(plan.get("cache_from_tags")),
        "planned_import_refs": len(string_values(plan.get("cache_from_refs"))),
        "export_tag": plan.get("cache_to_tag"),
    }


def boringcache_storage(identity: dict[str, Any]) -> dict[str, Any] | None:
    workspace = identity.get("workspace")
    tags = identity.get("tags")
    if not isinstance(workspace, str) or not workspace or not isinstance(tags, list) or not tags:
        return None

    command = [
        "boringcache",
        "check",
        workspace,
        ",".join(tags),
        "--no-git",
        "--no-platform",
        "--exact",
        "--json",
    ]
    try:
        result = subprocess.run(command, capture_output=True, check=False, text=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    results = payload.get("results") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        return None

    entries: dict[str, int] = {}
    for item in results:
        if not isinstance(item, dict) or item.get("status") != "hit":
            continue

        entry_key = next(
            (
                item.get(key)
                for key in (
                    "cache_entry_id",
                    "cacheEntryId",
                    "manifest_root_digest",
                    "manifestRootDigest",
                    "requested_tag",
                    "requestedTag",
                    "tag",
                )
                if isinstance(item.get(key), str) and item.get(key)
            ),
            None,
        )
        if entry_key is None:
            continue

        size = None
        for field in ("kv_total_size", "kvTotalSize", "compressed_size", "compressedSize", "size_bytes", "sizeBytes", "size"):
            size = integer_value(item.get(field))
            if size is not None:
                break
        if size is None:
            continue
        entries[entry_key] = max(entries.get(entry_key, 0), size)

    total_bytes = sum(entries.values())
    if total_bytes <= 0:
        return None

    return {
        "bytes": total_bytes,
        "source": "boringcache-check",
        "breakdown": {
            "workspace": workspace,
            "tags": tags,
            "total_bytes": total_bytes,
        },
    }


def github_actions_cache_storage(cache_key: str) -> dict[str, Any] | None:
    repository = os.environ.get("GITHUB_REPOSITORY", "").strip()
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not repository or not token or not cache_key:
        return None

    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    next_url = f"{api_url}/repos/{repository}/actions/caches?{urlencode({'per_page': 100, 'key': cache_key})}"
    total_bytes = 0

    while next_url:
        request = Request(next_url, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        try:
            with urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
                link_header = response.headers.get("Link", "")
        except (HTTPError, URLError, OSError, json.JSONDecodeError):
            return None

        entries = payload.get("actions_caches") if isinstance(payload, dict) else None
        if not isinstance(entries, list):
            return None
        for entry in entries:
            if isinstance(entry, dict) and entry.get("key") == cache_key:
                total_bytes += integer_value(entry.get("size_in_bytes")) or 0

        next_url = None
        for link in link_header.split(","):
            if 'rel="next"' in link:
                next_url = link.split(";", 1)[0].strip().strip("<>")
                break

    if total_bytes <= 0:
        return None
    return {
        "bytes": total_bytes,
        "source": "github-actions-cache-api",
        "breakdown": {
            "key": cache_key,
            "total_bytes": total_bytes,
        },
    }


def storage_sample(args: argparse.Namespace, identity: dict[str, Any]) -> dict[str, Any] | None:
    if args.strategy == "boringcache":
        return boringcache_storage(identity)
    if args.strategy == "actions-cache":
        return github_actions_cache_storage(args.storage_key)
    return None


def write_phase(args: argparse.Namespace) -> int:
    if not args.source_repository or not args.source_sha:
        raise SystemExit("benchmark phase requires the exact source repository and SHA")
    cache_hit = optional_bool(args.cache_hit)
    import_ready = optional_bool(args.cache_import_ready)
    evidence = load_evidence(args.evidence)
    identity = phase_cache_identity(args, evidence)
    measured_storage = storage_sample(args, identity)
    total_seconds = args.restore_or_setup_seconds + args.build_seconds

    payload = {
        "schema_version": SCHEMA_VERSION,
        "benchmark": args.benchmark,
        "strategy": args.strategy,
        "lane": args.lane,
        "phase": args.phase,
        "variant": args.variant or None,
        "mode": args.mode,
        "adapter": args.mode,
        "timing": {
            "restore_or_setup_seconds": args.restore_or_setup_seconds,
            "build_seconds": args.build_seconds,
            "total_seconds": total_seconds,
            "workflow_seconds": args.workflow_seconds or None,
        },
        "cache": {
            "hit": cache_hit,
            "import_ready": import_ready,
            "import_refs": len([ref for ref in args.cache_import_refs.splitlines() if ref.strip()]),
            "docker_plan": docker_cache_plan(evidence) if args.mode in ("docker", "buildkit") else None,
            "tag": args.cache_tag or identity.get("cache_tag") or None,
            "workspace": args.workspace or identity.get("workspace") or None,
            "storage_bytes": measured_storage["bytes"] if measured_storage else None,
            "storage_source": measured_storage["source"] if measured_storage else None,
            "storage_breakdown": measured_storage.get("breakdown") if measured_storage else None,
        },
        "source": {
            "repository": args.source_repository or None,
            "sha": args.source_sha or None,
        },
        "product_refs": evidence_product_refs(evidence),
        "action": evidence_action_versions(evidence),
        "github": github_identity(),
        "run_uid": run_uid(),
    }

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    slug = f"-{variant_slug(args.variant)}" if args.variant else ""
    output_path = output_dir / f"{args.benchmark}-{args.strategy}{slug}-{args.lane}-{args.phase}.json"
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(output_path)
    return 0


def load_phases(input_dir: Path) -> list[dict[str, Any]]:
    payloads = []
    for path in sorted(input_dir.rglob("*.json")):
        payload = json.loads(path.read_text())
        if payload.get("schema_version") == SCHEMA_VERSION and payload.get("phase"):
            payloads.append(payload)
    return payloads


def merge_lane(benchmark: str, strategy: str, lane: str, phases: list[dict[str, Any]]) -> dict[str, Any]:
    by_phase = {payload["phase"]: payload for payload in phases}
    runs: dict[str, Any] = {}
    for phase_name, fields in PHASE_RUN_FIELDS.items():
        payload = by_phase.get(phase_name)
        if payload is None:
            continue
        timing = payload["timing"]
        total_field, build_field, setup_field = fields
        runs[total_field] = timing["total_seconds"]
        if timing.get("workflow_seconds"):
            runs[f"{phase_name}_workflow_seconds"] = timing["workflow_seconds"]
        if build_field:
            runs[build_field] = timing["build_seconds"]
        if setup_field:
            runs[setup_field] = timing["restore_or_setup_seconds"]

    warm = by_phase.get("warm")
    reference = by_phase.get("commit") or by_phase.get("warm") or by_phase.get("cold")
    if reference is None:
        raise SystemExit(f"no usable phase evidence for {benchmark} {strategy} {lane}")

    phase_product_refs = [
        payload.get("product_refs")
        for payload in phases
        if isinstance(payload.get("product_refs"), dict) and payload.get("product_refs")
    ]
    product_refs = reference.get("product_refs") or (phase_product_refs[0] if phase_product_refs else {})
    product_refs_consistent = None
    if phase_product_refs:
        signatures = {json.dumps(refs, sort_keys=True) for refs in phase_product_refs}
        product_refs_consistent = len(phase_product_refs) == len(phases) and len(signatures) == 1

    observations = {
        payload["phase"]: {
            "cache_hit": payload["cache"]["hit"],
            "cache_import_ready": payload["cache"]["import_ready"],
            "cache_import_refs": payload["cache"].get("import_refs"),
        }
        for payload in phases
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "benchmark": benchmark,
        "strategy": strategy,
        "lane": lane,
        "mode": reference["mode"],
        "adapter": reference["adapter"],
        "runs": runs,
        "speed": {"warm_average_seconds": warm["timing"]["total_seconds"] if warm else None},
        "cache": reference["cache"],
        "source": reference["source"],
        "product_refs": product_refs,
        "product_refs_consistent": product_refs_consistent,
        "phase_observations": observations,
        "workspace": reference["cache"]["workspace"],
        "cache_tag": reference["cache"]["tag"],
        "run_uid": reference["run_uid"],
        "github": reference["github"],
    }


def format_seconds(value: Any) -> str:
    if value is None:
        return "n/a"
    seconds = int(value)
    if seconds < 60:
        return f"{seconds}s"
    return f"{seconds // 60}m{seconds % 60:02d}s"


def format_delta(baseline: Any, candidate: Any) -> str:
    if baseline is None or candidate is None or baseline == 0:
        return "n/a"
    change = (baseline - candidate) / baseline * 100
    if change >= 0:
        return f"{change:.0f}% faster"
    return f"{abs(change):.0f}% slower"


IMPORT_MODES = ("docker", "buildkit")


def imported(mode: str | None, observed: dict[str, Any]) -> bool:
    if observed.get("cache_import_ready") is False:
        return False
    if mode in IMPORT_MODES:
        if observed.get("cache_import_ready") is None:
            return True
        return bool(observed.get("cache_import_refs"))
    return observed.get("cache_hit") is not False


def cache_state(payload: dict[str, Any]) -> str:
    cache = payload["cache"]
    if cache.get("import_ready") is False:
        return "import not ready"
    if payload.get("mode") in IMPORT_MODES:
        if cache.get("import_ready") is None:
            plan = cache.get("docker_plan") or {}
            count = plan.get("planned_import_refs")
            return f"reuse not measured ({count} refs planned)" if count is not None else "not reported"
        refs = cache.get("import_refs")
        if refs:
            return f"imported {refs} ref{'s' if refs > 1 else ''}"
        if refs == 0:
            return "nothing to import"
        return "not reported"
    if cache["hit"] is True:
        return "hit"
    if cache["hit"] is False:
        return "miss"
    return "not reported"


def render_markdown(title: str, lanes: dict[tuple[str, str, str, str], dict[str, Any]], phases: list[dict[str, Any]]) -> str:
    lines = [f"## {title}", ""]
    benchmarks = sorted({payload["benchmark"] for payload in phases})

    for benchmark in benchmarks:
        if len(benchmarks) > 1:
            lines.append(f"### {benchmark}")
            lines.append("")
        lines.extend(render_benchmark(benchmark, lanes, phases, depth=4 if len(benchmarks) > 1 else 3))

    source = next((payload["source"] for payload in phases if payload["source"].get("sha")), None)
    if source and source.get("repository"):
        lines.append(f"Source: `{source['repository']}@{source['sha'][:7]}`")
        lines.append("")

    return "\n".join(lines)


def provider_label(strategy: str, variant: str) -> str:
    label = PROVIDER_LABELS.get(strategy, strategy)
    return f"{label} ({variant})" if variant else label


def render_benchmark(
    benchmark: str,
    all_lanes: dict[tuple[str, str, str, str], dict[str, Any]],
    all_phases: list[dict[str, Any]],
    depth: int,
) -> list[str]:
    lines: list[str] = []
    heading = "#" * depth
    phases = [payload for payload in all_phases if payload["benchmark"] == benchmark]
    lanes = {
        (strategy, variant, lane): value
        for (item, strategy, variant, lane), value in all_lanes.items()
        if item == benchmark
    }
    lane_names = sorted({lane for _, _, lane in lanes})

    for lane in lane_names:
        baseline = lanes.get((BASELINE_STRATEGY, "", lane))
        candidate = lanes.get((CANDIDATE_STRATEGY, "", lane))
        reference = candidate or baseline
        if reference is None:
            continue

        lane_providers = sorted(
            {(strategy, variant) for strategy, variant, item in lanes if item == lane},
            key=lambda entry: (entry[0] != CANDIDATE_STRATEGY, entry[0] != BASELINE_STRATEGY, bool(entry[1]), entry),
        )

        lines.append(f"{heading} {lane.capitalize()} lane")
        lines.append("")
        lines.append("| Provider | Phase | Cache setup | Build | Cache + build | Workflow | Cache |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: | --- |")

        for phase_name in LANE_PHASES[lane]:
            for strategy, variant in lane_providers:
                payload = next(
                    (
                        item
                        for item in phases
                        if item["strategy"] == strategy
                        and (item.get("variant") or "") == variant
                        and item["lane"] == lane
                        and item["phase"] == phase_name
                    ),
                    None,
                )
                if payload is None:
                    continue
                timing = payload["timing"]
                lines.append(
                    f"| {provider_label(strategy, variant)} | {PHASE_LABELS[phase_name]} "
                    f"| {format_seconds(timing['restore_or_setup_seconds'])} "
                    f"| {format_seconds(timing['build_seconds'])} "
                    f"| {format_seconds(timing['total_seconds'])} "
                    f"| {format_seconds(timing.get('workflow_seconds'))} "
                    f"| {cache_state(payload)} |"
                )

        lines.append("")

        if baseline and candidate:
            for phase_name in LANE_PHASES[lane]:
                total_field = PHASE_RUN_FIELDS[phase_name][0]
                before = baseline["runs"].get(total_field)
                after = candidate["runs"].get(total_field)
                if before is None or after is None:
                    continue
                observed = (candidate.get("phase_observations") or {}).get(phase_name, {})
                if phase_name != "cold" and not imported(candidate.get("mode"), observed):
                    lines.append(
                        f"- {PHASE_LABELS[phase_name]}: {PROVIDER_LABELS[CANDIDATE_STRATEGY]} found no cache to import, "
                        "so these timings are not like-for-like."
                    )
                    continue
                lines.append(
                    f"- {PHASE_LABELS[phase_name]}: {PROVIDER_LABELS[CANDIDATE_STRATEGY]} {format_seconds(after)} "
                    f"vs {PROVIDER_LABELS[BASELINE_STRATEGY]} {format_seconds(before)} — **{format_delta(before, after)}**"
                )
            lines.append("")

    return lines


def summarize(args: argparse.Namespace) -> int:
    phases = load_phases(Path(args.input_dir))
    if not phases:
        raise SystemExit(f"no benchmark phase evidence found under {args.input_dir}")

    source_shas: dict[tuple[str, str], set[str]] = {}
    for phase in phases:
        source = phase.get("source") or {}
        sha = source.get("sha")
        if not sha:
            raise SystemExit(f"missing source SHA for {phase['benchmark']} {phase['strategy']}")
        source_shas.setdefault((phase["benchmark"], phase["lane"]), set()).add(sha)
    for (benchmark, lane), shas in source_shas.items():
        if len(shas) != 1:
            raise SystemExit(f"mixed source SHAs for {benchmark} {lane}: {', '.join(sorted(shas))}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    grouped: dict[tuple[str, str, str, str], list[dict[str, Any]]] = {}
    for payload in phases:
        key = (payload["benchmark"], payload["strategy"], payload.get("variant") or "", payload["lane"])
        grouped.setdefault(key, []).append(payload)

    lanes = {}
    for (benchmark, strategy, variant, lane), lane_phases in grouped.items():
        merged = merge_lane(benchmark, strategy, lane, lane_phases)
        merged["variant"] = variant or None
        lanes[(benchmark, strategy, variant, lane)] = merged
        slug = f"-{variant_slug(variant)}" if variant else ""
        output_path = output_dir / f"{benchmark}-{strategy}{slug}-{lane}.json"
        output_path.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
        print(output_path)

    markdown = render_markdown(args.title, lanes, phases)
    (output_dir / "comparison.md").write_text(markdown)

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(markdown)

    return 0


def main() -> int:
    args = parse_args()
    if args.command == "phase":
        return write_phase(args)
    return summarize(args)


if __name__ == "__main__":
    raise SystemExit(main())
