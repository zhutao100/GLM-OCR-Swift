# Architecture

## Design goals

- Keep the runtime native to Swift and local MLX inference.
- Separate model-agnostic primitives from model-specific policy.
- Keep the CLI and app thin: they should orchestrate, not own model logic.
- Preserve deterministic seams for testing and parity work.

## Module Boundaries

### `VLMRuntimeKit`

Model-agnostic runtime primitives live here.

- `ModelStore`
  - Hugging Face snapshot download and cache resolution
- `TokenizerKit`
  - shared prompt/template helpers such as image-placeholder splitting
- `OCRTypes` and `OCRDocumentTypes`
  - public OCR protocols, result types, structured document types
- `OCRBlockListExport`
  - canonical examples-style block-list JSON export
- `PDFPagesSpec`
  - shared CLI/app page-selection parsing and resolution
- `VisionIO`
  - image/PDF decode, page count, raster conversion, resize helpers, tensor conversion, region cropping
- `MarkdownImageCropper`
  - converts Markdown image placeholders into cropped image files when an export directory exists
- `Generation`
  - model-agnostic generation facade and KV cache primitives
- `Weights`
  - safetensors helpers that adapters build on

`VLMRuntimeKit` must not learn GLM-OCR- or PP-DocLayout-V3-specific token, config, or label policy.

### `GLMOCRAdapter`

GLM-OCR-specific inference and orchestration live here.

- `GLMOCRDefaults`
  - default model ID, revision, and snapshot globs
- `GLMOCRConfig`, `GLMOCRTokenizer`
  - config decoding and tokenizer validation
- `GLMOCRProcessor`, `GLMOCRChatTemplate`
  - task prompt policy and GLM-specific token layout
- `GLMOCRImageProcessor`
  - resize, normalization, parity-related preprocessing knobs, and crop-level preprocess inspection helpers
- `GLMOCRModel`
  - weights, forward pass, and greedy decode
- `GLMOCRPipeline`
  - direct OCR for one image or one PDF page, plus multi-page non-layout PDF orchestration
- `GLMOCRLayoutPipeline`
  - composition layer that runs layout detection, crops regions, dispatches per-region OCR, and merges the result

### `DocLayoutAdapter`

PP-DocLayout-V3-specific layout detection lives here.

- `PPDocLayoutV3Defaults`
  - default model ID, revision, and download globs
- `PPDocLayoutV3Config`, `PPDocLayoutV3PreprocessorConfig`
  - minimal snapshot config decoding
- `PPDocLayoutV3Processor`
  - layout preprocessing
- `PPDocLayoutV3Mappings`
  - native label to OCR-task and visualization policy
- `PPDocLayoutV3Model`
  - MLX model and weight-loading logic
- `PPDocLayoutV3Postprocess`
  - NMS, containment merge, and reading-order logic
- `PPDocLayoutV3Detector`
  - snapshot loading plus inference and postprocess wiring
- `LayoutResultFormatter`
  - ordered regions to merged Markdown and `OCRDocument`

### `GLMOCRCLI`

The CLI is responsible for:

- argument parsing
- snapshot resolution/download
- choosing layout vs non-layout execution
- PDF page selection through `PDFPagesSpec`
- writing optional JSON exports
- printing Markdown to stdout

Current behavior:

- layout mode defaults on for PDFs and off for non-PDF inputs
- `--layout-parallelism` accepts `auto`, `1`, or `2`; runtime concurrency stays capped at `2`
- `--task` affects only non-layout mode
- `--generation-preset` selects a repo-owned decode preset; the default CLI/app preset is `default-greedy-v1`
- `--emit-json` and `--emit-ocrdocument-json` require layout mode

### `GLMOCRApp`

The app is intentionally small.

- drag and drop one image or PDF
- choose task, layout mode, page spec, and max tokens
- download/load models
- run one OCR request
- display Markdown output
- keep structured JSON in memory for future export UI
- auto-enable layout mode when a PDF is dropped and default PDF page selection to `all`

The app is not yet a full document workbench. Queueing, export UI, model management, and packaging remain future work.

## Runtime Flows

### Non-layout OCR

```text
CLI/App input
  -> VisionIO (image load or PDF render)
  -> GLMOCRImageProcessor
  -> GLMOCRProcessor prompt
  -> GLMOCRChatTemplate input IDs
  -> GLMOCRModel + GreedyGenerator
  -> OCRResult(text, diagnostics)
```

Notes:

- `GLMOCRPipeline.recognizePDF` loops selected pages and joins Markdown with blank lines.
- Non-layout PDF OCR uses `PDFPagesSpec` so CLI and app page semantics stay aligned.
- Runtime image tensors align to the loaded GLM vision-weight dtype by default; `GLMOCR_ALIGN_VISION_DTYPE=0` or `GLMOCR_VISION_INPUT_DTYPE=...` can override that for debugging.

### Layout OCR

```text
CLI/App input
  -> VisionIO (page image)
  -> PPDocLayoutV3Detector
  -> ordered OCR regions
  -> VisionIO.cropRegion for each region
  -> GLMOCRPipeline per region
  -> LayoutResultFormatter
  -> OCRResult(text, document, diagnostics)
```

Current implementation details:

- region task type is chosen from `PPDocLayoutV3Mappings`
- `GLMOCRLayoutPipeline` can run region OCR with `auto`, `1`, or `2` workers, capped at `2`
- the common layout path reuses one loaded page image for both layout detection and region cropping
- Layout OCR keeps the Core Image resize path as the general default, but adaptively switches short, wide text-line crops to the deterministic CPU bicubic backend; `GLMOCR_PREPROCESS_BACKEND` remains an explicit override for debugging/parity probes.

## Outputs And Artifacts

- Default CLI output
  - Markdown to stdout

- Layout-mode exports
  - `--emit-json` writes examples-style block-list JSON
  - `--emit-ocrdocument-json` writes structured `OCRDocument` JSON, including region polygons when layout masks provide them
- layout OCR currently applies polygon crops only for table regions; formula polygons are preserved in `OCRDocument` while OCR uses bbox crops

- Generated validation artifacts
  - `examples/result/*` from `scripts/run_examples.sh`
  - `examples/eval_records/latest/*` from `scripts/verify_example_eval.sh`

If an export directory exists, `MarkdownImageCropper` can materialize region-image placeholders into `imgs/` files next to the JSON output.

## Current Gaps

- Quality/parity maintenance continues on hard examples and eval hygiene; see `docs/dev_plans/quality_parity/tracker.md`.
- The maintained generation surface is intentionally narrow: `default-greedy-v1` and `parity-greedy-v1` are the only shipped presets, and broader preset families stay out of scope unless the parity contract starts depending on them.
- Broad corpus coverage remains report-only through `scripts/verify_example_eval.sh`; the opt-in integration lane protects only the current stable subset.
- Large-PDF performance is still pragmatic rather than optimized.
- The app remains a scaffold rather than a packaged end-user product.

## Change Rules

- Keep `VLMRuntimeKit` model-agnostic.
- Add new model families as new adapters under `Sources/ModelAdapters/`.
- When the public runtime shape or cross-module contracts change, update this doc and add an ADR if the decision is meant to endure.
- For parity-sensitive changes, follow `docs/golden_checks.md` and the quality tracker rather than ad hoc one-off workflows.
