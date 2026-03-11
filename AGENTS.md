# Agent Operating Guide (AGENTS.md)

This repo is meant to stay safely evolvable by coding agents across many sessions. Treat it as a native local-inference OCR app, not as a port of the upstream Python service stack.

## Mission

Build and maintain a fully native macOS GLM-OCR app in Swift using:

- MLX Swift for local inference
- Hugging Face `swift-transformers` for snapshot download and tokenizer loading
- a core-plus-adapter architecture that stays open to future multi-model consolidation

## Current Reality (verified 2026-03-11)

- `swift test` passes.
- `swift run GLMOCRCLI --help` works and is the live CLI contract.
- MLX-backed SwiftPM tests auto-prepare `mlx.metallib` on demand.
- `scripts/build.sh` is the scripted release-build entrypoint for the packaged CLI path.
- CLI and app support local OCR for images and PDFs.
- Non-layout task presets support `text`, `formula`, `table`, and structured `json`.
- Layout mode is implemented with PP-DocLayout-V3 -> region OCR -> merged Markdown.
- CLI layout exports support both examples-style block-list JSON and structured `OCRDocument` JSON.
- Heavy model-backed validation is opt-in through env vars and cached HF snapshots.
- Example generation, diffing, and scored evaluation tooling are wired up and in daily use.
- The repo has checked-in CI for `swift test` and nightly CLI packaging smoke checks.

## Non-Negotiables

1. Preserve module boundaries.
   - `VLMRuntimeKit` stays model-agnostic.
   - `DocLayoutAdapter` contains only PP-DocLayout-V3-specific code.
   - `GLMOCRAdapter` contains only GLM-OCR-specific code plus orchestration that composes the layout adapter.
   - UI code stays in `GLMOCRApp`.

2. Keep docs in sync with the code.
   - Update `README.md` for user-visible workflow or configuration changes.
   - Update `docs/overview.md` when the doc routing or source-of-truth map changes.
   - Update `docs/architecture.md` when module boundaries, public API shape, or runtime dataflow changes.
   - Update `docs/dev_plans/*` trackers when work lands or priorities change.
   - Add an ADR under `docs/decisions/` when you change interfaces, cache layout, prompt/template policy, or other durable contracts.

3. Prefer deterministic, testable primitives.
   - Keep preprocessing, prompt splitting, cache-path resolution, page selection, and export formatting easy to unit test.
   - Add targeted regression tests for deterministic fixes.

4. Do not overfit the repo to transient debugging work.
   - Remove temporary logging, ad hoc scripts, and one-off doc notes unless they are still part of the maintained workflow.

## Read First By Task

- Triage / bug reproduction
  - `README.md`
  - `docs/overview.md`
  - run `swift test`
  - then reproduce with `swift run GLMOCRCLI --help` or a small example input

- Runtime / pipeline feature work
  - `docs/architecture.md`
  - `docs/dev_plans/README.md`
  - relevant tracker under `docs/dev_plans/`
  - `docs/decisions/README.md`

- Small deterministic bugfix
  - search with `rg`
  - start from the owning target in `Sources/`
  - add or update a focused unit test under `Tests/`

- Parity / golden / examples work
  - `docs/dev_plans/quality_parity/tracker.md`
  - `docs/golden_checks.md`
  - `examples/README.md`
  - `examples/eval_records/README.md`
  - `tools/example_eval/README.md`
  - relevant notes under `docs/debug_notes/`

- Release / packaging / app polish
  - `README.md`
  - `docs/architecture.md`
  - `docs/dev_plans/gui_polish_distribution/tracker.md`
  - `docs/reference_projects.md`

- Docs-only work
  - `docs/overview.md`
  - `README.md`
  - `AGENTS.md`
  - `docs/dev_plans/README.md`
  - keep the maintained docs aligned instead of repeating the same guidance in multiple places

## Repo Map

- `Sources/VLMRuntimeKit/`
  - model store, prompt/template helpers, OCR types, block-list export, page selection, vision IO, markdown image cropping, generation, weights
- `Sources/ModelAdapters/DocLayout/`
  - PP-DocLayout-V3 config, preprocessing, mappings, model, detector, postprocess, markdown formatter
- `Sources/ModelAdapters/GLMOCR/`
  - GLM-OCR config, tokenizer, chat template, image processor, model, non-layout pipeline, layout pipeline
- `Sources/GLMOCRCLI/`
  - CLI flags, model download flow, export wiring
- `Sources/GLMOCRApp/`
  - SwiftUI scaffold for one dropped file at a time
