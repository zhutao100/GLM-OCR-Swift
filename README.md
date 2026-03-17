# GLM-OCR Swift

A native macOS OCR pipeline in Swift that runs the Hugging Face `zai-org/GLM-OCR` model locally with MLX Swift.

This repo ships as:

- `GLMOCRCLI`: a command-line OCR tool for images and PDFs
- `GLMOCRApp`: a small SwiftUI drag-and-drop app (one file at a time)

Optionally, layout mode runs `PaddlePaddle/PP-DocLayoutV3_safetensors` first to detect regions and produce region-ordered Markdown plus JSON exports.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16+ recommended)
- Apple Silicon recommended for performance

## Quickstart (CLI)

```bash
# Show the live CLI contract (source of truth for flags and defaults)
swift run GLMOCRCLI --help

# Optional: prefetch the default model snapshots
swift run GLMOCRCLI --download-only

# Image -> Markdown
swift run GLMOCRCLI --input examples/source/page.png > out.md

# PDF -> Markdown (all pages by default)
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Pages_1_2_3.pdf > out.md

# Restrict PDF pages explicitly
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Pages_1_2_3.pdf --pages 1-2 > out.md
```

Non-layout OCR supports task presets via `--task`: `text`, `formula`, `table`, and `json`.

### Layout mode (region-aware)

Layout mode is enabled by default for PDFs and disabled for non-PDF inputs. It is required for JSON exports.

```bash
swift run GLMOCRCLI --layout --input examples/source/table.png \
  --emit-json out.blocks.json \
  --emit-ocrdocument-json out.ocrdocument.json > out.md
```

## Quickstart (App)

```bash
swift run GLMOCRApp
```

Drag and drop one image or PDF, then run OCR.

## Included examples

Try the sample inputs under `examples/source/` (PNG + PDF). For the example corpus contract and reproducible evaluation tooling, see [examples/README.md](examples/README.md).

## Models and caching

By default, models are resolved from the local Hugging Face cache and downloaded only when missing. You can control the cache location with `--download-base`, `HF_HUB_CACHE`, or `HF_HOME`.

For a deeper CLI reference (outputs, caching, environment variables), see [docs/apis/cli.md](docs/apis/cli.md).

## Status and limitations

- Inference runs locally; the only network dependency is downloading model snapshots when they are not already cached.
- `--emit-json` / `--emit-ocrdocument-json` require layout mode.
- The SwiftUI app is intentionally minimal and does not yet include export UI, queueing, or signed/notarized distribution.

## Documentation

- [docs/apis/cli.md](docs/apis/cli.md) — CLI usage, outputs, and model/cache behavior
- [docs/development_guide.md](docs/development_guide.md) — build/test, app, release builds, examples/eval workflows
- [docs/architecture.md](docs/architecture.md) — module boundaries and runtime dataflow
- [docs/golden_checks.md](docs/golden_checks.md) — parity and model-backed verification (opt-in)
- [docs/overview.md](docs/overview.md) — documentation index and source-of-truth map

## License

MIT (see `LICENSE`).
