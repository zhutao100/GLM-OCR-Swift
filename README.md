# GLM-OCR Swift

A native macOS (Apple Silicon) SwiftPM workspace for building a local **GLM-OCR** app in Swift.

This repo is intentionally structured as **core + adapters**:

- `Sources/VLMRuntimeKit/` — model-agnostic runtime utilities (model download/cache, prompt helpers, shared types)
- `Sources/ModelAdapters/DocLayout/` — PP-DocLayout-V3 layout detector (layout mode support)
- `Sources/ModelAdapters/GLMOCR/` — GLM-OCR-specific glue (defaults/config/prompt policy/pipeline)
- `Sources/GLMOCRCLI/` — CLI harness (model download + pipeline wiring)
- `Sources/GLMOCRApp/` — SwiftUI UI scaffold (single-file drop + run)

## Current status (2026-02-12)

- `swift build` / `swift test` pass.
- CLI + App run (single file/image/PDF input).
- Hugging Face snapshot download + cache resolution is implemented (`VLMRuntimeKit/ModelStore`).
- End-to-end MVP OCR works for a single image or a single PDF page:
  - Vision decode + PDF page rendering
  - CIImage → MLX tensor conversion + normalization
  - GLM chat-template tokenization (`[gMASK]<sop>` + image placeholders)
  - Greedy token-by-token decode (with KV cache)
- Phase 04 layout mode is implemented for single-page documents:
  - PP-DocLayout-V3 layout detection → region crop → per-region GLM-OCR → merged Markdown
  - Optional examples-compatible block-list JSON export from the CLI (`--emit-json`)
  - Optional structured `OCRDocument` JSON export from the CLI (`--emit-ocrdocument-json`)

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

# One-time: build MLX's metal shader library next to SwiftPM-built executables
scripts/build_mlx_metallib.sh -c debug

# OCR a single PDF page (prints Markdown to stdout; first run downloads models)
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Page_1.pdf --page 1 > out.md

# Launch the SwiftUI app scaffold (drag/drop one image or PDF)
swift run GLMOCRApp
```

Note: if you `rm -rf .build` or switch build configs, re-run `scripts/build_mlx_metallib.sh` so the current build products have a colocated `mlx.metallib`.

Developer (Phase 02): single forward pass (logits only):

```bash
swift run GLMOCRCLI --dev-forward-pass
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
- `--input <path>`, `--page <n>` (PDF only), `--task <preset>`, `--max-new-tokens <n>`
- Layout mode: `--layout/--no-layout`, `--layout-parallelism auto|1|2`, `--emit-json <path>`, `--emit-ocrdocument-json <path>`

## Limitations / known gaps

- Quality/parity vs the official MLX Python example is not yet validated on a curated image set.
- Layout mode currently runs a **single PDF page** at a time (CLI `--page`; App uses page 1).
- App currently uses page 1 for PDFs (no page picker yet).
- App has no queue/settings/export UI yet; it’s a single-file scaffold used to iterate on pipeline wiring.

## Next steps (roadmap)

Keep the detailed plan in `docs/dev_plans/`. Near-term work:

1. Phase 05: multi-page workflows + export/UX polish.
2. Quality/parity validation vs the official pipeline + curated test set.

## Docs

- `docs/overview.md` — docs index + “what exists today”
- `docs/architecture.md` — module boundaries + current vs planned dataflow
- `docs/dev_plans/` — phased plan (source of truth for roadmap)
- `docs/GLM-OCR_model.md` — GLM-OCR model notes (tokens, templates, pipeline behavior)
- `docs/reference_projects.md` — reference Swift OCR ports + borrowing map
- `AGENTS.md` — agent operating guide for working in this repo

## Documentation Changelog

- Added: `DocLayoutAdapter` module mention + a runnable OCR example command using `examples/source/`.
- Removed/clarified: stale “OCR is stubbed” / “golden parity is failing” notes that no longer match the repo.
- Clarified: Quickstart now includes the required `mlx.metallib` step and a concrete CLI OCR invocation.

## License

MIT.
