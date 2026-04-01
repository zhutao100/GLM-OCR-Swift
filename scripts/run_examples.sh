#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Batch-run GLMOCRCLI over examples/source and write outputs to examples/result,
mirroring the folder layout of examples/reference_result.

Usage:
  scripts/run_examples.sh [-c debug|release] [--clean] [--generation-preset <name>] [--glm-revision <rev>] [--layout-revision <rev>]

Options:
  -c, --configuration  SwiftPM build configuration (default: release)
  --clean              Remove examples/result before running
  --generation-preset <name>
                      Applied and recorded parity generation preset (default: parity-greedy-v1)
  --glm-model <id>     GLM-OCR HF model id (default: pinned parity contract)
  --glm-revision <rev> GLM-OCR HF revision (branch/tag/commit) (default: pinned parity contract)
  --layout-model <id>  Layout HF model id (default: pinned parity contract)
  --layout-revision <rev> Layout HF revision (branch/tag/commit) (default: pinned parity contract)
  --download-base <dir> Hub download base directory (default: HF hub cache)
  -h, --help           Show help

Notes:
  - Ensures mlx.metallib exists in the SwiftPM bin directory for the chosen -c profile.
  - PDFs default to OCR’ing all pages (use GLMOCRCLI --pages to restrict).
  - The defaults come from the checked-in parity contract in `scripts/lib/_parity_defaults.sh`.
EOF
}

config="release"
clean="0"
glm_model=""
glm_revision=""
layout_model=""
layout_revision=""
generation_preset=""
download_base=""

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root_dir/scripts/lib/_parity_defaults.sh"

glm_model="$PARITY_GLM_MODEL_ID"
glm_revision="$PARITY_GLM_REVISION"
layout_model="$PARITY_LAYOUT_MODEL_ID"
layout_revision="$PARITY_LAYOUT_REVISION"
generation_preset="$PARITY_GENERATION_PRESET"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      config="${2:-}"; shift 2 ;;
    --clean)
      clean="1"; shift ;;
    --generation-preset)
      generation_preset="${2:-}"; shift 2 ;;
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

case "$generation_preset" in
  parity-greedy-v1) ;;
  *)
    echo "Unsupported --generation-preset: $generation_preset" >&2
    echo "Supported presets: parity-greedy-v1" >&2
    exit 2 ;;
esac

cd "$root_dir"

. "$root_dir/scripts/lib/_examples_fingerprint.sh"

src_dir="$root_dir/examples/source"
out_root="$root_dir/examples/result"
meta_path="$out_root/.run_examples_meta.json"

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
started_at_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

git_head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
git_describe="$(git describe --always --dirty --broken 2>/dev/null || true)"
git_dirty=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    git_dirty="true"
  else
    git_dirty="false"
  fi
fi

write_run_meta() {
  local status ended_at_utc fingerprint
  status="$1"
  ended_at_utc="$2"
  fingerprint="$(examples_compute_fingerprint)"

  local -a meta_args
  meta_args=(
    --meta-path "$meta_path"
    --status "$status"
    --configuration "$config"
    --fingerprint-sha256 "$fingerprint"
    --git-head-sha "$git_head_sha"
    --git-describe "$git_describe"
    --git-dirty "$git_dirty"
    --glm-model "$glm_model"
    --glm-revision "$glm_revision"
    --layout-model "$layout_model"
    --layout-revision "$layout_revision"
    --generation-preset "$generation_preset"
    --download-base "$download_base"
    --started-at-utc "$started_at_utc"
    --ended-at-utc "$ended_at_utc"
  )

  local f
  for f in "${succeeded[@]}"; do
    meta_args+=(--succeeded "$f")
  done
  for f in "${failed[@]}"; do
    meta_args+=(--failed "$f")
  done
  for f in "${skipped[@]}"; do
    meta_args+=(--skipped "$f")
  done

  python3 "$root_dir/scripts/python/write_run_examples_meta.py" "${meta_args[@]}"
}

echo "==> Running examples from: $src_dir"
echo "==> Parity contract: glm=$glm_model@$glm_revision layout=$layout_model@$layout_revision preset=$generation_preset"
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
  if [[ -n "$generation_preset" ]]; then
    cli_args+=(--generation-preset "$generation_preset")
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
  write_run_meta failed "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  exit 1
fi

write_run_meta ok "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "OK."
