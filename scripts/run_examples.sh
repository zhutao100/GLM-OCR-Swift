#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Batch-run GLMOCRCLI over examples/source and write outputs to examples/result,
mirroring the folder layout of examples/reference_result.

Usage:
  scripts/run_examples.sh [-c debug|release] [--clean] [--glm-revision <rev>] [--layout-revision <rev>]

Options:
  -c, --configuration  SwiftPM build configuration (default: release)
  --clean              Remove examples/result before running
  --glm-model <id>     GLM-OCR HF model id (default: GLMOCRCLI default)
  --glm-revision <rev> GLM-OCR HF revision (branch/tag/commit) (default: GLMOCRCLI default)
  --layout-model <id>  Layout HF model id (default: GLMOCRCLI default)
  --layout-revision <rev> Layout HF revision (branch/tag/commit) (default: GLMOCRCLI default)
  --download-base <dir> Hub download base directory (default: HF hub cache)
  -h, --help           Show help

Notes:
  - Ensures mlx.metallib exists in the SwiftPM bin directory for the chosen -c profile.
  - PDFs default to OCR’ing all pages (use GLMOCRCLI --pages to restrict).
  - For deterministic parity/quality baselines, prefer pinned revisions (see docs/dev_plans/quality_parity/tracker.md).
EOF
}

config="release"
clean="0"
glm_model=""
glm_revision=""
layout_model=""
layout_revision=""
download_base=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      config="${2:-}"; shift 2 ;;
    --clean)
      clean="1"; shift ;;
    --glm-model)
      glm_model="${2:-}"; shift 2 ;;
    --glm-revision)
      glm_revision="${2:-}"; shift 2 ;;
    --layout-model)
      layout_model="${2:-}"; shift 2 ;;
    --layout-revision)
      layout_revision="${2:-}"; shift 2 ;;
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

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

src_dir="$root_dir/examples/source"
out_root="$root_dir/examples/result"

if [[ ! -d "$src_dir" ]]; then
  echo "Missing examples/source at: $src_dir" >&2
  exit 1
fi

if [[ "$clean" == "1" ]]; then
  rm -rf "$out_root"
fi
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

is_noisy_file() {
  local base
  base="$(basename "$1")"

  # common macOS/windows noise + hidden dotfiles
  [[ "$base" == ".DS_Store" ]] && return 0
  [[ "$base" == "Thumbs.db" ]] && return 0
  [[ "$base" == "desktop.ini" ]] && return 0
  [[ "$base" == "._"* ]] && return 0
  [[ "$base" == "."* ]] && return 0

  return 1
}

is_supported_input() {
  local p ext
  p="$1"
  ext="${p##*.}"
  ext="${ext,,}"

  case "$ext" in
    png|jpg|jpeg|pdf) return 0 ;;
    *) return 1 ;;
  esac
}

skipped=()
failed=()
succeeded=()

echo "==> Running examples from: $src_dir"
# shellcheck disable=SC2016
while IFS= read -r -d '' input_path; do
  if is_noisy_file "$input_path"; then
    continue
  fi
  if ! is_supported_input "$input_path"; then
    echo "skip (unsupported extension): $input_path" >&2
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
  echo "output: examples/result/$name"
  # Always run in layout mode so we can emit block-list JSON.
  # PDF layout auto-enables anyway; for images, --layout is required for --emit-json.
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

  if "$cli_path" "${cli_args[@]}" > "$md_out"; then
    succeeded+=("$base")
  else
    echo "ERROR: failed processing $base (continuing)" >&2
    failed+=("$base")
    # keep partial outputs if any were produced
  fi
done < <(find "$src_dir" -type f -print0)

echo "==== Summary ===="
echo "Succeeded: ${#succeeded[@]}"
echo "Skipped  : ${#skipped[@]}"
echo "Failed   : ${#failed[@]}"

if [[ ${#skipped[@]} -gt 0 ]]; then
  printf 'Skipped files:\n' >&2
  for f in "${skipped[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'Failed files:\n' >&2
  for f in "${failed[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
  exit 1
fi

echo "OK."
