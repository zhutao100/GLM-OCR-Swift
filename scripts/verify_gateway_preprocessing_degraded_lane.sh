#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build and score the synthetic degraded-input lane used by the gateway-preprocessing tracker.

Steps:
  1) Generate the degraded lane repo under .build/gateway_preprocessing/degraded_lane_repo/
  2) Run GLMOCRCLI over the lane's examples/source into examples/result
  3) Run tools/example_eval against the lane and write reports under .build/gateway_preprocessing/degraded_lane_eval/<label>/

Usage:
  scripts/verify_gateway_preprocessing_degraded_lane.sh [-c debug|release] [--label <name>] [--baseline-label <name>] [--clean-lane]
    [--glm-model <id>] [--glm-revision <rev>] [--layout-model <id>] [--layout-revision <rev>]
    [--generation-preset <name>] [--download-base <dir>]
EOF
}

config="release"
label="current"
baseline_label=""
clean_lane="0"

glm_model=""
glm_revision=""
layout_model=""
layout_revision=""
generation_preset=""
download_base=""

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root_dir/scripts/_parity_defaults.sh"

glm_model="$PARITY_GLM_MODEL_ID"
glm_revision="$PARITY_GLM_REVISION"
layout_model="$PARITY_LAYOUT_MODEL_ID"
layout_revision="$PARITY_LAYOUT_REVISION"
generation_preset="$PARITY_GENERATION_PRESET"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      config="${2:-}"; shift 2 ;;
    --label)
      label="${2:-}"; shift 2 ;;
    --baseline-label)
      baseline_label="${2:-}"; shift 2 ;;
    --clean-lane)
      clean_lane="1"; shift ;;
    --glm-model)
      glm_model="${2:-}"; shift 2 ;;
    --glm-revision)
      glm_revision="${2:-}"; shift 2 ;;
    --layout-model)
      layout_model="${2:-}"; shift 2 ;;
    --layout-revision)
      layout_revision="${2:-}"; shift 2 ;;
    --generation-preset)
      generation_preset="${2:-}"; shift 2 ;;
    --download-base)
      download_base="${2:-}"; shift 2 ;;
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

lane_root="$root_dir/.build/gateway_preprocessing/degraded_lane_repo"
eval_out_dir="$root_dir/.build/gateway_preprocessing/degraded_lane_eval/$label"

if [[ "$clean_lane" == "1" ]]; then
  rm -rf "$lane_root"
fi

echo "==> Generating degraded lane repo…"
PYENV_VERSION=venv313 pyenv exec python3 \
  "$root_dir/scripts/gateway_preprocessing_generate_degraded_lane.py" \
  --repo-root "$root_dir" \
  --out-root "$lane_root"

src_dir="$lane_root/examples/source"
out_root="$lane_root/examples/result"

if [[ ! -d "$src_dir" ]]; then
  echo "Missing lane examples/source at: $src_dir" >&2
  exit 1
fi

rm -rf "$out_root"
mkdir -p "$out_root"

echo "==> Building GLMOCRCLI (-c $config)…"
swift build -c "$config" --product GLMOCRCLI

bin_path="$(swift build -c "$config" --show-bin-path)"
cli_path="$bin_path/GLMOCRCLI"
metallib_path="$bin_path/mlx.metallib"

if [[ ! -x "$cli_path" ]]; then
  echo "GLMOCRCLI not found/executable at: $cli_path" >&2
  exit 1
fi

if [[ ! -f "$metallib_path" ]]; then
  echo "==> mlx.metallib missing for -c $config; building…"
  "$root_dir/scripts/build_mlx_metallib.sh" -c "$config"
else
  echo "==> Found mlx.metallib: $metallib_path"
fi

is_supported_input() {
  local p ext
  p="$1"
  ext="${p##*.}"
  ext="${ext,,}"

  case "$ext" in
    png|jpg|jpeg) return 0 ;;
    *) return 1 ;;
  esac
}

failed=()
succeeded=()
started_at_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "==> Running degraded lane from: $src_dir"
echo "==> Parity contract: glm=$glm_model@$glm_revision layout=$layout_model@$layout_revision preset=$generation_preset"

