# GLM-OCR Swift

Native macOS GLM-OCR in Swift with local MLX inference. The project turns images and PDFs into Markdown, and can optionally run a layout stage first so the output also includes structured region data.

The repo is intentionally split into a model-agnostic runtime plus adapters:

- `Sources/VLMRuntimeKit/` - shared runtime primitives
- `Sources/ModelAdapters/DocLayout/` - PP-DocLayout-V3 layout detection
- `Sources/ModelAdapters/GLMOCR/` - GLM-OCR model glue and orchestration
- `Sources/GLMOCRCLI/` - CLI entrypoint
- `Sources/GLMOCRApp/` - SwiftUI app scaffold

See `docs/architecture.md` for the current module boundaries and dataflow.

## Current State (verified 2026-03-11)

- `swift test` passes.
- `swift run GLMOCRCLI --help` works.
- `scripts/build.sh` builds the packaged CLI release path.
- `scripts/build_mlx_metallib.sh -c debug` builds the runtime Metal library.
- MLX-backed SwiftPM tests auto-prepare `mlx.metallib` on demand.
- The repo has checked-in CI for `swift test` plus nightly CLI packaging smoke checks.
- End-to-end OCR works locally for images and PDFs through the CLI.
- Layout mode works for images and PDFs:
  - PP-DocLayout-V3 detection
  - per-region GLM-OCR
  - merged Markdown
  - optional block-list JSON and `OCRDocument` JSON exports
- The SwiftUI app can load one image or PDF, run OCR, and show Markdown output.
- The repo includes an examples corpus plus diff/evaluation tooling under `examples/`, `scripts/`, and `tools/example_eval/`.

## Supported Workflows

- Single image OCR to Markdown
- Single-page or multi-page PDF OCR to Markdown
- Layout-aware OCR with JSON export
- Batch example generation with `scripts/run_examples.sh`
- Example diffing with `scripts/compare_examples.py`
- Scored evaluation and persistent run records with `tools/example_eval/` and `scripts/verify_example_eval.sh`

## Quickstart

### Prerequisites

- macOS 14+
- Xcode 16+ or another Swift 6 toolchain
- Xcode Command Line Tools
- Apple Silicon is strongly recommended

### Package Build and Smoke Test

```bash
swift build
swift test
swift run GLMOCRCLI --help
```

`swift test` now prepares the SwiftPM `mlx.metallib` automatically when an MLX-backed test first needs it.

If you want to run MLX-backed SwiftPM executables directly from `.build`, prebuild the Metal library with:

```bash
scripts/build_mlx_metallib.sh -c debug
```

If you remove `.build` or switch between `debug` and `release`, rebuild `mlx.metallib` for that configuration before running those executables directly.

### Scripted Release Build

Use the repo build wrapper for the packaged CLI path:

```bash
scripts/build.sh
DERIVED_DATA_PATH=./dist ./scripts/build.sh
```

Equivalent explicit command:

```bash
xcodebuild build -scheme GLMOCRCLI -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode -skipPackagePluginValidation ENABLE_PLUGIN_PREPAREMLSHADERS=YES CLANG_COVERAGE_MAPPING=NO
```

CI uses the same script and smoke-runs `GLMOCRCLI --help` from the release products after copying `default.metallib` next to the binary.

### Run OCR

```bash
# Image -> Markdown
swift run GLMOCRCLI --input examples/source/page.png > out.md

# PDF -> Markdown (all pages by default)
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Page_1.pdf --pages 1 > out.md

# Layout mode with both JSON export formats
swift run GLMOCRCLI --layout --input examples/source/page.png \
  --emit-json out.json \
  --emit-ocrdocument-json out.ocrdocument.json > out.md
```

The first run may download missing Hugging Face snapshot files into the local cache.

### Launch the App

```bash
swift run GLMOCRApp
```

The app is a single-file scaffold: drag in one image or PDF, choose task/layout settings, then run OCR.

### Examples and Evaluation

```bash
# Regenerate examples/result/*
scripts/run_examples.sh

# Report-only diffs vs checked-in baselines
python3 scripts/compare_examples.py --lane both
```

