#!/usr/bin/env bash
set -euo pipefail

# Tier 0: mandatory fast verifier after every edit.
#
# Supports two modes:
# - SwiftPM mode (default): uses `swift build` / `swift test`
# - Xcode mode: if PROJECT_OR_WORKSPACE points to an existing .xcodeproj/.xcworkspace
#
# Artifacts:
#   artifacts/logs/build.log
#   artifacts/logs/test.log (when tests run)
#
# Verbosity:
#   VERBOSE=1   stream tool output (default is low-noise)

mkdir -p artifacts/logs

PROJECT_OR_WORKSPACE="${PROJECT_OR_WORKSPACE:-}"
SCHEME="${SCHEME:-}"
DESTINATION="${DESTINATION:-platform=macOS}"
CONFIGURATION="${CONFIGURATION:-Debug}"
VERBOSE="${VERBOSE:-0}"

maybe_enable_swiftpm_sandbox_ci_compat() {
  # The in-process Seatbelt sandbox denies all writes outside the repo workspace.
  # On GitHub Actions (and some other CI environments), Apple toolchains commonly
  # need to write caches under `/var/folders/...` (e.g., clang module cache, `xcrun` db).
  #
  # Keep local defaults strict, but enable the compat allowlist on CI unless the
  # caller explicitly set `SWIFTPM_SANDBOX_ALLOW_SYSTEM_TMP`.
  if [[ "${CI:-}" == "true" || "${CI:-}" == "1" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if [[ -z "${SWIFTPM_SANDBOX_ALLOW_SYSTEM_TMP:-}" ]]; then
      export SWIFTPM_SANDBOX_ALLOW_SYSTEM_TMP=1
      echo "[verify_fast] CI compat: SWIFTPM_SANDBOX_ALLOW_SYSTEM_TMP=1"
    fi
  fi
}

maybe_enable_swiftpm_sandbox_ci_compat

run_logged() {
  local log_file="${1}"
  shift

  if [[ "${VERBOSE}" == "1" ]]; then
    "$@" 2>&1 | tee "${log_file}"
    return "${PIPESTATUS[0]}"
  fi

  "$@" >"${log_file}" 2>&1
}

dump_log_tail() {
  local log_file="${1}"
  local lines="${2:-200}"

  [[ -f "${log_file}" ]] || return 0
  echo "[verify_fast] --- ${log_file} (tail) ---"
  tail -n "${lines}" "${log_file}" || true
}

require_swift_6() {
  local -a swiftc_cmd=()
  if command -v swiftc >/dev/null 2>&1; then
    swiftc_cmd=(swiftc)
  elif command -v xcrun >/dev/null 2>&1; then
    swiftc_cmd=(xcrun swiftc)
  else
    echo "error: swiftc not found (no swiftc in PATH, and xcrun unavailable)." >&2
    exit 2
  fi

  local version_line
  version_line="$("${swiftc_cmd[@]}" -version 2>/dev/null | head -n 1 || true)"
  if [[ -z "${version_line}" ]]; then
    echo "error: swiftc -version returned no output." >&2
    exit 2
  fi

  local major
  if [[ "${version_line}" =~ ([Aa]pple[[:space:]]+)?Swift[[:space:]]+version[[:space:]]+([0-9]+)\. ]]; then
    major="${BASH_REMATCH[2]}"
  else
    echo "error: could not parse Swift version from: ${version_line}" >&2
    exit 2
  fi

  if ((major < 6)); then
    echo "error: Swift 6+ required. Found: ${version_line}" >&2
    exit 2
  fi

  echo "[verify_fast] Toolchain: ${version_line}"
}

require_swift_6

if [[ -n "${PROJECT_OR_WORKSPACE}" && -e "${PROJECT_OR_WORKSPACE}" ]]; then
  # Xcode mode
  echo "[verify_fast] Xcode mode: ${PROJECT_OR_WORKSPACE}"
  if [[ -z "${SCHEME}" ]]; then
    echo "SCHEME must be set in Xcode mode (e.g., export SCHEME=CodexMac)" >&2
    exit 2
  fi

  local_build_args=()
  if [[ "${PROJECT_OR_WORKSPACE}" == *.xcworkspace ]]; then
    local_build_args+=( -workspace "${PROJECT_OR_WORKSPACE}" )
  else
    local_build_args+=( -project "${PROJECT_OR_WORKSPACE}" )
  fi

  echo "[verify_fast] Building (log: artifacts/logs/build.log)..."
  if ! run_logged "artifacts/logs/build.log" \
    xcodebuild \
      "${local_build_args[@]}" \
      -scheme "${SCHEME}" \
      -configuration "${CONFIGURATION}" \
      -destination "${DESTINATION}" \
      build; then
    echo "[verify_fast] Build failed (log: artifacts/logs/build.log)." >&2
    if [[ "${VERBOSE}" != "1" ]]; then
      dump_log_tail "artifacts/logs/build.log"
    fi
    exit 1
  fi

  echo "[verify_fast] Running unit tests (optional; disable via RUN_TESTS=0)..."
  if [[ "${RUN_TESTS:-1}" == "1" ]]; then
    echo "[verify_fast] Testing (log: artifacts/logs/test.log)..."
    if ! run_logged "artifacts/logs/test.log" \
      xcodebuild \
        "${local_build_args[@]}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination "${DESTINATION}" \
        test \
        -resultBundlePath "artifacts/TestResults.xcresult"; then
      echo "[verify_fast] Tests failed (log: artifacts/logs/test.log)." >&2
      if [[ "${VERBOSE}" != "1" ]]; then
        dump_log_tail "artifacts/logs/test.log"
      fi
      exit 1
    fi
  fi

  echo "[verify_fast] PASS"
  exit 0
fi

# SwiftPM mode
echo "[verify_fast] SwiftPM mode"
echo "[verify_fast] swift build (log: artifacts/logs/build.log)..."
if [[ "${RUN_TESTS:-1}" == "1" ]]; then
  if ! run_logged "artifacts/logs/build.log" swift build --build-tests; then
    echo "[verify_fast] Build failed (log: artifacts/logs/build.log)." >&2
    if [[ "${VERBOSE}" != "1" ]]; then
      dump_log_tail "artifacts/logs/build.log"
    fi
    exit 1
  fi

  echo "[verify_fast] swift test (log: artifacts/logs/test.log)..."
  if ! run_logged "artifacts/logs/test.log" swift test --skip-build; then
    echo "[verify_fast] Tests failed (log: artifacts/logs/test.log)." >&2
    if [[ "${VERBOSE}" != "1" ]]; then
      dump_log_tail "artifacts/logs/test.log"
    fi
    exit 1
  fi
else
  if ! run_logged "artifacts/logs/build.log" swift build; then
    echo "[verify_fast] Build failed (log: artifacts/logs/build.log)." >&2
    if [[ "${VERBOSE}" != "1" ]]; then
      dump_log_tail "artifacts/logs/build.log"
    fi
    exit 1
  fi
fi

echo "[verify_fast] PASS"
