#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path
from typing import Any


def _parse_bool(value: str | None) -> bool | None:
    if not value:
        return None
    normalized = value.strip().lower()
    if normalized in {"true", "1", "yes"}:
        return True
    if normalized in {"false", "0", "no"}:
        return False
    return None


def _write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Write examples/result/.run_examples_meta.json.")
    parser.add_argument("--meta-path", type=Path, required=True)
    parser.add_argument("--status", choices=["ok", "failed"], required=True)
    parser.add_argument("--configuration", choices=["debug", "release"], required=True)
    parser.add_argument("--fingerprint-sha256", default="", help="Working-tree fingerprint used for up-to-date checks.")

    parser.add_argument("--git-head-sha", default="")
    parser.add_argument("--git-describe", default="")
    parser.add_argument("--git-dirty", default="")

    parser.add_argument("--glm-model", default="")
    parser.add_argument("--glm-revision", default="")
    parser.add_argument("--layout-model", default="")
    parser.add_argument("--layout-revision", default="")
    parser.add_argument("--download-base", default="")

    parser.add_argument("--started-at-utc", default="")
    parser.add_argument("--ended-at-utc", default="")

    parser.add_argument("--succeeded", action="append", default=[])
    parser.add_argument("--failed", action="append", default=[])
    parser.add_argument("--skipped", action="append", default=[])

    args = parser.parse_args(argv)

    obj: dict[str, Any] = {
        "schema_version": 1,
        "generated_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "status": args.status,
        "configuration": args.configuration,
        "fingerprint_sha256": args.fingerprint_sha256,
        "git": {
            "head_sha": args.git_head_sha or None,
            "describe": args.git_describe or None,
            "dirty": _parse_bool(args.git_dirty),
        },
        "models": {
            "glm_model": args.glm_model,
            "glm_revision": args.glm_revision,
            "layout_model": args.layout_model,
            "layout_revision": args.layout_revision,
            "download_base": args.download_base,
        },
        "run": {
            "started_at_utc": args.started_at_utc,
            "ended_at_utc": args.ended_at_utc,
            "succeeded": args.succeeded,
            "failed": args.failed,
            "skipped": args.skipped,
        },
    }

    _write_json(args.meta_path, obj)
    print(f"Wrote {args.meta_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
