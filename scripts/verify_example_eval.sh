#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Agentic verification loop:
  1) Ensure `examples/result/` is up-to-date (refresh if needed).
  2) Run `tools/example_eval` from the repo root.
  3) Record + compare results under `examples/eval_records/latest/`.

Usage:
  scripts/verify_example_eval.sh [-c debug|release] [--force-refresh-examples] [--no-refresh-examples] [--baseline-ref <git-ref>]
EOF
}

config="release"
force_refresh_examples=0
refresh_examples=1
baseline_ref="HEAD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      config="${2:-}"; shift 2 ;;
    --force-refresh-examples)
      force_refresh_examples=1; shift ;;
    --no-refresh-examples)
      refresh_examples=0; shift ;;
    --baseline-ref)
      baseline_ref="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

if [[ "$config" != "debug" && "$config" != "release" ]]; then
  echo "Invalid configuration: $config (expected 'debug' or 'release')" >&2
  exit 2
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

. "$root_dir/scripts/_examples_fingerprint.sh"

if [[ ! -f tools/example_eval/pyproject.toml ]]; then
  echo "Missing tools/example_eval submodule. Run:" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi

meta_path="$root_dir/examples/result/.run_examples_meta.json"

result_is_complete() {
  if [[ ! -d examples/source || ! -d examples/result ]]; then
    return 1
  fi

  shopt -s nullglob
  for src_path in examples/source/*; do
    local src_name stem
    src_name="$(basename "$src_path")"
    if [[ "$src_name" == ._* ]]; then
      continue
    fi
    stem="${src_name%.*}"
    if [[ ! -f "examples/result/$stem/$stem.md" || ! -f "examples/result/$stem/$stem.json" ]]; then
      return 1
    fi
  done

  return 0
}

needs_refresh=0
if [[ "$refresh_examples" -eq 1 ]]; then
  if [[ "$force_refresh_examples" -eq 1 ]]; then
    needs_refresh=1
  else
    current_fp="$(examples_compute_fingerprint)"
    stored_fp=""
    if [[ -f "$meta_path" && -n "$current_fp" ]]; then
      stored_fp="$(
        META_PATH="$meta_path" python3 - <<'PY'
import json
import os
from pathlib import Path

p = Path(os.environ["META_PATH"])
try:
  obj = json.loads(p.read_text(encoding="utf-8"))
  legacy_fp = ""
  if isinstance(obj.get("git"), dict):
    legacy_fp = obj["git"].get("fingerprint_sha256", "") or ""
  print(obj.get("fingerprint_sha256", "") or legacy_fp or "")
except Exception:
  print("")
PY
      )"
    fi

    if [[ -z "$current_fp" ]]; then
      echo "WARN: not a git repo; cannot determine if examples are up-to-date." >&2
      needs_refresh=1
    elif ! result_is_complete; then
      needs_refresh=1
    elif [[ -n "$stored_fp" && "$stored_fp" == "$current_fp" ]]; then
      needs_refresh=0
    else
      # If meta is missing or doesn't match the current fingerprint, refresh.
      needs_refresh=1
    fi
  fi

  if [[ "$needs_refresh" -eq 1 ]]; then
    scripts/run_examples.sh -c "$config"
  else
    echo "OK: examples/result is up-to-date (fingerprint match)."
  fi
fi

uv run --project tools/example_eval example-eval evaluate --repo-root .
python3 scripts/example_eval_record.py --repo-root "$root_dir" --baseline-ref "$baseline_ref"

echo "OK: recorded under examples/eval_records/latest/"
echo "  - examples/eval_records/latest/agent_report.md"
echo "  - examples/eval_records/latest/delta_from_baseline.md"
