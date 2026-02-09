# GLM-OCR Swift (Starter)

A **standalone GLM-OCR** native macOS project (Apple Silicon) designed as **core + adapter** from day one:

- `VLMRuntimeKit` — shared inference/runtime utilities (model download, tokenization, vision IO, generation)
- `ModelAdapters/GLMOCR` — GLM-OCR-specific processor + model glue
- `GLMOCRApp` — minimal SwiftUI GUI (drag/drop, queue, cancellation)
- `GLMOCRCLI` — CLI harness for smoke-testing without UI

This repo is intentionally a **starter scaffold**: the GLM-OCR model port is stubbed so you can iterate in phases.

## Requirements

- macOS 14+
- Xcode 16+ (Swift 6 toolchain) or Swift 6.0 toolchain installed
- Apple Silicon recommended (MLX)

## Quick start

```bash
# Fetch deps + build
swift build

# Run CLI help
swift run GLMOCRCLI --help

# Run SwiftUI app (SwiftPM executable app)
swift run GLMOCRApp
```

## Model download / cache

The runtime is structured to download model snapshots via Hugging Face Hub (`HubApi.snapshot`) into either:

- a user-provided base directory, or
- the default HF cache under `~/.cache/huggingface/hub` (Linux-like layout, also works on macOS).

See `VLMRuntimeKit/ModelStore` and `docs/dev_plans/01_modelstore.md`.

## Repository docs

- `AGENTS.md` — instructions for agentic coding tools
- `docs/dev_plans/` — phased execution plan
- `docs/reference_projects.md` — summary of relevant Swift OCR ports + reusable components
- `docs/architecture.md` — module boundaries + dataflow

## License

This starter repo is MIT-licensed.