- `Tests/VLMRuntimeKitTests/`
  - deterministic runtime tests
- `Tests/DocLayoutAdapterTests/`
  - layout unit tests plus opt-in golden/integration checks
- `Tests/GLMOCRAdapterTests/`
  - GLM-OCR unit tests plus opt-in integration, golden, and example-parity checks

## Source Of Truth Priority

- Live CLI surface and runnable behavior
  - `swift run GLMOCRCLI --help`
  - current source under `Sources/`

- User-facing workflow and defaults
  - `README.md`

- Architecture and durable contracts
  - `docs/architecture.md`
  - ADRs in `docs/decisions/`

- Current roadmap and active gaps
  - `docs/dev_plans/README.md`
  - active trackers under `docs/dev_plans/`

- Parity, examples, and evaluation workflow
  - `docs/golden_checks.md`
  - `examples/README.md`
  - `examples/eval_records/README.md`
  - `tools/example_eval/README.md`

- Historical context
  - `docs/debug_notes/`
  - `docs/dev_plans/archive/`
  - `docs/reference_projects.md`

## Common Commands

```bash
swift build
swift test
swift run GLMOCRCLI --help
swift run GLMOCRCLI --download-only
swift run GLMOCRCLI --input examples/source/page.png > out.md
swift run GLMOCRCLI --layout --input examples/source/table.png --emit-json out.json > out.md
swift run GLMOCRApp
scripts/build_mlx_metallib.sh -c debug
scripts/build.sh
scripts/run_examples.sh
python3 scripts/compare_examples.py --lane both
git submodule update --init --recursive
scripts/verify_example_eval.sh
```

## Validation Expectations

- Keep `swift test` green before wrapping up.
- If you touched CLI docs, flags, or packaging behavior, also run `swift run GLMOCRCLI --help`.
- If you touched the packaged release path or build docs, run `scripts/build.sh`.
- MLX-backed SwiftPM tests auto-prepare `mlx.metallib`; use `scripts/build_mlx_metallib.sh -c debug` to prewarm direct SwiftPM runtime experiments or executables.
- The checked-in CI workflow covers default `swift test` verification and nightly CLI packaging smoke checks. Manual local command discipline remains the pre-merge validation contract.
- Use opt-in lanes only when the task requires them:
  - `GLMOCR_RUN_GOLDEN=1`
  - `LAYOUT_RUN_GOLDEN=1`
  - `GLMOCR_RUN_EXAMPLES=1`
  - `GLMOCR_TEST_RUN_FORWARD_PASS=1`
  - `GLMOCR_TEST_RUN_GENERATE=1`
- Snapshot-backed tests auto-resolve from the local HF cache when possible. Use `GLMOCR_SNAPSHOT_PATH` or `LAYOUT_SNAPSHOT_PATH` to pin a snapshot folder explicitly.

## Repo Conventions

- Swift 6 strict concurrency is enabled everywhere.
- Default to `Sendable` value types and use `actor` for mutable shared state.
- Prefer typed errors over `fatalError` unless the failure is genuinely unrecoverable.
- Keep `VLMRuntimeKit` free of GLM-OCR- or PP-DocLayout-V3-specific policy.
- Swift formatting is driven by `.swift-format` and the repo hook in `scripts/precommit_swift_format_autostage.sh`, wired through `.pre-commit-config.yaml`.
- When working with MLX tensors:
  - avoid compound assignment unless non-aliasing is proven
  - prefer out-of-place residual updates such as `x = x + y`
  - align dtype and device explicitly during parity work; see `docs/golden_checks.md`

## Docs Maintenance Checklist

- If CLI flags, defaults, or quickstart steps changed, update `README.md`.
- If module boundaries, outputs, or runtime flow changed, update `docs/architecture.md`.
- If priorities changed, update `docs/dev_plans/README.md` and the relevant tracker.
- If you touch historical docs, fix dead links and obvious inaccuracies, but keep them clearly historical.
- Before wrapping up, look for duplicated guidance across `README.md`, `AGENTS.md`, and `docs/`; consolidate rather than copy-paste.

## Useful Local References

- `docs/reference_projects.md`
- `docs/GLM-OCR_model.md`
- `../GLM-OCR`
- `../glm-ocr.swift`
- `../glm-ocr-swift-2`
- HF cache roots
  - `~/.cache/huggingface/hub/models--zai-org--GLM-OCR/`
  - `~/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/`
- When inspecting Python reference code, use:
  - `PYENV_VERSION=venv313 pyenv exec ...`
