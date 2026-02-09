# GLM-OCR Swift

A native macOS (Apple Silicon) SwiftPM workspace for building a local **GLM-OCR** app in Swift.

This repo is intentionally structured as **core + adapter**:

- `Sources/VLMRuntimeKit/` — model-agnostic runtime utilities (model download/cache, prompt helpers, shared types)
- `Sources/ModelAdapters/GLMOCR/` — GLM-OCR-specific glue (defaults/config/prompt policy/pipeline)
- `Sources/GLMOCRCLI/` — CLI harness (model download + pipeline wiring)
- `Sources/GLMOCRApp/` — SwiftUI UI scaffold (single-file drop + run)

## Current status (2026-02-09)

- `swift build` / `swift test` pass.
- CLI + App run.
- Hugging Face snapshot download + cache resolution is implemented (`VLMRuntimeKit/ModelStore`).
- **OCR inference is not implemented yet** (vision tensor conversion, tokenizer/chat template, weights loading, generation/model port).
  - `GLMOCRCLI --download-only` is expected to work.
  - `GLMOCRCLI --input …` currently fails with a `notImplemented` error (model port stub).

## Requirements

- macOS 14+
- Xcode 16+ (Swift 6 toolchain) or a standalone Swift 6 toolchain
- Apple Silicon recommended (MLX)

## Quickstart

```bash
# Build + test
swift build
swift test

# CLI usage (no model download)
swift run GLMOCRCLI --help

# Launch the SwiftUI app scaffold
swift run GLMOCRApp
```

Optional (large download):

```bash
# Download the model snapshot to the default HF cache
swift run GLMOCRCLI --download-only

# Or download into a custom directory
swift run GLMOCRCLI --download-base ~/hf-cache --download-only
```

## Configuration

### Model download cache (Hugging Face)

Cache directory precedence in `VLMRuntimeKit`:

1. CLI `--download-base` (or a future App setting)
2. `HF_HUB_CACHE`
3. `HF_HOME` (uses `$HF_HOME/hub`)
4. default: `~/.cache/huggingface/hub`

### CLI flags

Run `swift run GLMOCRCLI --help` for the full list. Key flags:

- `--model` (default: `zai-org/GLM-OCR`)
- `--revision` (default: `main`)
- `--download-base <path>` (optional)
- `--download-only` (download without inference)
- `--input <path>`, `--task <preset>`, `--max-new-tokens <n>` (wired, but inference is stubbed)

## Limitations / known gaps

- `GLMOCRModel.generate(...)` is unimplemented (no end-to-end OCR yet).
- `VisionIO` currently loads images via `CIImage`, but MLX tensor conversion is a stub; PDF page rendering is not implemented.
- Prompt formatting is placeholder (`<image>` + instruction) and not yet aligned with GLM-OCR’s shipped chat template / special tokens.
- App has no queue/cancellation/settings yet; it’s a single-file scaffold used to iterate on pipeline wiring.

## Next steps (roadmap)

Keep the detailed plan in `docs/dev_plans/`. Near-term work:

1. Phase 02: implement `VisionIO` tensor conversion + tokenizer/chat template + a minimal decode loop.
2. Phase 03: port the GLM-OCR model + weights mapping in MLX Swift.

## Docs

- `docs/overview.md` — docs index + “what exists today”
- `docs/architecture.md` — module boundaries + current vs planned dataflow
- `docs/dev_plans/` — phased plan (source of truth for roadmap)
- `docs/GLM-OCR_model.md` — GLM-OCR model notes (tokens, templates, pipeline behavior)
- `docs/reference_projects.md` — reference Swift OCR ports + borrowing map
- `AGENTS.md` — agent operating guide for working in this repo

## Documentation Changelog

- Added: explicit “Current status”, runnable quickstart, and configuration details (HF cache precedence + CLI flags).
- Removed/clarified: claims of job queue/cancellation/export and end-to-end OCR (not implemented yet).
- Restructured: consistent module paths (`Sources/...`) and a single doc index (`docs/overview.md`) to avoid duplication.

## License

MIT.
