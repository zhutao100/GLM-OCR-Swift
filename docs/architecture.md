# Architecture

## Module boundaries

### `VLMRuntimeKit` (model-agnostic)

Responsibilities:

- `ModelStore`: Hugging Face Hub snapshot download + local cache conventions
- `Weights`: safetensors + dtype/quant plumbing (stubbed in starter)
- `TokenizerKit`: prompt templates + multimodal placeholder splitting
- `OCRTypes`: shared pipeline protocol + result types (Sendable-first)
- `VisionIO`: decode images/PDF pages and convert to MLX tensors
- `Generation`: decoder loop, KV cache, streaming interface (stubbed in starter)

### `GLMOCRAdapter` (model-specific)

Responsibilities:

- `GLMOCRConfig`: parse model config + tokenizer config metadata
- `GLMOCRProcessor`: task presets, prompt templates, vision preprocessing policy
- `GLMOCRModel`: model definition + weight-loading glue (stubbed)
- `GLMOCRPipeline`: orchestration actor; conforms to `OCRPipeline`

### `GLMOCRApp` (SwiftUI)

Responsibilities:

- drag/drop images + PDFs
- job queue, cancellation, progress, export
- model manager screen for download status + storage location

## Dataflow (MVP)

```
Image/PDF -> VisionIO -> GLMOCRProcessor -> TokenizerKit(prompt)
     -> GLMOCRModel + Generation -> OCRResult(text + diagnostics)
```

## Extension points

- Add new model adapters under `Sources/ModelAdapters/*`
- Consolidation to a multi-model app is a mechanical refactor once adapters exist.
