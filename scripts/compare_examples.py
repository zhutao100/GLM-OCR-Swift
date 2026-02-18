#!/usr/bin/env python3

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal


Lane = Literal["parity", "quality"]
ImagePolicy = Literal["none", "exists", "sha256"]
FailCondition = Literal["missing", "markdown", "json", "images"]


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compare examples/result/* against reference_result (parity lane) and/or golden_result (quality lane).\n\n"
            "Default behavior is report-only: it writes diffs + a summary under .build/quality_parity and exits 0.\n"
            "Use --fail-on to make it exit non-zero when diffs/missing artifacts are found.\n"
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "--lane",
        default="both",
        choices=["parity", "quality", "both"],
        help="Which baseline lane to compare against.",
    )
    parser.add_argument(
        "--example",
        action="append",
        default=[],
        help="Compare only this example name (repeatable). Default: all examples under examples/source.",
    )
    parser.add_argument("--source-root", type=Path, default=Path("examples/source"), help="Input fixtures root.")
    parser.add_argument("--result-root", type=Path, default=Path("examples/result"), help="Generated outputs root.")
    parser.add_argument(
        "--reference-root",
        type=Path,
        default=Path("examples/reference_result"),
        help="Upstream reference baseline root (parity lane).",
    )
    parser.add_argument(
        "--golden-root",
        type=Path,
        default=Path("examples/golden_result"),
        help="Curated golden baseline root (quality lane).",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(".build/quality_parity"),
        help="Output directory for reports/diffs.",
    )
    parser.add_argument(
        "--bbox-tolerance",
        type=int,
        default=15,
        help="Max allowed bbox_2d coordinate delta for JSON structural parity (parity lane).",
    )
    parser.add_argument(
        "--image-policy",
        choices=["none", "exists", "sha256"],
        default="exists",
        help="How strictly to compare imgs/* assets.",
    )
    parser.add_argument(
        "--max-details",
        type=int,
        default=25,
        help="Max number of per-example mismatch details to record in diff text.",
    )
    parser.add_argument(
        "--fail-on",
        action="append",
        default=[],
        choices=["missing", "markdown", "json", "images"],
        help="Exit non-zero if any example has this kind of issue (repeatable).",
    )
    return parser.parse_args()


def _is_noisy_file(path: Path) -> bool:
    name = path.name
    if name in {".DS_Store", "Thumbs.db", "desktop.ini"}:
        return True
    if name.startswith("._"):
        return True
    if name.startswith("."):
        return True
    return False


def _list_examples_from_source(source_root: Path) -> list[str]:
    if not source_root.is_dir():
        raise SystemExit(f"Missing --source-root: {source_root}")

    supported = {".png", ".jpg", ".jpeg", ".pdf"}
    names: list[str] = []
    for path in source_root.iterdir():
        if not path.is_file() or _is_noisy_file(path):
            continue
        if path.suffix.lower() not in supported:
            continue
        names.append(path.stem)
    return sorted(set(names))


def _normalize_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [line.rstrip() for line in text.split("\n")]
    return "\n".join(lines).strip()


def _unified_diff(a: str, b: str, *, fromfile: str, tofile: str) -> str:
    a_lines = a.splitlines(keepends=True)
    b_lines = b.splitlines(keepends=True)
    diff = difflib.unified_diff(a_lines, b_lines, fromfile=fromfile, tofile=tofile, n=3)
    return "".join(diff)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass(frozen=True)
class MarkdownReport:
    status: Literal["match", "diff", "missing"]
    similarity: float | None = None


def _compare_markdown(actual_path: Path, expected_path: Path, *, out_dir: Path) -> MarkdownReport:
    if not expected_path.is_file() or not actual_path.is_file():
        return MarkdownReport(status="missing", similarity=None)

    expected_raw = expected_path.read_text(encoding="utf-8")
    actual_raw = actual_path.read_text(encoding="utf-8")

    expected = _normalize_text(expected_raw)
    actual = _normalize_text(actual_raw)

    if expected == actual:
        return MarkdownReport(status="match", similarity=1.0)

    ratio = difflib.SequenceMatcher(a=expected, b=actual).ratio()
    diff_text = _unified_diff(
        expected,
        actual,
        fromfile=str(expected_path),
        tofile=str(actual_path),
    )
    (out_dir / "markdown.diff").write_text(diff_text, encoding="utf-8")
    return MarkdownReport(status="diff", similarity=ratio)


@dataclass(frozen=True)
class JSONReport:
    status: Literal["match", "diff", "missing", "error"]
    structural_ok: bool | None = None
    content_ok: bool | None = None
    max_bbox_delta: int | None = None
    pages_expected: int | None = None
    pages_actual: int | None = None
    blocks_expected: int | None = None
    blocks_actual: int | None = None


def _as_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


def _compare_json_block_list(
    actual_path: Path,
    expected_path: Path,
    *,
    bbox_tolerance: int,
    max_details: int,
    out_dir: Path,
) -> JSONReport:
    if not expected_path.is_file() or not actual_path.is_file():
        return JSONReport(status="missing")

    try:
        expected = json.loads(expected_path.read_text(encoding="utf-8"))
        actual = json.loads(actual_path.read_text(encoding="utf-8"))
    except Exception as e:
        (out_dir / "json.diff").write_text(f"ERROR: failed to parse JSON: {e}\n", encoding="utf-8")
        return JSONReport(status="error")

    if not isinstance(expected, list) or not isinstance(actual, list):
        (out_dir / "json.diff").write_text(
            "ERROR: expected both JSON roots to be lists (pages).\n",
            encoding="utf-8",
        )
        return JSONReport(status="error")

    pages_expected = len(expected)
    pages_actual = len(actual)

    structural_ok = True
    content_ok = True
    max_bbox_delta = 0

    blocks_expected_total = 0
    blocks_actual_total = 0

    details: list[str] = []

    if pages_expected != pages_actual:
        structural_ok = False
        details.append(f"- Page count mismatch: expected={pages_expected} actual={pages_actual}")

    for page_idx, (e_page, a_page) in enumerate(zip(expected, actual)):
        if not isinstance(e_page, list) or not isinstance(a_page, list):
            structural_ok = False
            details.append(f"- Page {page_idx}: expected/actual page is not a list")
            continue

        blocks_expected_total += len(e_page)
        blocks_actual_total += len(a_page)

        if len(e_page) != len(a_page):
            structural_ok = False
            details.append(f"- Page {page_idx}: block count mismatch expected={len(e_page)} actual={len(a_page)}")

        for block_idx, (e_blk, a_blk) in enumerate(zip(e_page, a_page)):
            if len(details) >= max_details:
                break

            if not isinstance(e_blk, dict) or not isinstance(a_blk, dict):
                structural_ok = False
                details.append(f"- Page {page_idx} block {block_idx}: expected/actual block is not an object")
                continue

            e_index = _as_int(e_blk.get("index"))
            a_index = _as_int(a_blk.get("index"))
            if e_index is None or a_index is None or e_index != a_index:
                structural_ok = False
                details.append(f"- Page {page_idx} block {block_idx}: index mismatch expected={e_index} actual={a_index}")

            e_label = e_blk.get("label")
            a_label = a_blk.get("label")
            if e_label != a_label:
                structural_ok = False
                details.append(f"- Page {page_idx} block {block_idx}: label mismatch expected={e_label!r} actual={a_label!r}")

            e_bbox = e_blk.get("bbox_2d")
            a_bbox = a_blk.get("bbox_2d")
            if not (isinstance(e_bbox, list) and isinstance(a_bbox, list) and len(e_bbox) == 4 and len(a_bbox) == 4):
                structural_ok = False
                details.append(f"- Page {page_idx} block {block_idx}: bbox_2d missing/invalid")
            else:
                for coord_idx, (ev, av) in enumerate(zip(e_bbox, a_bbox)):
                    evi = _as_int(ev)
                    avi = _as_int(av)
                    if evi is None or avi is None:
                        structural_ok = False
                        details.append(
                            f"- Page {page_idx} block {block_idx}: bbox_2d coord {coord_idx} not int-like: expected={ev!r} actual={av!r}"
                        )
                        continue
                    delta = abs(avi - evi)
                    max_bbox_delta = max(max_bbox_delta, delta)
                    if delta > bbox_tolerance:
                        structural_ok = False
                        details.append(
                            f"- Page {page_idx} block {block_idx}: bbox_2d coord {coord_idx} delta={delta} > tol={bbox_tolerance}"
                        )

            e_content = _normalize_text(str(e_blk.get("content", "")))
            a_content = _normalize_text(str(a_blk.get("content", "")))

            if e_label == "image":
                if e_content.strip() != "" or a_content.strip() != "":
                    content_ok = False
                    details.append(f"- Page {page_idx} block {block_idx}: image block content must be empty")
            else:
                if e_content == "" or a_content == "":
                    content_ok = False
                    details.append(f"- Page {page_idx} block {block_idx}: text block content must be non-empty")
                elif e_content != a_content:
                    content_ok = False
                    details.append(f"- Page {page_idx} block {block_idx}: content mismatch (normalized)")

        if len(details) >= max_details:
            details.append(f"- … truncated (max_details={max_details})")
            break

    if pages_expected != pages_actual:
        # totals are only meaningful when pages align
        blocks_expected = None
        blocks_actual = None
    else:
        blocks_expected = blocks_expected_total
        blocks_actual = blocks_actual_total

    if structural_ok and content_ok:
        return JSONReport(
            status="match",
            structural_ok=True,
            content_ok=True,
            max_bbox_delta=max_bbox_delta,
            pages_expected=pages_expected,
            pages_actual=pages_actual,
            blocks_expected=blocks_expected,
            blocks_actual=blocks_actual,
        )

    lines: list[str] = []
    lines.append("JSON parity summary")
    lines.append(f"- structural_ok: {structural_ok}")
    lines.append(f"- content_ok   : {content_ok}")
    lines.append(f"- bbox_tol     : {bbox_tolerance}")
    lines.append(f"- max_bbox_delta: {max_bbox_delta}")
    lines.append(f"- pages expected/actual: {pages_expected}/{pages_actual}")
    if blocks_expected is not None and blocks_actual is not None:
        lines.append(f"- blocks expected/actual: {blocks_expected}/{blocks_actual}")
    lines.append("")
    lines.append("Details:")
    lines.extend(details if details else ["- (no details recorded)"])
    (out_dir / "json.diff").write_text("\n".join(lines) + "\n", encoding="utf-8")

    return JSONReport(
        status="diff",
        structural_ok=structural_ok,
        content_ok=content_ok,
        max_bbox_delta=max_bbox_delta,
        pages_expected=pages_expected,
        pages_actual=pages_actual,
        blocks_expected=blocks_expected,
        blocks_actual=blocks_actual,
    )


@dataclass(frozen=True)
class ImagesReport:
    status: Literal["match", "diff", "missing", "skipped"]
    missing: list[str]
    extra: list[str]
    hash_mismatch: list[str]


def _list_image_files(folder: Path) -> list[Path]:
    if not folder.is_dir():
        return []
    out: list[Path] = []
    for p in folder.iterdir():
        if not p.is_file() or _is_noisy_file(p):
            continue
        out.append(p)
    return sorted(out, key=lambda p: p.name)


def _compare_images(
    *,
    actual_dir: Path,
    expected_dir: Path,
    policy: ImagePolicy,
    out_dir: Path,
    max_details: int,
) -> ImagesReport:
    if policy == "none":
        return ImagesReport(status="skipped", missing=[], extra=[], hash_mismatch=[])

    expected_files = _list_image_files(expected_dir)
    if not expected_files:
        # No expected images for this example baseline.
        return ImagesReport(status="match", missing=[], extra=[], hash_mismatch=[])

    actual_files = _list_image_files(actual_dir)
    expected_names = {p.name for p in expected_files}
    actual_names = {p.name for p in actual_files}

    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)

    hash_mismatch: list[str] = []
    if policy == "sha256":
        for name in sorted(expected_names & actual_names):
            e = expected_dir / name
            a = actual_dir / name
            if _sha256(e) != _sha256(a):
                hash_mismatch.append(name)
                if len(hash_mismatch) >= max_details:
                    break

    status: Literal["match", "diff", "missing"]
    if missing:
        status = "missing"
    elif extra or hash_mismatch:
        status = "diff"
    else:
        status = "match"

    if status != "match":
        lines: list[str] = []
        lines.append("Images summary")
        lines.append(f"- policy: {policy}")
        if missing:
            lines.append(f"- missing ({len(missing)}): {missing[:max_details]}")
        if extra:
            lines.append(f"- extra ({len(extra)}): {extra[:max_details]}")
        if hash_mismatch:
            lines.append(f"- sha256 mismatch ({len(hash_mismatch)}): {hash_mismatch[:max_details]}")
        (out_dir / "images.diff").write_text("\n".join(lines) + "\n", encoding="utf-8")

    return ImagesReport(status=status, missing=missing, extra=extra, hash_mismatch=hash_mismatch)


@dataclass(frozen=True)
class ExampleReport:
    name: str
    markdown: MarkdownReport
    json: JSONReport | None
    images: ImagesReport


def _write_summary_md(lane: Lane, reports: list[ExampleReport], *, out_dir: Path) -> None:
    has_json = lane == "parity"
    header = "| Example | Markdown | JSON | Images |"
    sep = "|---|---:|---:|---:|"
    if not has_json:
        header = "| Example | Markdown | Images |"
        sep = "|---|---:|---:|"

    rows: list[str] = [header, sep]
    for r in reports:
        md = r.markdown.status
        img = r.images.status
        if has_json:
            js = r.json.status if r.json else "—"
            rows.append(f"| `{r.name}` | {md} | {js} | {img} |")
        else:
            rows.append(f"| `{r.name}` | {md} | {img} |")

    (out_dir / "summary.md").write_text("\n".join(rows) + "\n", encoding="utf-8")


def _write_summary_json(lane: Lane, reports: list[ExampleReport], *, out_dir: Path) -> None:
    out: dict[str, Any] = {
        "lane": lane,
        "examples": [],
    }
    for r in reports:
        entry: dict[str, Any] = {
            "name": r.name,
            "markdown": {
                "status": r.markdown.status,
                "similarity": r.markdown.similarity,
            },
            "images": {
                "status": r.images.status,
                "missing": r.images.missing,
                "extra": r.images.extra,
                "hash_mismatch": r.images.hash_mismatch,
            },
        }
        if lane == "parity" and r.json is not None:
            entry["json"] = {
                "status": r.json.status,
                "structural_ok": r.json.structural_ok,
                "content_ok": r.json.content_ok,
                "max_bbox_delta": r.json.max_bbox_delta,
                "pages_expected": r.json.pages_expected,
                "pages_actual": r.json.pages_actual,
                "blocks_expected": r.json.blocks_expected,
                "blocks_actual": r.json.blocks_actual,
            }
        out["examples"].append(entry)

    (out_dir / "summary.json").write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _compare_lane(
    *,
    lane: Lane,
    example_names: list[str],
    result_root: Path,
    baseline_root: Path,
    out_root: Path,
    bbox_tolerance: int,
    image_policy: ImagePolicy,
    max_details: int,
) -> list[ExampleReport]:
    lane_out = out_root / lane
    if lane_out.exists():
        shutil.rmtree(lane_out)
    lane_out.mkdir(parents=True, exist_ok=True)

    reports: list[ExampleReport] = []
    for name in example_names:
        actual_dir = result_root / name
        expected_dir = baseline_root / name
        example_out = lane_out / name
        example_out.mkdir(parents=True, exist_ok=True)

        md_actual = actual_dir / f"{name}.md"
        md_expected = expected_dir / f"{name}.md"

        markdown_report = _compare_markdown(md_actual, md_expected, out_dir=example_out)

        json_report: JSONReport | None = None
        if lane == "parity":
            json_actual = actual_dir / f"{name}.json"
            json_expected = expected_dir / f"{name}.json"
            json_report = _compare_json_block_list(
                json_actual,
                json_expected,
                bbox_tolerance=bbox_tolerance,
                max_details=max_details,
                out_dir=example_out,
            )

        images_report = _compare_images(
            actual_dir=actual_dir / "imgs",
            expected_dir=expected_dir / "imgs",
            policy=image_policy,
            out_dir=example_out,
            max_details=max_details,
        )

        report = ExampleReport(
            name=name,
            markdown=markdown_report,
            json=json_report,
            images=images_report,
        )
        (example_out / "summary.json").write_text(
            json.dumps(
                {
                    "name": name,
                    "markdown": markdown_report.__dict__,
                    "json": json_report.__dict__ if json_report else None,
                    "images": images_report.__dict__,
                },
                indent=2,
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )
        reports.append(report)

    _write_summary_md(lane, reports, out_dir=lane_out)
    _write_summary_json(lane, reports, out_dir=lane_out)
    return reports


def _write_combined_summary(
    *,
    parity: list[ExampleReport] | None,
    quality: list[ExampleReport] | None,
    out_root: Path,
) -> None:
    if not parity and not quality:
        return

    by_name: dict[str, dict[str, Any]] = {}
    for r in parity or []:
        by_name.setdefault(r.name, {})["parity"] = r
    for r in quality or []:
        by_name.setdefault(r.name, {})["quality"] = r

    names = sorted(by_name.keys())
    rows: list[str] = [
        "| Example | Parity MD | Parity JSON | Parity Images | Quality MD | Quality Images |",
        "|---|---:|---:|---:|---:|---:|",
    ]

    combined_json: dict[str, Any] = {"examples": []}

    for name in names:
        p: ExampleReport | None = by_name[name].get("parity")
        q: ExampleReport | None = by_name[name].get("quality")

        p_md = p.markdown.status if p else "—"
        p_json = (p.json.status if (p and p.json) else "—") if p else "—"
        p_img = p.images.status if p else "—"
        q_md = q.markdown.status if q else "—"
        q_img = q.images.status if q else "—"

        rows.append(f"| `{name}` | {p_md} | {p_json} | {p_img} | {q_md} | {q_img} |")

        entry: dict[str, Any] = {"name": name}
        if p:
            entry["parity"] = {
                "markdown": p.markdown.__dict__,
                "json": p.json.__dict__ if p.json else None,
                "images": p.images.__dict__,
            }
        if q:
            entry["quality"] = {
                "markdown": q.markdown.__dict__,
                "images": q.images.__dict__,
            }
        combined_json["examples"].append(entry)

    (out_root / "summary.md").write_text("\n".join(rows) + "\n", encoding="utf-8")
    (out_root / "summary.json").write_text(json.dumps(combined_json, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _should_fail(reports: list[ExampleReport], *, lane: Lane, fail_on: set[FailCondition]) -> bool:
    for r in reports:
        if "missing" in fail_on:
            if r.markdown.status == "missing":
                return True
            if r.images.status in {"missing"}:
                return True
            if lane == "parity" and r.json and r.json.status in {"missing", "error"}:
                return True

        if "markdown" in fail_on and r.markdown.status != "match":
            return True
        if "images" in fail_on and r.images.status != "match":
            return True
        if lane == "parity" and "json" in fail_on and r.json and r.json.status != "match":
            return True

    return False


def main() -> int:
    args = _parse_args()

    example_names = args.example if args.example else _list_examples_from_source(args.source_root)
    result_root = args.result_root
    out_root = args.out_dir

    fail_on: set[FailCondition] = set(args.fail_on)
    image_policy: ImagePolicy = args.image_policy

    lanes: list[Lane] = []
    if args.lane in {"parity", "both"}:
        lanes.append("parity")
    if args.lane in {"quality", "both"}:
        lanes.append("quality")

    any_fail = False
    lane_reports: dict[Lane, list[ExampleReport]] = {}
    for lane in lanes:
        baseline_root = args.reference_root if lane == "parity" else args.golden_root
        reports = _compare_lane(
            lane=lane,
            example_names=example_names,
            result_root=result_root,
            baseline_root=baseline_root,
            out_root=out_root,
            bbox_tolerance=args.bbox_tolerance,
            image_policy=image_policy,
            max_details=args.max_details,
        )
        lane_reports[lane] = reports

        lane_out = out_root / lane
        print(f"[{lane}] Wrote report to: {lane_out}")

        if fail_on and _should_fail(reports, lane=lane, fail_on=fail_on):
            any_fail = True

    if len(lanes) == 2:
        _write_combined_summary(
            parity=lane_reports.get("parity"),
            quality=lane_reports.get("quality"),
            out_root=out_root,
        )
        print(f"[both] Wrote combined summary to: {out_root / 'summary.md'}")

    return 1 if any_fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
