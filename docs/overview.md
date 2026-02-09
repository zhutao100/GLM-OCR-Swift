# Docs overview

This folder is the structured reference for the repo. For the runnable quickstart, start at `README.md`.

## Current status (2026-02-09)

What exists and works today:

- SwiftPM package with `VLMRuntimeKit`, `GLMOCRAdapter`, `GLMOCRCLI`, `GLMOCRApp`
- `swift test` passes (focused unit tests for deterministic helpers)
- Hugging Face snapshot download + cache resolution is implemented (`VLMRuntimeKit/ModelStore`)
- CLI/App scaffolding is wired to the pipeline (download → load → recognize)
- GLM-OCR model architecture + safetensors weight loading + tokenizer validation (forward pass produces logits; decoding is not implemented yet)

What is still stubbed / not implemented yet:

- Vision preprocessing: MLX tensor conversion and PDF page rendering (`VLMRuntimeKit/VisionIO`)
- Chat-template/prompt correctness vs the real GLM-OCR template (`VLMRuntimeKit/TokenizerKit`, `GLMOCRProcessor`)
- Token-by-token decode loop / KV-cache / streaming generation (`VLMRuntimeKit/Generation`)

## Where things live (source of truth)

- Architecture and module boundaries: `docs/architecture.md`
- Roadmap and prioritized TODOs: `docs/dev_plans/`
- Decisions that affect interfaces/layout: `docs/decisions/`
- GLM-OCR model notes (special tokens, templates, pipeline behavior): `docs/GLM-OCR_model.md`
- Reference Swift OCR ports and a borrowing map: `docs/reference_projects.md`

## “I’m looking for…”

- **How to build/run:** `README.md`
- **Where to implement feature X:** `docs/dev_plans/` + `docs/architecture.md`
- **Why we chose core+adapter:** `docs/decisions/0001-core-adapter.md`
