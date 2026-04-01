#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class ExampleScore:
    name: str
    final_overall: float | None
    parity_overall: float | None
    quality_overall: float | None


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _safe_float(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _load_summary(path: Path) -> dict[str, ExampleScore]:
    payload = _read_json(path)
    examples = payload.get("examples")
    if not isinstance(examples, list):
        raise ValueError(f"Invalid summary.json: missing examples list: {path}")

    out: dict[str, ExampleScore] = {}
    for item in examples:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if not isinstance(name, str) or not name:
            continue
        parity = item.get("parity") if isinstance(item.get("parity"), dict) else {}
        out[name] = ExampleScore(
            name=name,
            final_overall=_safe_float(item.get("final_overall")),
            parity_overall=_safe_float(parity.get("overall")) if isinstance(parity, dict) else None,
            quality_overall=_safe_float(item.get("quality_overall")),
        )
    return out


def _mean(values: list[float]) -> float:
    return sum(values) / float(len(values)) if values else 0.0


def _format_score(value: float | None) -> str:
    return "None" if value is None else f"{value:.4f}"


def _format_delta(value: float | None) -> str:
    if value is None:
        return ""
    sign = "+" if value >= 0 else ""
    return f"{sign}{value:.4f}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Aggregate degraded-lane example-eval scores by defect family.")
    parser.add_argument("--lane-root", type=Path, required=True, help="Lane repo root (contains degraded_lane_index.json).")
    parser.add_argument("--summary-json", type=Path, required=True, help="example-eval summary.json to aggregate.")
    parser.add_argument("--baseline-summary-json", type=Path, default=None, help="Optional baseline summary.json for deltas.")
    parser.add_argument("--out-md", type=Path, default=None, help="Write Markdown summary to this path.")
    args = parser.parse_args(argv)

    lane_root = args.lane_root.resolve()
    index_path = lane_root / "degraded_lane_index.json"
    if not index_path.is_file():
        raise SystemExit(f"Missing lane index: {index_path}")

    index = _read_json(index_path)
    variants = index.get("variants")
    if not isinstance(variants, list):
        raise SystemExit(f"Invalid lane index (missing variants): {index_path}")

    summary = _load_summary(args.summary_json.resolve())
    baseline = _load_summary(args.baseline_summary_json.resolve()) if args.baseline_summary_json else None

    by_family: dict[str, list[ExampleScore]] = {}
    missing: list[str] = []
    for variant in variants:
        if not isinstance(variant, dict):
            continue
        name = variant.get("name")
        family = variant.get("family")
        if not isinstance(name, str) or not isinstance(family, str):
            continue
        score = summary.get(name)
        if score is None:
            missing.append(name)
            continue
        by_family.setdefault(family, []).append(score)

    lines: list[str] = []
    lines.append("# Degraded lane score summary")
    lines.append("")
    lines.append(f"- lane_root: `{lane_root}`")
    lines.append(f"- summary_json: `{args.summary_json.resolve()}`")
    if args.baseline_summary_json:
        lines.append(f"- baseline_summary_json: `{args.baseline_summary_json.resolve()}`")
    lines.append("")

    if missing:
        lines.append("## Missing examples")
        lines.append("")
        lines.append(f"- missing_in_summary: {len(missing)}")
        for name in sorted(missing):
            lines.append(f"  - `{name}`")
        lines.append("")

    lines.append("## By family")
    lines.append("")
    if baseline is None:
        lines.append("| Family | N | Final (mean) | Parity (mean) | Quality (mean) |")
        lines.append("|---|---:|---:|---:|---:|")
    else:
        lines.append("| Family | N | Final (mean) | Δ Final | Parity (mean) | Quality (mean) |")
        lines.append("|---|---:|---:|---:|---:|---:|")

    for family in sorted(by_family.keys()):
        scores = by_family[family]
        finals = [s.final_overall for s in scores if s.final_overall is not None]
        parities = [s.parity_overall for s in scores if s.parity_overall is not None]
        qualities = [s.quality_overall for s in scores if s.quality_overall is not None]

        final_mean = _mean(finals) if finals else None
        parity_mean = _mean(parities) if parities else None
        quality_mean = _mean(qualities) if qualities else None

        if baseline is None:
            lines.append(
                f"| `{family}` | {len(scores)} | {_format_score(final_mean)} | {_format_score(parity_mean)} | {_format_score(quality_mean)} |"
            )
            continue

        baseline_finals = [
            baseline[name].final_overall
            for name in (s.name for s in scores)
            if name in baseline and baseline[name].final_overall is not None
        ]
        baseline_mean = _mean(baseline_finals) if baseline_finals else None
        delta = (final_mean - baseline_mean) if final_mean is not None and baseline_mean is not None else None
        lines.append(
            f"| `{family}` | {len(scores)} | {_format_score(final_mean)} | {_format_delta(delta)} | {_format_score(parity_mean)} | {_format_score(quality_mean)} |"
        )

    lines.append("")

    out_text = "\n".join(lines).rstrip() + "\n"
    if args.out_md is None:
        sys.stdout.write(out_text)
        return 0

    out_path = args.out_md.expanduser().resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(out_text, encoding="utf-8")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv[1:]))
