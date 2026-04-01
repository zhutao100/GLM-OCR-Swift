# Development guide

This guide is for contributors and advanced users building from source. For the user-facing overview and basic usage, start with [README.md](../README.md).

## Prerequisites

- macOS 14+
- Swift 6 toolchain (Xcode 16+ recommended)
- Xcode Command Line Tools (or full Xcode)
- Apple Silicon recommended (MLX is optimized for Apple Silicon)
- (Optional) Python 3 for the example diffing/evaluation scripts under `scripts/`

## Build toolchains at a glance

This repo intentionally supports two build workflows:

- SwiftPM (`swift build` / `swift test` / `swift run`)
  - fastest iteration loop for development and tests
- Xcode/xcodebuild (`scripts/build.sh`)
  - production/release build path used by packaging smoke checks

Both workflows ultimately rely on the Metal compiler tools (`metal` / `metallib`) when building MLX shaders. If your machine does not have them, install the Metal toolchain component:

```bash
xcodebuild -downloadComponent MetalToolchain
```

`scripts/build.sh` will also attempt this download automatically when Metal tools are missing.

## Development builds and tests (SwiftPM)

```bash
swift build
swift test
```

Notes:

- `swift test` auto-prepares `mlx.metallib` when an MLX-backed test first needs it.
- Running SwiftPM-built executables (`swift run ...`) on a clean checkout can fail if `mlx.metallib` is missing. If you hit Metal/MLX shader load errors, prebuild the SwiftPM metallib first:

  ```bash
  scripts/build_mlx_metallib.sh -c debug
  ```

## Run locally

### CLI

```bash
scripts/build.sh
CLI=".build/xcode/Build/Products/Release/GLMOCRCLI"
"$CLI" --input examples/source/page.png > out.md
```

### App

```bash
swift run GLMOCRApp
```

The app is intentionally small: drag in one image or PDF, choose task/layout/page settings, then run OCR.

## Production builds (xcodebuild / packaged CLI path)

For a Release build via Xcode/xcodebuild (used by the repo’s packaging smoke checks):

```bash
scripts/build.sh
```

By default, `scripts/build.sh` builds all workspace schemes (libraries + the CLI/app executables). To build only a subset (for example just the CLI), set `SCHEMES`:

```bash
SCHEMES='GLMOCRCLI' scripts/build.sh
```

Useful environment overrides:

- `CONFIGURATION=Release` (default) or `CONFIGURATION=Debug`
- `DERIVED_DATA_PATH=.build/xcode` (default) to control output location
- `DESTINATION='platform=macOS,arch=<host>'` (default; set explicitly if you need to override)
- `SCHEMES='GLMOCRCLI'` to build only the CLI
- `SKIP_XCODE_PLUGIN_FINGERPRINT_BYPASS=1` to avoid writing Xcode defaults used for non-interactive package plugin builds

After a successful build, the binaries are under the derived data products directory (for example `"$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/GLMOCRCLI"`).

For distribution, also ship `default.metallib` next to the CLI binary. It is produced under the derived data products directory at:

- `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`

## Examples and evaluation tooling

This repo includes a checked-in example corpus under `examples/source/` and tooling to regenerate outputs and compare against baselines.

Regenerate the current outputs:

```bash
scripts/run_examples.sh
```

Report diffs against checked-in baselines:

```bash
python3 scripts/compare_examples.py --lane both
```

For scored evaluation, initialize the evaluator submodule first if needed:

```bash
git submodule update --init --recursive
scripts/verify_example_eval.sh
```

References:

- [examples/README.md](../examples/README.md) — example corpus ownership and output contract
- [examples/eval_records/README.md](../examples/eval_records/README.md) — scored evaluation record policy
- [tools/example_eval/README.md](../tools/example_eval/README.md) — evaluator usage and report outputs
- [docs/golden_checks.md](golden_checks.md) — opt-in parity and model-backed verification matrix

## Opt-in test lanes (model-backed)

By default, `swift test` stays lightweight. The heavier parity/integration lanes are opt-in via environment variables.

- `GLMOCR_RUN_GOLDEN=1` — enable GLM-OCR golden/parity integration tests
- `LAYOUT_RUN_GOLDEN=1` — enable PP-DocLayout-V3 golden/parity integration tests
- `GLMOCR_RUN_EXAMPLES=1` — enable the end-to-end examples parity integration lane
- `GLMOCR_TEST_RUN_FORWARD_PASS=1` — enable the GLM-OCR smoke forward-pass test
- `GLMOCR_TEST_RUN_GENERATE=1` — enable the GLM-OCR one-token generate smoke test

Snapshot-backed tests will prefer local snapshots when provided:

- `GLMOCR_SNAPSHOT_PATH`
- `LAYOUT_SNAPSHOT_PATH`

## Formatting

This repo uses `prek` (a `pre-commit`-compatible runner) with `.pre-commit-config.yaml`.

One-time setup:

```bash
brew install prek
git config core.hooksPath .githooks
prek prepare-hooks
```

The committed `.githooks/pre-commit` hook is a self-healing shim: it runs `prek run` on the staged set, auto-stages autofixes,
and retries until stable.

Manual runs:

```bash
prek run
prek run --all-files
```

Swift formatting is driven by `.swift-format` and the repo hook script `scripts/precommit_swift_format_autostage.sh`.
