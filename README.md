# GLM-OCR Swift

A native macOS (Apple Silicon) SwiftPM workspace for running **GLM-OCR** locally in Swift (images/PDFs → Markdown), with an optional layout stage for structured output.

This repo is intentionally structured as **core + adapters**:

- `Sources/VLMRuntimeKit/` — model-agnostic runtime utilities (model download/cache, prompt helpers, shared types)
- `Sources/ModelAdapters/DocLayout/` — PP-DocLayout-V3 layout detector (layout mode support)
- `Sources/ModelAdapters/GLMOCR/` — GLM-OCR-specific glue (defaults/config/prompt policy/pipeline)
- `Sources/GLMOCRCLI/` — CLI harness (model download + pipeline wiring)
- `Sources/GLMOCRApp/` — SwiftUI UI scaffold (single-file drop + run)

See `docs/architecture.md` for module boundaries and dataflow.

## Current status (2026-02-17)

- `swift build` / `swift test` pass.
- CLI + App run for images and PDFs (single/multi-page).
- Hugging Face Hub snapshot download + cache resolution is implemented (`VLMRuntimeKit/ModelStore`).
- End-to-end OCR works for a single image or a PDF (single/multi-page):
  - Vision decode + PDF page rendering
  - CIImage → MLX tensor conversion + normalization
  - GLM chat-template tokenization (`[gMASK]<sop>` + image placeholders)
  - Greedy token-by-token decode (with KV cache)
- Phase 04 layout mode is implemented (PDF/images):
  - PP-DocLayout-V3 layout detection → region crop → per-region GLM-OCR → merged Markdown
  - Optional examples-compatible block-list JSON export from the CLI (`--emit-json`)
  - Optional structured `OCRDocument` JSON export from the CLI (`--emit-ocrdocument-json`)

## Requirements

- macOS 14+
- Xcode 16+ (Swift 6 toolchain) or a standalone Swift 6 toolchain
- Xcode Command Line Tools (for `xcrun metal` used by `scripts/build_mlx_metallib.sh`)
- Apple Silicon recommended (MLX)

## Quickstart

```bash
# Build + test
swift build
swift test

# CLI usage (no model download)
swift run GLMOCRCLI --help

# One-time (per build config): build MLX's metal shader library next to SwiftPM-built executables
scripts/build_mlx_metallib.sh -c debug

# OCR an image (prints Markdown to stdout; first run downloads models)
swift run GLMOCRCLI --input examples/source/page.png > out.md

# OCR a PDF with layout exports (writes JSON + crops images into ./imgs/)
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Page_1.pdf --pages 1 --emit-json out.json > out.md

# Launch the SwiftUI app scaffold (drag/drop one image or PDF)
swift run GLMOCRApp
```

Note: if you `rm -rf .build` or switch build configs, re-run `scripts/build_mlx_metallib.sh` so the current build products have a colocated `mlx.metallib`.

Optional: batch-run all inputs in `examples/source/` (always runs in layout mode so it can emit JSON):

```bash
scripts/run_examples.sh
```

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
- `--input <path>`, `--pages <spec>` (PDF only; omit for all pages), `--task <preset>`, `--max-new-tokens <n>`
- Layout mode (default: on for PDFs): `--layout/--no-layout`, `--layout-parallelism auto|1|2`, `--emit-json <path>`, `--emit-ocrdocument-json <path>`

## Limitations / known gaps

- Quality/parity is only partially validated (opt-in examples parity + golden checks exist); see `docs/dev_plans/quality_parity/tracker.md`.
- `--task` presets apply to non-layout mode; layout mode determines tasks per region (so `--task` is ignored).
- Layout Markdown image placeholders are only replaced with saved crops when an output directory is available (e.g. via `--emit-json` / `--emit-ocrdocument-json`).
- Large PDFs may be slower (PDF pages are rendered one-by-one; no shared render session yet).
- App has no queue/settings/export UI yet; it’s a single-file scaffold used to iterate on pipeline wiring.

## Next steps (roadmap)

Keep the detailed plan in `docs/dev_plans/README.md`. Near-term work:

1. Quality/parity validation (tracked in `docs/dev_plans/quality_parity/tracker.md`).
2. Export/UX polish + distribution packaging (tracked in `docs/dev_plans/gui_polish_distribution/tracker.md`).

## Docs

- `docs/overview.md` — docs index + “what exists today”
- `docs/architecture.md` — module boundaries + current vs planned dataflow
- `docs/dev_plans/README.md` — phased plan (source of truth for roadmap)
- `docs/dev_plans/quality_parity/tracker.md` — quality/parity validation tracker
- `docs/golden_checks.md` — opt-in numerical parity & golden fixtures
- `docs/GLM-OCR_model.md` — GLM-OCR model notes (tokens, templates, pipeline behavior)
- `docs/reference_projects.md` — reference Swift OCR ports + borrowing map
- `AGENTS.md` — agent operating guide for working in this repo

## Documentation Changelog

- Added: a quality/parity tracker (`docs/dev_plans/quality_parity/tracker.md`) and linked it from the main docs/roadmap.
- Added: a minimal image quickstart command + a layout-export example (`--emit-json`) that also materializes cropped images.
- Removed: stale roadmap item suggesting multi-page workflows are still pending (multi-page PDFs are implemented).
- Clarified/restructured: requirements call out the `xcrun metal` prerequisite; layout mode semantics (`--task` is ignored) are explicit; dev plans distinguish active vs completed trackers.

## License

MIT.
