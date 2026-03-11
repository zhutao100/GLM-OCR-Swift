# GLM-OCR Swift

Native macOS OCR for GLM-OCR using MLX Swift and Hugging Face Swift tooling. The project runs fully local OCR on images and PDFs, and can optionally run PP-DocLayout-V3 first to produce region-aware Markdown plus structured JSON exports.

The repo is intentionally split into a model-agnostic runtime plus model-specific adapters:

- `Sources/VLMRuntimeKit/` - shared runtime primitives
- `Sources/ModelAdapters/DocLayout/` - PP-DocLayout-V3 layout detection
- `Sources/ModelAdapters/GLMOCR/` - GLM-OCR model glue and orchestration
- `Sources/GLMOCRCLI/` - CLI entrypoint
- `Sources/GLMOCRApp/` - SwiftUI app scaffold

See `docs/architecture.md` for the current module boundaries and dataflow.

## Quickstart

### Prerequisites

- macOS 14+
- Xcode 16+ or another Swift 6 toolchain
- Xcode Command Line Tools
- Apple Silicon is strongly recommended

### Build and smoke test

```bash
swift build
swift test
swift run GLMOCRCLI --help
```

`swift test` prepares the SwiftPM `mlx.metallib` automatically when an MLX-backed test first needs it.

If you want to run MLX-backed SwiftPM executables directly from `.build`, prebuild the Metal library with:

```bash
scripts/build_mlx_metallib.sh -c debug
```

### Run OCR

```bash
# Optional: prefetch the default model snapshots only
swift run GLMOCRCLI --download-only

# Image -> Markdown
swift run GLMOCRCLI --input examples/source/page.png > out.md

# PDF -> Markdown (all pages by default)
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Pages_1_2_3.pdf > out.md

# Restrict PDF pages explicitly
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Pages_1_2_3.pdf --pages 1-2 > out.md

# Layout mode with both JSON export formats
swift run GLMOCRCLI --layout --input examples/source/table.png \
  --emit-json out.json \
  --emit-ocrdocument-json out.ocrdocument.json > out.md
```

The first inference run may download missing Hugging Face snapshots into the local cache.

### Launch the app

```bash
swift run GLMOCRApp
```

The app is intentionally small: drag in one image or PDF, choose task/layout/page settings, then run OCR. Dropping a PDF auto-enables layout mode and defaults page selection to `all`.

### Build the packaged CLI path

Use the repo build wrapper for the release package path:

```bash
scripts/build.sh
DERIVED_DATA_PATH=./dist ./scripts/build.sh
```

Equivalent explicit command:

```bash
xcodebuild build -scheme GLMOCRCLI -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode -skipPackagePluginValidation ENABLE_PLUGIN_PREPAREMLSHADERS=YES CLANG_COVERAGE_MAPPING=NO
```

### Examples and scored evaluation

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

The checked-in parity contract for examples lives in `scripts/_parity_defaults.sh` and is recorded into `examples/result/.run_examples_meta.json` plus `examples/eval_records/latest/`.

## Configuration

### Key CLI defaults

- `--model`: `zai-org/GLM-OCR`
- `--revision`: `main`
- `--layout-model`: `PaddlePaddle/PP-DocLayoutV3_safetensors`
- `--layout-revision`: `main`
- `--task`: `text`
- `--max-new-tokens`: `2048`
- `--generation-preset`: `default-greedy-v1`
- `--layout-parallelism`: `auto`
- Layout mode default: on for PDFs, off for non-PDF inputs
- Checked-in parity preset: `parity-greedy-v1`

Run `swift run GLMOCRCLI --help` for the full flag list.

### Snapshot and cache resolution

`VLMRuntimeKit` resolves the Hugging Face cache in this order:

1. `--download-base`
2. `HF_HUB_CACHE`
3. `HF_HOME` + `/hub`
4. `~/.cache/huggingface/hub`

For GLM-OCR and layout runtime loads, snapshot lookup prefers an explicit snapshot override first, then the local HF cache, and only downloads when neither local source is available.

### Key environment variables

- `GLMOCR_SNAPSHOT_PATH`
  - override the preferred local snapshot for GLM-OCR runtime loads and model-backed tests
- `LAYOUT_SNAPSHOT_PATH`
  - override the preferred local snapshot for PP-DocLayout-V3 runtime loads and model-backed tests
- `GLMOCR_RUN_GOLDEN=1`
  - enable GLM-OCR golden/parity integration tests
- `LAYOUT_RUN_GOLDEN=1`
  - enable PP-DocLayout-V3 golden/parity integration tests
- `GLMOCR_RUN_EXAMPLES=1`
  - enable the checked-in end-to-end examples parity integration lane
- `GLMOCR_TEST_RUN_FORWARD_PASS=1`
  - enable the GLM-OCR smoke forward-pass test
- `GLMOCR_TEST_RUN_GENERATE=1`
  - enable the GLM-OCR one-token generate smoke test
- `GLMOCR_PREPROCESS_BACKEND`, `GLMOCR_POST_RESIZE_JPEG_QUALITY`, `GLMOCR_ALIGN_VISION_DTYPE`, `GLMOCR_VISION_INPUT_DTYPE`
  - preprocessing/debug overrides; runtime image tensors align to the loaded vision weights by default, and layout OCR adaptively prefers deterministic resize for short, wide text-line crops unless the backend is forced explicitly

The full parity and integration matrix lives in `docs/golden_checks.md`.

## Known Limits

- In layout mode, region labels determine the OCR task, so CLI/app task selection is ignored.
- `--emit-json` and `--emit-ocrdocument-json` require layout mode.
- Markdown image placeholders are only materialized into cropped image files when an export directory exists via `--emit-json` or `--emit-ocrdocument-json`.
- Table OCR uses polygon crops when layout masks provide them; formula OCR still uses bbox crops even though `OCRDocument` preserves derived polygons.
- Default user-facing revisions track `main`; pinned revisions are reserved for parity scripts and scored eval artifacts.
- Broad corpus parity remains report-only through `scripts/verify_example_eval.sh`; the opt-in integration lane protects only the current stable subset.
- The app does not yet provide queueing, export UI, model management, or signed/notarized distribution.

## Next Steps

- Keep tightening hard examples and eval hygiene through `docs/dev_plans/quality_parity/tracker.md`.
- Return to app/export/distribution work through `docs/dev_plans/gui_polish_distribution/tracker.md` when product focus shifts back to packaging.

## Docs

- `docs/overview.md` - docs index and source-of-truth map
- `docs/architecture.md` - current runtime architecture and dataflow
- `docs/dev_plans/README.md` - current roadmap entrypoint
- `docs/golden_checks.md` - opt-in parity, integration, and fixture workflow
- `examples/README.md` - example corpus and output contract
- `examples/eval_records/README.md` - scored evaluation record policy
- `tools/example_eval/README.md` - evaluator usage and scoring model
- `AGENTS.md` - operating guide for coding agents

## License

MIT