while IFS= read -r -d '' input_path; do
  if ! is_supported_input "$input_path"; then
    continue
  fi

  base="$(basename "$input_path")"
  name="${base%.*}"

  out_dir="$out_root/$name"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  md_out="$out_dir/$name.md"
  json_out="$out_dir/$name.json"

  echo "----"
  echo "input : $base"
  echo "output: .build/gateway_preprocessing/degraded_lane_repo/examples/result/$name"

  cli_args=(--layout --input "$input_path" --emit-json "$json_out")
  if [[ -n "$glm_model" ]]; then
    cli_args+=(--model "$glm_model")
  fi
  if [[ -n "$glm_revision" ]]; then
    cli_args+=(--revision "$glm_revision")
  fi
  if [[ -n "$layout_model" ]]; then
    cli_args+=(--layout-model "$layout_model")
  fi
  if [[ -n "$layout_revision" ]]; then
    cli_args+=(--layout-revision "$layout_revision")
  fi
  if [[ -n "$download_base" ]]; then
    cli_args+=(--download-base "$download_base")
  fi
  if [[ -n "$generation_preset" ]]; then
    cli_args+=(--generation-preset "$generation_preset")
  fi

  if "$cli_path" "${cli_args[@]}" > "$md_out"; then
    succeeded+=("$base")
  else
    echo "ERROR: failed processing $base (continuing)" >&2
    failed+=("$base")
  fi
done < <(find "$src_dir" -type f -print0)

echo "==== OCR run summary ===="
echo "Succeeded: ${#succeeded[@]}"
echo "Failed   : ${#failed[@]}"

if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'Failed files:\n' >&2
  for f in "${failed[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
  exit 1
fi

if [[ ! -f tools/example_eval/pyproject.toml ]]; then
  echo "Missing tools/example_eval submodule. Run:" >&2
  echo "  git submodule update --init --recursive" >&2
  exit 1
fi

echo "==> Scoring degraded lane…"
uv run --project "$root_dir/tools/example_eval" example-eval evaluate --repo-root "$lane_root" --out-dir "$eval_out_dir"

echo "==> Aggregating by defect family…"
python3 "$root_dir/scripts/gateway_preprocessing_summarize_degraded_lane_eval.py" \
  --lane-root "$lane_root" \
  --summary-json "$eval_out_dir/summary.json" \
  --out-md "$eval_out_dir/degraded_lane_summary.md"

if [[ -n "$baseline_label" ]]; then
  baseline_summary="$root_dir/.build/gateway_preprocessing/degraded_lane_eval/$baseline_label/summary.json"
  if [[ ! -f "$baseline_summary" ]]; then
    echo "Missing baseline summary.json: $baseline_summary" >&2
    exit 1
  fi
  python3 "$root_dir/scripts/gateway_preprocessing_summarize_degraded_lane_eval.py" \
    --lane-root "$lane_root" \
    --summary-json "$eval_out_dir/summary.json" \
    --baseline-summary-json "$baseline_summary" \
    --out-md "$eval_out_dir/degraded_lane_delta_from_${baseline_label}.md"
fi

echo "==> Writing run metadata…"
LABEL="$label" \
BASELINE_LABEL="$baseline_label" \
STARTED_AT_UTC="$started_at_utc" \
CONFIGURATION="$config" \
LANE_ROOT="$lane_root" \
EVAL_OUT_DIR="$eval_out_dir" \
GLM_MODEL="$glm_model" \
GLM_REVISION="$glm_revision" \
LAYOUT_MODEL="$layout_model" \
LAYOUT_REVISION="$layout_revision" \
GENERATION_PRESET="$generation_preset" \
DOWNLOAD_BASE="$download_base" \
python3 - <<'PY'
import json
import os
from pathlib import Path

out_dir = Path(os.environ["EVAL_OUT_DIR"])
out_dir.mkdir(parents=True, exist_ok=True)

meta = {
  "label": os.environ["LABEL"],
  "baseline_label": os.environ.get("BASELINE_LABEL") or None,
  "started_at_utc": os.environ["STARTED_AT_UTC"],
  "ended_at_utc": __import__("datetime").datetime.now(__import__("datetime").UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
  "configuration": os.environ["CONFIGURATION"],
  "lane_root": os.environ["LANE_ROOT"],
  "glm_model": os.environ["GLM_MODEL"],
  "glm_revision": os.environ["GLM_REVISION"],
  "layout_model": os.environ["LAYOUT_MODEL"],
  "layout_revision": os.environ["LAYOUT_REVISION"],
  "generation_preset": os.environ["GENERATION_PRESET"],
  "download_base": os.environ["DOWNLOAD_BASE"],
  "gateway_env": {k: v for k, v in os.environ.items() if k.startswith("GLMOCR_GATEWAY_") or k.startswith("VLM_GATEWAY_")},
}

(out_dir / "run_meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "OK: wrote reports under: $eval_out_dir"
echo "  - $eval_out_dir/summary.md"
echo "  - $eval_out_dir/degraded_lane_summary.md"
echo "  - $eval_out_dir/run_meta.json"
