#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

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
    phase.add_argument("--cache-tag", default="")
    phase.add_argument("--workspace", default="")
    phase.add_argument("--source-repository", default="")
    phase.add_argument("--source-sha", default="")
    phase.add_argument("--evidence")
    phase.add_argument("--output-dir", default="benchmark-results")

    summarize = subparsers.add_parser("summarize")
    summarize.add_argument("--benchmark", default="")
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


def write_phase(args: argparse.Namespace) -> int:
    cache_hit = optional_bool(args.cache_hit)
    import_ready = optional_bool(args.cache_import_ready)
    evidence = load_evidence(args.evidence)
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
            "tag": args.cache_tag or None,
            "workspace": args.workspace or None,
            "storage_bytes": None,
            "storage_source": None,
        },
        "source": {
            "repository": args.source_repository or None,
            "sha": args.source_sha or None,
        },
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

    observations = {
        payload["phase"]: {
            "cache_hit": payload["cache"]["hit"],
            "cache_import_ready": payload["cache"]["import_ready"],
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


def cache_state(payload: dict[str, Any]) -> str:
    cache = payload["cache"]
    if cache["import_ready"] is False:
        return "import not ready"
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
                if phase_name != "cold" and (observed.get("cache_hit") is False or observed.get("cache_import_ready") is False):
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
