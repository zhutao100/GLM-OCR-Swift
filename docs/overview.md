# Docs Overview

This folder is the maintained docs entry point for contributors. For the runnable quickstart, start with `README.md`. For the live CLI surface, use `swift run GLMOCRCLI --help`.

## Current State (verified 2026-03-11)

- The SwiftPM workspace builds and tests cleanly.
- MLX-backed SwiftPM tests auto-prepare `mlx.metallib`.
- Local OCR works through both the CLI and the app for images and PDFs.
- Non-layout task presets support `text`, `formula`, `table`, and structured `json`.
- Layout mode emits Markdown, examples-style block-list JSON, and structured `OCRDocument` JSON.
- Hugging Face snapshot download and cache resolution are implemented in `VLMRuntimeKit`.
- Example generation, diffing, scored evaluation, and persistent eval records are all wired up.
- The main remaining work is incremental quality/parity tightening plus later app/distribution polish.

## Maintained Docs

- `README.md`
  - user-facing overview and quickstart (CLI + app)
- `docs/development_guide.md`
  - build/test, app, release builds, and examples/eval workflows
- `docs/apis/README.md`
  - user-facing interface index
- `docs/apis/cli.md`
  - `GLMOCRCLI` usage, outputs, and model/cache behavior
- `docs/architecture.md`
  - current module boundaries, runtime flows, and output contracts
- `docs/golden_checks.md`
  - opt-in parity, golden, and model-backed integration workflow
- `docs/dev_plans/README.md`
  - roadmap entrypoint and tracker index
- `docs/dev_plans/quality_parity/tracker.md`
  - live parity maintenance backlog, baseline scores, and reproducibility contract
- `docs/dev_plans/quality_parity/gateway_preprocessing/README.md`
  - candidate assessment and experiment design for lightweight degraded-input gateway preprocessing
- `docs/dev_plans/quality_parity/gateway_preprocessing/tracker.md`
  - ordered gateway-preprocessing workstreams and acceptance criteria
- `docs/dev_plans/gui_polish_distribution/tracker.md`
  - deferred app/export/distribution backlog
- `docs/decisions/README.md`
  - ADR index for durable design choices
- `examples/README.md`
  - example corpus ownership and output contract
- `examples/eval_records/README.md`
  - eval record refresh policy and baseline semantics
- `tools/example_eval/README.md`
  - evaluator usage and report outputs

## Background And Reference

- `docs/reference_projects.md`
  - external project survey and borrowing notes; background only
- `docs/GLM-OCR_model.md`
  - model notes and upstream behavior background
- `docs/context/`
  - supporting background material for parity and numerical behavior

## Historical Material

- `docs/debug_notes/`
  - investigation logs and postmortems
- `docs/dev_plans/archive/`
  - completed implementation phases and archived trackers
- `docs/decisions/obsolete_archive/`
  - superseded ADRs

Treat these folders as reference context. They can describe older repo states and are not the source of current behavior.

## Generated Versus Maintained Content

- Maintained docs
  - `README.md`
  - `AGENTS.md`
  - `docs/*.md`
  - `examples/README.md`
  - `examples/eval_records/README.md`

- Generated validation artifacts
  - `examples/result/*` from `scripts/run_examples.sh`
  - `examples/eval_records/latest/*` from `scripts/verify_example_eval.sh`
  - `.build/example_eval/*` from `tools/example_eval/`

## Source Of Truth Priority

1. `swift run GLMOCRCLI --help` and the current source under `Sources/`
2. `README.md`
3. `docs/architecture.md` and ADRs under `docs/decisions/`
4. active trackers under `docs/dev_plans/`
5. background and historical docs for context only
