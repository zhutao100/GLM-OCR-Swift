# Architecture

## Module boundaries

### `VLMRuntimeKit` (model-agnostic)

Responsibilities:

- `ModelStore`: Hugging Face Hub snapshot download + local cache conventions (**implemented**)
- `TokenizerKit`: prompt/template helpers (placeholder splitting + task→instruction mapping; **implemented**)
- `OCRTypes`: shared pipeline protocol + result types (including optional structured document output; **implemented**)
- `VisionIO`: vision IO helpers
  - image file → `CIImage` (**implemented**)
  - PDF page rendering + CIImage→MLX tensor conversion (**implemented**)
  - normalized bbox/polygon region crop (**implemented**)
- `Generation`: model-agnostic generation façade (`CausalLM` + wrapper; **implemented**)
  - KV cache primitives (**implemented**); streaming output (**planned**)
- `Weights`: safetensors loading helpers (**implemented**; model-specific transforms live in adapters)

### `GLMOCRAdapter` (model-specific)

Responsibilities:

- `GLMOCRDefaults`: default model id/revision + snapshot download globs (**implemented**)
- `GLMOCRConfig`: parse model config metadata (**implemented**)
- `GLMOCRTokenizer`: load tokenizer + validate special token IDs (**implemented**)
- `GLMOCRProcessor`: model-specific prompt policy (**implemented**)
- `GLMOCRChatTemplate`: GLM-OCR chat-template tokenization (**implemented**)
- `GLMOCRImageProcessor`: GLM-OCR resize/normalize policy (**implemented**)
- `GLMOCRModel`: model definition + weight-loading + forward pass + greedy decode (**implemented**)
- `GLMOCRPipeline`: orchestration actor; conforms to `OCRPipeline` (**implemented**)
- `GLMOCRLayoutOptions`: layout-mode concurrency policy (**implemented**)
- `GLMOCRLayoutPipeline`: layout detection → region OCR → merge; conforms to `OCRPipeline` (**implemented**)

### `DocLayoutAdapter` (layout-specific)

Responsibilities:

- `PPDocLayoutV3Defaults`: model id/revision + snapshot download globs (**implemented**)
- `PPDocLayoutV3Config`: minimal `config.json` decoding (e.g. `id2label`) (**implemented**)
- `PPDocLayoutV3Processor`: resize/normalize policy (**implemented**)
- `PPDocLayoutV3Mappings`: layout label → task/kind policy (**implemented**)
- `PPDocLayoutV3Model`: MLX inference + weight-loading (encoder-only subset; **implemented**)
- `PPDocLayoutV3Postprocess`: NMS + containment merge + ordering (**implemented**)
- `PPDocLayoutV3Detector`: snapshot load + inference + postprocess wiring (**implemented**)
- `LayoutResultFormatter`: regions → merged Markdown (**implemented**)

### `GLMOCRApp` (SwiftUI)

Responsibilities:

- Minimal UI scaffold:
  - drag/drop a single file (image/PDF)
  - show download status (via `Progress` callback)
  - run a single recognition attempt and display output/error
  - optional “Layout mode” toggle (default on for PDFs); keeps structured JSON in memory for later export

Planned (Phase 05):

- job queue, cancellation, progress per job, export
- model manager screen for download status + storage location

## Dataflow (MVP)

```
Image/PDF -> VisionIO -> GLMOCRImageProcessor -> GLMOCRProcessor(prompt)
     -> GLMOCRChatTemplate + GLMOCRModel.generate -> OCRResult(text + document? + diagnostics)
```

## Dataflow (layout mode)

```
PDF page -> VisionIO -> PPDocLayoutV3Detector -> [regions]
     -> VisionIO.cropRegion -> GLMOCRPipeline(recognize CIImage per region)
     -> LayoutResultFormatter -> OCRResult(text + document)
```

### Current implementation note (2026-02-10)

Phase 03 MVP and Phase 04 layout mode now run end-to-end for a single image or a single PDF page:

- decode (image / PDF page render),
- resize/normalize → `pixelValues`,
- build GLM-OCR chat-template `input_ids` with aligned image placeholders,
- greedy token-by-token decode (with KV cache).

Layout mode additionally performs:

- PP-DocLayout-V3 detection → ordered regions,
- region crop → per-region GLM-OCR (text/table/formula),
- `LayoutResultFormatter` merge into Markdown + `OCRDocument`.

Remaining work is largely “quality + UX”: parity validation vs the official MLX Python example, multi-page/document orchestration, and app export/UX polish.

## Numerical parity & golden checks

When porting models (or changing preprocessing/generation), use the opt-in golden workflow described in `docs/golden_checks.md` to keep `swift test` fast by default while still enabling deterministic parity checks when needed.

## Extension points

- Add new model adapters under `Sources/ModelAdapters/*`
- Consolidation to a multi-model app is a mechanical refactor once adapters exist.
