# Architecture

## Module boundaries

### `VLMRuntimeKit` (model-agnostic)

Responsibilities:

- `ModelStore`: Hugging Face Hub snapshot download + local cache conventions (**implemented**)
- `TokenizerKit`: prompt/template helpers (placeholder splitting + task→instruction mapping; **implemented**)
- `OCRTypes`: shared pipeline protocol + result types (Sendable-first; **implemented**)
- `VisionIO`: vision IO helpers
  - image file → `CIImage` (**implemented**)
  - PDF page rendering + CIImage→MLX tensor conversion (**planned; tensor conversion is currently a stub**)
- `Generation`: model-agnostic generation façade (`CausalLM` + wrapper; **implemented**)
  - token-by-token decode loop / KV cache / streaming output (**planned**)
- `Weights`: safetensors + dtype/quant plumbing (**planned; currently a stub**)

### `GLMOCRAdapter` (model-specific)

Responsibilities:

- `GLMOCRDefaults`: default model id/revision + snapshot download globs (**implemented**)
- `GLMOCRConfig`: parse model config metadata (**implemented**)
- `GLMOCRProcessor`: model-specific prompt policy (**placeholder; needs alignment with GLM-OCR chat template**)
- `GLMOCRModel`: model definition + weight-loading + generation (**stubbed**)
- `GLMOCRPipeline`: orchestration actor; conforms to `OCRPipeline` (**implemented**, but inference fails until the model port lands)

### `GLMOCRApp` (SwiftUI)

Responsibilities:

- Minimal UI scaffold:
  - drag/drop a single file (image/PDF)
  - show download status (via `Progress` callback)
  - run a single recognition attempt and display output/error

Planned (Phase 05):

- job queue, cancellation, progress per job, export
- model manager screen for download status + storage location

## Dataflow (MVP)

```
Image/PDF -> VisionIO -> GLMOCRProcessor -> TokenizerKit(prompt)
     -> GLMOCRModel + Generation -> OCRResult(text + diagnostics)
```

### Current implementation note

Today, `GLMOCRPipeline.recognize(.fileURL(...), ...)` validates the file path and builds a placeholder prompt, but it does not yet:

- decode the image/PDF,
- convert pixels to an MLX tensor,
- tokenize using the real GLM-OCR chat template,
- run model forward + decode.

Those pieces land in Phase 02/03.

## Extension points

- Add new model adapters under `Sources/ModelAdapters/*`
- Consolidation to a multi-model app is a mechanical refactor once adapters exist.
