#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<'USAGE'
Release-build wrapper for building the Swift package via xcodebuild.

Usage:
  scripts/build.sh [xcodebuild args...]

Defaults:
  CONFIGURATION=Release
  DERIVED_DATA_PATH=.build/xcode
  DESTINATION='platform=macOS,arch=<host>'
  SCHEMES=(auto-detected)

This script ensures that the Xcode toolchain and Metal compiler tools are available.
If the Metal toolchain is missing, it will attempt to install it with:

  xcodebuild -downloadComponent MetalToolchain

Environment:
  CONFIGURATION                 Xcode configuration (Release or Debug)
  DERIVED_DATA_PATH             DerivedData output directory
  DESTINATION                   xcodebuild destination (default: platform=macOS,arch=<host>)
  SCHEMES                        Space-separated list of schemes to build (defaults to all workspace schemes except "*-Package")
  SKIP_METAL_TOOLCHAIN_DOWNLOAD Set to 1 to disable auto-download attempts
  SKIP_XCODE_PLUGIN_FINGERPRINT_BYPASS Set to 1 to avoid writing the Xcode defaults used for non-interactive package plugin builds

Examples:
  scripts/build.sh
  CONFIGURATION=Debug scripts/build.sh
  DERIVED_DATA_PATH=./dist scripts/build.sh
  SCHEMES='GLMOCRCLI' scripts/build.sh
  DESTINATION='platform=macOS,arch=arm64' scripts/build.sh
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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    die "scripts/build.sh only supports macOS (xcodebuild + Metal toolchain required)"
  fi
}

ensure_xcode_tools() {
  command_exists xcodebuild || die "xcodebuild not found. Install Xcode (preferred) or Xcode Command Line Tools."
  command_exists xcrun || die "xcrun not found. Install Xcode Command Line Tools."
  command_exists xcode-select || die "xcode-select not found. Install Xcode Command Line Tools."

  local developer_dir=""
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$developer_dir" || ! -d "$developer_dir" ]]; then
    die "Xcode toolchain is not configured. Run `xcode-select --install`, or switch to Xcode via `sudo xcode-select --switch /Applications/Xcode.app`."
  fi

  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    warn "Xcode first-launch tasks are incomplete. If builds fail, run: sudo xcodebuild -runFirstLaunch"
  fi
}

ensure_xcode_package_plugin_settings() {
  if [[ "${SKIP_XCODE_PLUGIN_FINGERPRINT_BYPASS:-0}" == "1" ]]; then
    return 0
  fi
  if ! command_exists defaults; then
    warn "defaults not found; skipping Xcode package plugin fingerprint bypass"
    return 0
  fi

  local current=""
  current="$(defaults read com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation 2>/dev/null || true)"
  case "$current" in
    1|YES|true|TRUE) return 0 ;;
    *) ;;
  esac

  warn "Enabling non-interactive SwiftPM build tool plugins for xcodebuild (Xcode default: IDESkipPackagePluginFingerprintValidation=YES)"
  defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES >/dev/null 2>&1 || true
}

ensure_metal_toolchain() {
  local metal_path=""
  local metallib_path=""

  metal_path="$(xcrun -sdk macosx -f metal 2>/dev/null || true)"
  metallib_path="$(xcrun -sdk macosx -f metallib 2>/dev/null || true)"
  if [[ -n "$metal_path" && -n "$metallib_path" ]]; then
    return 0
  fi

  if [[ "${SKIP_METAL_TOOLCHAIN_DOWNLOAD:-0}" == "1" ]]; then
    die "Metal toolchain tools (metal/metallib) not found. Install the Metal toolchain component (see `xcodebuild -downloadComponent MetalToolchain`)."
  fi

  warn "Metal toolchain tools (metal/metallib) not found; attempting to download MetalToolchain component..."
  if ! xcodebuild -downloadComponent MetalToolchain; then
    die "Failed to download MetalToolchain. Ensure Xcode 15+ is installed, Xcode license is accepted, and try again."
  fi

  metal_path="$(xcrun -sdk macosx -f metal 2>/dev/null || true)"
  metallib_path="$(xcrun -sdk macosx -f metallib 2>/dev/null || true)"
  if [[ -z "$metal_path" || -z "$metallib_path" ]]; then
    die "MetalToolchain download did not make metal/metallib available via xcrun. Try selecting Xcode via `sudo xcode-select --switch /Applications/Xcode.app` and retry."
  fi
}

discover_schemes() {
  if ! command_exists plutil; then
    die "plutil not found; unable to discover xcodebuild schemes automatically"
  fi
  xcodebuild -list -json 2>/dev/null \
    | plutil -extract workspace.schemes xml1 -o - - 2>/dev/null \
    | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
configuration="${CONFIGURATION:-Release}"
derived_data_path="${DERIVED_DATA_PATH:-.build/xcode}"
host_arch="$(uname -m)"
destination="${DESTINATION:-platform=macOS,arch=$host_arch}"

cd "$root_dir"
ensure_macos
ensure_xcode_tools
ensure_xcode_package_plugin_settings
ensure_metal_toolchain

schemes=()
if [[ -n "${SCHEMES:-}" ]]; then
  while IFS= read -r scheme; do
    [[ -n "$scheme" ]] || continue
    schemes+=("$scheme")
  done < <(printf '%s\n' "$SCHEMES" | tr -s '[:space:]' '\n')
else
  discovered_schemes="$(discover_schemes || true)"
  if [[ -z "$discovered_schemes" ]]; then
    die "Failed to auto-discover xcodebuild schemes. Try running `xcodebuild -list -json` manually, or set SCHEMES='GLMOCRCLI GLMOCRApp ...'."
  fi
  while IFS= read -r scheme; do
    [[ -n "$scheme" ]] || continue
    [[ "$scheme" == *"-Package" ]] && continue
    schemes+=("$scheme")
  done <<<"$discovered_schemes"
fi

if [[ ${#schemes[@]} -eq 0 ]]; then
  die "No schemes selected to build"
fi

log "==> Selected schemes:"
for scheme in "${schemes[@]}"; do
  log "  - $scheme"
done

for scheme in "${schemes[@]}"; do
  log "==> Building $scheme ($configuration) via xcodebuild"
  xcodebuild build \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "$destination" \
    -derivedDataPath "$derived_data_path" \
    -skipPackagePluginValidation \
    ENABLE_PLUGIN_PREPAREMLSHADERS=YES \
    CLANG_COVERAGE_MAPPING=NO \
    "$@"
done
