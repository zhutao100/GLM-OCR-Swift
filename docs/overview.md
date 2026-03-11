# Docs Overview

This folder is the maintained reference set for the repo. For the runnable quickstart, start with `README.md`.

## Current State (verified 2026-03-11)

- The SwiftPM workspace builds and tests cleanly.
- MLX-backed SwiftPM tests auto-prepare `mlx.metallib` instead of relying on manual prebuild steps.
- Local OCR works through both the CLI and the app for images and PDFs.
- Layout mode is implemented and can emit Markdown, examples-style block-list JSON, and structured `OCRDocument` JSON.
- Hugging Face snapshot download and cache resolution are implemented in `VLMRuntimeKit`.
- Example generation, diffing, scored evaluation, and persistent eval records are all wired up.
- The repo has checked-in CI for default verification and nightly CLI packaging smoke checks.
- The main remaining work is quality/parity tightening and app/distribution polish.

## Start Here

- Build and run the project
  - `README.md`

- Understand the current runtime structure
  - `docs/architecture.md`

- Find the active roadmap
  - `docs/dev_plans/README.md`

- Work on parity, golden fixtures, or model-backed integration checks
  - `docs/golden_checks.md`
  - `docs/dev_plans/quality_parity/tracker.md`

- Understand why the repo uses core plus adapters
  - `docs/decisions/README.md`
  - `docs/decisions/0001-core-adapter.md`

- Evaluate or compare example outputs
  - `tools/example_eval/README.md`
  - `examples/eval_records/README.md`
  - `scripts/compare_examples.py`

## Source Of Truth Map

- Current user-facing behavior
  - `README.md`
  - `swift run GLMOCRCLI --help`

- Architecture, module boundaries, and dataflow
  - `docs/architecture.md`

- Durable design decisions
  - `docs/decisions/README.md`

- Active roadmap and prioritized gaps
  - `docs/dev_plans/README.md`
  - tracker files under `docs/dev_plans/`

- Parity and integration workflow
  - `docs/golden_checks.md`

- Generated example artifacts and evaluation records
  - `examples/README.md`
  - `examples/eval_records/README.md`

## Generated Versus Maintained Content

- Maintained docs
  - `README.md`
  - `AGENTS.md`
  - `docs/*.md`

- Generated validation artifacts
  - `examples/result/*` from `scripts/run_examples.sh`
  - `examples/eval_records/latest/*` from `scripts/verify_example_eval.sh`
  - `.build/example_eval/*` from `tools/example_eval/`

## Active Work

- Quality/parity backlog
  - `docs/dev_plans/quality_parity/tracker.md`

- GUI polish and distribution
  - `docs/dev_plans/gui_polish_distribution/tracker.md`

## Historical Material

- `docs/dev_plans/archive/`
  - completed implementation plans and archived trackers

- `docs/debug_notes/`
  - investigation logs and postmortems

- `docs/context/`
  - supporting background material

Treat these folders as reference context. They can describe older states of the project and should not be used as the source of current behavior.
