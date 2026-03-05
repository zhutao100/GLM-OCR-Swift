#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class GitInfo:
    head_sha: str | None
    describe: str | None
    is_dirty: bool | None


_DIRTY_STATUS_IGNORED_PREFIXES = (
    "examples/result/",
    "examples/eval_records/",
)


def _run(
    argv: list[str],
    *,
    cwd: Path,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, cwd=cwd, text=True, capture_output=True)


def _git(repo_root: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return _run(["git", *args], cwd=repo_root)


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.rstrip() + "\n", encoding="utf-8")


def _format_score(score: float | None) -> str:
    if score is None:
        return "None"
    return f"{score:.4f}"


def _format_delta(delta: float | None) -> str:
    if delta is None:
        return ""
    sign = "+" if delta >= 0 else ""
    return f"{sign}{delta:.4f}"


def _safe_float(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _git_porcelain_paths(output: str) -> list[str]:
    paths: list[str] = []
    for line in output.splitlines():
        if not line:
            continue
        if len(line) < 4:
            continue
        path_part = line[3:]
        if " -> " in path_part:
            path_part = path_part.split(" -> ", 1)[1]
        path_part = path_part.strip().strip('"')
        if path_part:
            paths.append(path_part)
    return paths


def _is_ignored_dirty_path(path: str) -> bool:
    for prefix in _DIRTY_STATUS_IGNORED_PREFIXES:
        if path == prefix.rstrip("/"):
            return True
        if path.startswith(prefix):
            return True
    return False


def _git_info(repo_root: Path) -> GitInfo:
    head = _git(repo_root, ["rev-parse", "HEAD"])
    head_sha = head.stdout.strip() if head.returncode == 0 else None

    status = _git(repo_root, ["status", "--porcelain=v1"])
    if status.returncode != 0:
        is_dirty = None
    else:
        dirty_paths = [p for p in _git_porcelain_paths(status.stdout) if not _is_ignored_dirty_path(p)]
        is_dirty = bool(dirty_paths)

    describe = _git(repo_root, ["describe", "--always"])
    if describe.returncode != 0:
        describe_text = None
    else:
        describe_text = describe.stdout.strip()
        if is_dirty:
            describe_text = f"{describe_text}-dirty"

    return GitInfo(head_sha=head_sha, describe=describe_text, is_dirty=is_dirty)


def _maybe_git_show(repo_root: Path, rev: str, path: Path) -> str | None:
    rel = path.as_posix()
    proc = _git(repo_root, ["show", f"{rev}:{rel}"])
    if proc.returncode != 0:
        return None
    return proc.stdout


def _copy_eval_artifacts(build_dir: Path, record_dir: Path) -> None:
    build_summary_json = build_dir / "summary.json"
    build_summary_md = build_dir / "summary.md"
    if not build_summary_json.is_file():
        raise FileNotFoundError(f"Missing evaluator output: {build_summary_json}")
    if not build_summary_md.is_file():
        raise FileNotFoundError(f"Missing evaluator output: {build_summary_md}")

    record_dir.mkdir(parents=True, exist_ok=True)
    record_junit = record_dir / "junit.xml"
    if record_junit.exists():
        record_junit.unlink()

    record_examples = record_dir / "examples"
    if record_examples.exists():
        shutil.rmtree(record_examples)

    shutil.copy2(build_summary_json, record_dir / "summary.json")
    shutil.copy2(build_summary_md, record_dir / "summary.md")

    build_junit = build_dir / "junit.xml"
    if build_junit.is_file():
        shutil.copy2(build_junit, record_junit)

    build_examples = build_dir / "examples"
    if build_examples.is_dir():
        def ignore(_dir: str, names: list[str]) -> set[str]:
            return {n for n in names if n == ".DS_Store"}

        shutil.copytree(build_examples, record_examples, ignore=ignore)


def _summarize_example_signals(example: dict[str, Any]) -> list[str]:
    parity = example.get("parity") or {}
    if not parity.get("available", False):
        reason = parity.get("missing_reason") or "missing parity score"
        return [f"- parity: unavailable ({reason})"]

    out: list[str] = []
    hint_style = False
    hint_json = False
    hint_blocks = False
    hint_tables = False
    hint_rules = False

    dims = (example.get("final_dimensions") or {}) if isinstance(example.get("final_dimensions"), dict) else {}
    dim_items: list[tuple[str, float]] = []
    for k, v in dims.items():
        sv = _safe_float(v)
        if sv is not None:
            dim_items.append((k, sv))
    dim_items.sort(key=lambda kv: kv[1])
    if dim_items:
        lowest_name, lowest_score = dim_items[0]
        out.append(f"- lowest dimension: `{lowest_name}` = {_format_score(lowest_score)}")

    details = parity.get("details") or {}

    style = details.get("style") or {}
    actual_style = style.get("actual") or {}
    expected_style = style.get("expected") or {}
    if isinstance(actual_style, dict) and isinstance(expected_style, dict):
        center_actual = actual_style.get("center_wrappers")
        center_expected = expected_style.get("center_wrappers")
        if center_actual != center_expected and center_actual is not None and center_expected is not None:
            out.append(f"- style.center_wrappers: actual={center_actual}, expected={center_expected}")
            hint_style = True

        bold_actual = actual_style.get("bold_markers")
        bold_expected = expected_style.get("bold_markers")
        if bold_actual != bold_expected and bold_actual is not None and bold_expected is not None:
            out.append(f"- style.bold_markers: actual={bold_actual}, expected={bold_expected}")
            hint_style = True

        hl_actual = actual_style.get("heading_levels")
        hl_expected = expected_style.get("heading_levels")
        if hl_actual != hl_expected and hl_actual is not None and hl_expected is not None:
            out.append(f"- style.heading_levels: actual={hl_actual}, expected={hl_expected}")
            hint_style = True

        lang_actual = actual_style.get("code_languages")
        lang_expected = expected_style.get("code_languages")
        if lang_actual != lang_expected and lang_actual is not None and lang_expected is not None:
            out.append(f"- style.code_languages: actual={lang_actual}, expected={lang_expected}")
            hint_style = True

    json_details = details.get("json") or {}
    if isinstance(json_details, dict) and json_details.get("available") is True:
        components = json_details.get("components") or {}
        if isinstance(components, dict):
            lows = [(k, _safe_float(v)) for k, v in components.items()]
            lows = [(k, v) for k, v in lows if v is not None and v < 0.98]
            lows.sort(key=lambda kv: kv[1])
            if lows:
                formatted = ", ".join(f"{k}={_format_score(v)}" for k, v in lows[:5])
                out.append(f"- json components < 0.98: {formatted}")
                hint_json = True

    tables = details.get("tables") or {}
    if isinstance(tables, dict):
        table_list = tables.get("tables") or []
        low_tables: list[str] = []
        if isinstance(table_list, list):
            for t in table_list:
                if not isinstance(t, dict):
                    continue
                score = _safe_float(t.get("score"))
                if score is None or score >= 0.98:
                    continue
                idx = t.get("index")
                low_tables.append(f"#{idx}={_format_score(score)}")
        if low_tables:
            out.append(f"- tables < 0.98: {', '.join(low_tables[:5])}")
            hint_tables = True

    block_shape = _safe_float(details.get("block_shape"))
    if block_shape is not None and block_shape < 0.98:
        out.append(f"- block_shape: {_format_score(block_shape)}")
        hint_blocks = True

    text_details = details.get("text") or {}
    if isinstance(text_details, dict):
        blocks = text_details.get("blocks") or []
        if isinstance(blocks, list) and blocks:
            status_counts: dict[str, int] = {}
            low_pairs: list[tuple[float, dict[str, Any]]] = []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                status = str(b.get("status") or "unknown")
                status_counts[status] = status_counts.get(status, 0) + 1
                score = _safe_float(b.get("score")) or 0.0
                if status != "paired" or score < 0.50:
                    low_pairs.append((score, b))
                    hint_blocks = True
            if status_counts:
                counts = ", ".join(f"{k}={v}" for k, v in sorted(status_counts.items()))
                out.append(f"- text blocks: {counts}")
            if low_pairs:
                low_pairs.sort(key=lambda kv: kv[0])
                samples: list[str] = []
                for score, b in low_pairs[:5]:
                    idx = b.get("index")
                    actual_kind = b.get("actual_kind")
                    expected_kind = b.get("expected_kind")
                    status = b.get("status")
                    samples.append(
                        f"(idx={idx}, status={status}, actual={actual_kind}, expected={expected_kind}, score={_format_score(score)})"
                    )
                out.append(f"- lowest text pairs: {', '.join(samples)}")

    failed_rules = [
        r
        for r in (example.get("rules") or [])
        if isinstance(r, dict) and r.get("status") in {"fail", "error"}
    ]
    if failed_rules:
        head = failed_rules[0]
        out.append(
            f"- rules failed: {len(failed_rules)} (first: {head.get('check_id')} / {head.get('check_type')} / {head.get('message')})"
        )
        hint_rules = True

    hints: list[str] = []
    if hint_style:
        hints.append("Markdown style wrappers (centering/bold/fences)")
    if hint_json:
        hints.append("OCR JSON (block ordering, bbox rounding, content normalization)")
    if hint_blocks:
        hints.append("Markdown block segmentation (heading/list/paragraph splits)")
    if hint_tables:
        hints.append("Table extraction/canonicalization")
    if hint_rules:
        hints.append("Example-specific rules/regression")
    if hints:
        out.append(f"- fix_hints: {', '.join(hints)}")

    return out


def _render_agent_report(
    *,
    repo_root: Path,
    current_summary: dict[str, Any],
    baseline_summary: dict[str, Any] | None,
    git_info: GitInfo,
) -> str:
    generated_at = dt.datetime.now(dt.UTC).isoformat(timespec="seconds")

    baseline_by_name: dict[str, dict[str, Any]] = {}
    if baseline_summary is not None:
        for ex in baseline_summary.get("examples", []):
            if isinstance(ex, dict) and isinstance(ex.get("name"), str):
                baseline_by_name[ex["name"]] = ex

    current_examples = [ex for ex in current_summary.get("examples", []) if isinstance(ex, dict)]

    rows: list[tuple[str, float, float | None]] = []
    for ex in current_examples:
        name = ex.get("name")
        if not isinstance(name, str):
            continue
        final = _safe_float(ex.get("final_overall"))
        if final is None:
            continue
        base_final = _safe_float((baseline_by_name.get(name) or {}).get("final_overall"))
        delta = None if base_final is None else (final - base_final)
        rows.append((name, final, delta))
    rows.sort(key=lambda r: r[1])

    mean_final: float | None = None
    if rows:
        mean_final = sum(r[1] for r in rows) / len(rows)

    lines: list[str] = []
    lines.append("# Example evaluation (agent report)")
    lines.append("")
    lines.append(f"- generated_at: `{generated_at}`")
    if git_info.describe:
        lines.append(f"- git: `{git_info.describe}`")
    if git_info.head_sha:
        lines.append(f"- git_head_sha: `{git_info.head_sha}`")
    if git_info.is_dirty is not None:
        lines.append(f"- git_dirty: `{git_info.is_dirty}`")
    if mean_final is not None:
        lines.append(f"- mean_final_overall: `{_format_score(mean_final)}`")
    lines.append("")

    lines.append("## Scores")
    lines.append("")
    lines.append("| Example | Final | Δ vs baseline | Parity | Result→Golden | Ref→Golden | Rules |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    for ex in sorted(current_examples, key=lambda e: str(e.get("name") or "")):
        name = ex.get("name")
        if not isinstance(name, str):
            continue
        final = _safe_float(ex.get("final_overall"))
        base_final = _safe_float((baseline_by_name.get(name) or {}).get("final_overall"))
        delta = None if (final is None or base_final is None) else (final - base_final)

        parity_overall = _safe_float(((ex.get("parity") or {}) if isinstance(ex.get("parity"), dict) else {}).get("overall"))
        rtg_overall = _safe_float(
            (
                (ex.get("result_to_golden") or {})
                if isinstance(ex.get("result_to_golden"), dict)
                else {}
            ).get("overall")
        )
        rfg_overall = _safe_float(
            (
                (ex.get("reference_to_golden") or {})
                if isinstance(ex.get("reference_to_golden"), dict)
                else {}
            ).get("overall")
        )
        rules = ex.get("rules") or []
        failed = sum(
            1 for r in rules if isinstance(r, dict) and r.get("status") in {"fail", "error"}
        )
        total_rules = len(rules) if isinstance(rules, list) else 0

        lines.append(
            f"| `{name}` | {_format_score(final)} | {_format_delta(delta)} | {_format_score(parity_overall)} | {_format_score(rtg_overall)} | {_format_score(rfg_overall)} | {failed}/{total_rules} |"
        )

    lines.append("")
    lines.append("## Focus")
    lines.append("")

    focus = [r for r in rows if r[1] < 0.90 or (r[2] is not None and r[2] < -0.001)]
    if not focus:
        focus = rows[:3]
    for name, final, delta in focus:
        ex = next((e for e in current_examples if e.get("name") == name), None)
        if ex is None:
            continue
        lines.append(f"### `{name}`")
        lines.append("")
        lines.append(f"- final_overall: `{_format_score(final)}`")
        if delta is not None:
            lines.append(f"- delta_vs_baseline: `{_format_delta(delta)}`")
        lines.append(f"- result_md: `examples/result/{name}/{name}.md`")
        lines.append(f"- result_json: `examples/result/{name}/{name}.json`")
        lines.append(f"- reference_md: `examples/reference_result/{name}/{name}.md`")
        lines.append(f"- reference_json: `examples/reference_result/{name}/{name}.json`")
        lines.append(f"- eval_report_md: `examples/eval_records/latest/examples/{name}/report.md`")
        lines.append(f"- eval_report_json: `examples/eval_records/latest/examples/{name}/report.json`")
        golden_dir = repo_root / "examples" / "golden_result" / name
        if golden_dir.is_dir():
            lines.append(f"- golden_md: `examples/golden_result/{name}/{name}.md`")
            lines.append(f"- golden_json: `examples/golden_result/{name}/{name}.json`")
        else:
            lines.append("- golden: not available for this example")

        signals = _summarize_example_signals(ex)
        if signals:
            lines.append("")
            lines.append("**Signals**")
            lines.extend(signals)
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def _render_delta_report(
    *,
    current_summary: dict[str, Any],
    baseline_summary: dict[str, Any] | None,
) -> str:
    if baseline_summary is None:
        return (
            "# Example evaluation delta (baseline unavailable)\n\n"
            "- No baseline found in `git show HEAD:examples/eval_records/latest/summary.json`.\n"
            "- To establish a baseline, commit `examples/eval_records/latest/` on a known-good run,\n"
            "  then rerun `scripts/verify_example_eval.sh` to get deltas vs that baseline.\n"
        )

    baseline_by_name: dict[str, dict[str, Any]] = {}
    for ex in baseline_summary.get("examples", []):
        if isinstance(ex, dict) and isinstance(ex.get("name"), str):
            baseline_by_name[ex["name"]] = ex

    current_examples = [ex for ex in current_summary.get("examples", []) if isinstance(ex, dict)]

    deltas: list[tuple[str, float]] = []
    for ex in current_examples:
        name = ex.get("name")
        if not isinstance(name, str):
            continue
        current_final = _safe_float(ex.get("final_overall"))
        baseline_final = _safe_float((baseline_by_name.get(name) or {}).get("final_overall"))
        if current_final is None or baseline_final is None:
            continue
        deltas.append((name, current_final - baseline_final))

    deltas.sort(key=lambda kv: kv[1])

    lines: list[str] = []
    lines.append("# Example evaluation delta (vs baseline)")
    lines.append("")
    if not deltas:
        lines.append("- No comparable examples between baseline and current.")
        return "\n".join(lines).rstrip() + "\n"

    regressions = [d for d in deltas if d[1] < -0.001]
    improvements = [d for d in deltas if d[1] > 0.001]

    lines.append(f"- regressions: `{len(regressions)}`")
    lines.append(f"- improvements: `{len(improvements)}`")
    lines.append("")

    lines.append("| Example | Δ final_overall |")
    lines.append("|---|---:|")
    for name, delta in deltas:
        lines.append(f"| `{name}` | {_format_delta(delta)} |")

    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Record tools/example_eval output into a persistent repo directory.")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd(), help="Repository root (default: cwd).")
    parser.add_argument(
        "--build-dir",
        type=Path,
        default=Path(".build/example_eval"),
        help="Evaluator output dir (default: .build/example_eval).",
    )
    parser.add_argument(
        "--record-dir",
        type=Path,
        default=Path("examples/eval_records/latest"),
        help="Persistent record output dir (default: examples/eval_records/latest).",
    )
    parser.add_argument(
        "--baseline-ref",
        type=str,
        default="HEAD",
        help="Git ref to read the baseline from (default: HEAD).",
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    build_dir = (repo_root / args.build_dir).resolve()
    record_dir = (repo_root / args.record_dir).resolve()

    _copy_eval_artifacts(build_dir, record_dir)

    current_summary = _read_json(record_dir / "summary.json")
    if not isinstance(current_summary, dict):
        raise ValueError("summary.json must be an object at top-level")

    baseline_text = _maybe_git_show(repo_root, args.baseline_ref, Path("examples/eval_records/latest/summary.json"))
    baseline_summary = json.loads(baseline_text) if baseline_text else None
    if baseline_summary is not None and not isinstance(baseline_summary, dict):
        baseline_summary = None

    git_info = _git_info(repo_root)
    meta: dict[str, Any] = {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git": {
            "head_sha": git_info.head_sha,
            "describe": git_info.describe,
            "dirty": git_info.is_dirty,
        },
        "tools": {
            "python": sys.version.split()[0],
        },
    }

    uv = _run(["uv", "--version"], cwd=repo_root)
    if uv.returncode == 0:
        meta["tools"]["uv"] = uv.stdout.strip()

    example_eval_sha = _git(repo_root, ["-C", "tools/example_eval", "rev-parse", "HEAD"])
    if example_eval_sha.returncode == 0:
        meta["tools"]["example_eval_submodule_head_sha"] = example_eval_sha.stdout.strip()

    examples_meta_path = repo_root / "examples" / "result" / ".run_examples_meta.json"
    if examples_meta_path.is_file():
        try:
            meta["examples_result"] = _read_json(examples_meta_path)
        except Exception:
            meta["examples_result"] = {"error": f"failed to parse {examples_meta_path.as_posix()}"}

    _write_json(record_dir / "meta.json", meta)

    agent_report = _render_agent_report(
        repo_root=repo_root,
        current_summary=current_summary,
        baseline_summary=baseline_summary,
        git_info=git_info,
    )
    _write_text(record_dir / "agent_report.md", agent_report)

    delta_report = _render_delta_report(current_summary=current_summary, baseline_summary=baseline_summary)
    _write_text(record_dir / "delta_from_baseline.md", delta_report)

    print(f"OK: wrote {record_dir.relative_to(repo_root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