For scored evaluation, initialize the submodule first if needed:

```bash
git submodule update --init --recursive
scripts/verify_example_eval.sh
```

`scripts/run_examples.sh` uses the checked-in parity contract by default: pinned HF revisions plus the applied-and-recorded `parity-greedy-v1` preset from `scripts/_parity_defaults.sh`.

`scripts/verify_example_eval.sh` refreshes `examples/result/` when needed, runs `tools/example_eval/`, and records the latest evaluation snapshot under `examples/eval_records/latest/`, including the model revisions and generation preset used for the example run.

## Configuration

### CLI defaults

- `--model`: `zai-org/GLM-OCR`
- `--revision`: `main`
- `--layout-model`: `PaddlePaddle/PP-DocLayoutV3_safetensors`
- `--layout-revision`: `main`
- `--max-new-tokens`: `2048`
- `--generation-preset`: `default-greedy-v1`
- Checked-in parity generation preset: `parity-greedy-v1`
- Current generation policy for both shipped presets: greedy (`temperature = 0`, `topP = 1`)
- Layout mode default: on for PDFs, off for non-PDF inputs

Run `swift run GLMOCRCLI --help` for the full flag list.

### Hugging Face cache resolution

`VLMRuntimeKit` resolves the snapshot cache in this order:

1. `--download-base`
2. `HF_HUB_CACHE`
3. `HF_HOME` + `/hub`
4. `~/.cache/huggingface/hub`

### Key environment variables

- `GLMOCR_SNAPSHOT_PATH` and `LAYOUT_SNAPSHOT_PATH`
  - override auto-discovered cached snapshots for model-backed tests
- `GLMOCR_RUN_GOLDEN=1` and `LAYOUT_RUN_GOLDEN=1`
  - enable opt-in golden/parity integration tests
- `GLMOCR_RUN_EXAMPLES=1`
  - enables the checked-in end-to-end examples parity tests
- `GLMOCR_PREPROCESS_BACKEND`, `GLMOCR_POST_RESIZE_JPEG_QUALITY`, `GLMOCR_ALIGN_VISION_DTYPE`
  - developer-only preprocessing and parity knobs

The full test and parity matrix lives in `docs/golden_checks.md`.

## Known Limits

- Quality/parity work is still active. The current tracker is `docs/dev_plans/quality_parity/tracker.md`.
- In layout mode, region labels determine the OCR task, so CLI `--task` is ignored.
- Markdown image placeholders are only replaced with cropped image files when an export directory exists through `--emit-json` or `--emit-ocrdocument-json`.
- Formula OCR currently keeps bbox crops even when `OCRDocument` preserves derived layout polygons; table OCR uses polygon crops.
- The app does not yet provide queueing, export UI, model management, or packaging/distribution features.

## Next Steps

- Finish the quality/parity backlog in `docs/dev_plans/quality_parity/tracker.md`.
- Return to app polish and packaging in `docs/dev_plans/gui_polish_distribution/tracker.md`.

## Docs

- `docs/overview.md` - docs index and source-of-truth map
- `docs/architecture.md` - current runtime architecture and dataflow
- `docs/dev_plans/README.md` - active roadmap and archived plan pointers
- `docs/golden_checks.md` - opt-in parity, integration, and fixture workflow
- `docs/GLM-OCR_model.md` - model notes and reference behavior background
- `docs/reference_projects.md` - external reference survey and borrowing map
- `tools/example_eval/README.md` - scored evaluation workflow
- `AGENTS.md` - operating guide for coding agents

## Documentation Changelog

- Added: a verified quickstart that now matches the current CLI, app, and evaluation workflows.
- Added: the current configuration surface, including cache precedence and the key opt-in test env vars.
- Removed: stale roadmap references to non-active trackers and outdated formatting/linting assumptions.
- Clarified: which outputs are user-facing (`out.md`, JSON exports) versus generated validation artifacts (`examples/result/*`, `examples/eval_records/latest/*`).

## License

MIT
