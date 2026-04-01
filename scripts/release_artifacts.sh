#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<'USAGE'
Build and package all external-facing Release artifacts (CLI + App) in one shot.

Usage:
  scripts/release_artifacts.sh

Outputs (default):
  artifacts/release/<stamp>/
    - glmocr.macos.<arch>.zip      (GLMOCRCLI + default.metallib)
    - glmocrapp.macos.<arch>.zip   (GLMOCRApp + default.metallib)
    - SHA256SUMS.txt
    - logs/

Environment:
  CONFIGURATION   Xcode configuration (default: Release)
  DERIVED_DATA_PATH  Xcode derived data output directory (default: .build/xcode)
  OUT_DIR         Output directory root (default: artifacts/release)
  STAMP           Output subdir name (default: YYYY-MM-DD_HH-MM-SS)
  SCHEMES         Schemes to build via scripts/build.sh (default: 'GLMOCRCLI GLMOCRApp')
  SKIP_VERIFY     Set to 1 to skip scripts/verify_fast.sh
  SKIP_BUILD      Set to 1 to skip scripts/build.sh (package from existing build products)
  VERBOSE         Set to 1 to stream command output (default: 0)

Examples:
  scripts/release_artifacts.sh
  OUT_DIR=./dist-artifacts STAMP=nightly SKIP_VERIFY=1 scripts/release_artifacts.sh
  SCHEMES='GLMOCRCLI' scripts/release_artifacts.sh
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

run_logged() {
  local log_file="${1}"
  shift

  if [[ "${VERBOSE:-0}" == "1" ]]; then
    "$@" 2>&1 | tee "${log_file}"
    return "${PIPESTATUS[0]}"
  fi

  "$@" >"${log_file}" 2>&1
}

dump_log_tail() {
  local log_file="${1}"
  local lines="${2:-200}"

  [[ -f "${log_file}" ]] || return 0
  echo "[release_artifacts] --- ${log_file} (tail) ---"
  tail -n "${lines}" "${log_file}" || true
}

copy_resource_bundles() {
  local src_dir="${1}"
  local dest_dir="${2}"

  shopt -s nullglob
  local bundle
  for bundle in "${src_dir}"/*.bundle; do
    [[ -d "${bundle}" ]] || continue
    cp -R "${bundle}" "${dest_dir}/"
  done
}

package_artifacts() {
  set -Eeuo pipefail

  [[ -f "${cli_src}" ]] || { echo "missing GLMOCRCLI at: ${cli_src}" >&2; return 1; }
  [[ -f "${app_src}" ]] || { echo "missing GLMOCRApp at: ${app_src}" >&2; return 1; }
  [[ -f "${metallib_src}" ]] || { echo "missing default.metallib at: ${metallib_src}" >&2; return 1; }

  cp "${cli_src}" "${cli_stage}/GLMOCRCLI"
  chmod +x "${cli_stage}/GLMOCRCLI"
  cp "${metallib_src}" "${cli_stage}/default.metallib"
  copy_resource_bundles "${products_dir}" "${cli_stage}"
  "${cli_stage}/GLMOCRCLI" --help >"${out_dir}/glmocrcli-help.txt" 2>"${out_dir}/glmocrcli-help.err" || true

  cp "${app_src}" "${app_stage}/GLMOCRApp"
  chmod +x "${app_stage}/GLMOCRApp"
  cp "${metallib_src}" "${app_stage}/default.metallib"
  copy_resource_bundles "${products_dir}" "${app_stage}"

  shopt -s nullglob
  local -a cli_payload=(GLMOCRCLI default.metallib)
  local item
  pushd "${cli_stage}" >/dev/null
  for item in *.bundle; do
    cli_payload+=("${item}")
  done
  zip -qr "${cli_zip}" "${cli_payload[@]}"
  popd >/dev/null

  local -a app_payload=(GLMOCRApp default.metallib)
  pushd "${app_stage}" >/dev/null
  for item in *.bundle; do
    app_payload+=("${item}")
  done
  zip -qr "${app_zip}" "${app_payload[@]}"
  popd >/dev/null

  (cd "${out_dir}" && shasum -a 256 "$(basename "${cli_zip}")" "$(basename "${app_zip}")" > SHA256SUMS.txt)
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root_dir"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build/xcode}"
OUT_DIR="${OUT_DIR:-artifacts/release}"
STAMP="${STAMP:-$(date +'%Y-%m-%d_%H-%M-%S')}"
SCHEMES="${SCHEMES:-GLMOCRCLI GLMOCRApp}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
VERBOSE="${VERBOSE:-0}"

arch="$(uname -m)"
out_dir="${OUT_DIR}/${STAMP}"
log_dir="${out_dir}/logs"
mkdir -p "${log_dir}"
out_dir="$(cd "${out_dir}" && pwd -P)"
log_dir="${out_dir}/logs"

verify_log="${log_dir}/verify_fast.log"
build_log="${log_dir}/xcodebuild_release.log"
package_log="${log_dir}/package.log"

log "==> Packaging stamp: ${STAMP}"
log "==> Output directory: ${out_dir}"
log "==> Host arch: ${arch}"

if [[ "${SKIP_VERIFY}" != "1" ]]; then
  log "==> Running fast verification (SwiftPM): scripts/verify_fast.sh"
  if ! run_logged "${verify_log}" ./scripts/verify_fast.sh; then
    warn "Verification failed (log: ${verify_log})"
    if [[ "${VERBOSE}" != "1" ]]; then
      dump_log_tail "${verify_log}"
    fi
    exit 1
  fi
else
  log "==> Skipping verification (SKIP_VERIFY=1)"
fi

if [[ "${SKIP_BUILD}" != "1" ]]; then
  log "==> Building release products via scripts/build.sh"
  if ! run_logged "${build_log}" env \
    CONFIGURATION="${CONFIGURATION}" \
    DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
    SCHEMES="${SCHEMES}" \
    ./scripts/build.sh -quiet; then
    warn "Release build failed (log: ${build_log})"
    if [[ "${VERBOSE}" != "1" ]]; then
      dump_log_tail "${build_log}"
    fi
    exit 1
  fi
else
  log "==> Skipping build (SKIP_BUILD=1)"
fi

products_dir="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
cli_src="${products_dir}/GLMOCRCLI"
app_src="${products_dir}/GLMOCRApp"
metallib_src="${products_dir}/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"

[[ -d "${products_dir}" ]] || die "Expected build products directory not found: ${products_dir}"

cli_zip="${out_dir}/glmocr.macos.${arch}.zip"
app_zip="${out_dir}/glmocrapp.macos.${arch}.zip"

cli_stage="$(mktemp -d "${TMPDIR:-/tmp}/glmocr-cli-stage.XXXXXX")"
app_stage="$(mktemp -d "${TMPDIR:-/tmp}/glmocr-app-stage.XXXXXX")"
cleanup() {
  rm -rf "${cli_stage}" 2>/dev/null || true
  rm -rf "${app_stage}" 2>/dev/null || true
}
trap cleanup EXIT

log "==> Packaging artifacts"
if ! run_logged "${package_log}" package_artifacts; then
  warn "Packaging failed (log: ${package_log})"
  if [[ "${VERBOSE}" != "1" ]]; then
    dump_log_tail "${package_log}"
  fi
  exit 1
fi

log "==> Done"
log "  - ${cli_zip}"
log "  - ${app_zip}"
log "  - ${out_dir}/SHA256SUMS.txt"
