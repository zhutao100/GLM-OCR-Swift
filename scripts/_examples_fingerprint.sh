# Shared helper for determining whether `examples/result` is up-to-date for the
# current working tree state.
#
# This file is meant to be sourced by other scripts.

examples_fingerprint_paths=(
  Package.swift
  Package.resolved
  Sources
  scripts/run_examples.sh
  scripts/build_mlx_metallib.sh
  examples/source
)

examples_compute_fingerprint() {
  local head_sha relevant_diff untracked diff_hash

  head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$head_sha" ]]; then
    printf "\n"
    return 0
  fi

  relevant_diff="$(git diff HEAD -- "${examples_fingerprint_paths[@]}" 2>/dev/null || true)"
  untracked="$(git ls-files --others --exclude-standard -- "${examples_fingerprint_paths[@]}" 2>/dev/null || true)"

  diff_hash="$(
    { printf "%s\n" "$head_sha"; printf "%s\n" "$relevant_diff"; printf "%s\n" "$untracked" | LC_ALL=C sort; } \
      | shasum -a 256 \
      | awk '{print $1}'
  )"
  printf "%s\n" "$diff_hash"
}
