# Phase 04.7 Implementation Plan — Layout orchestration + concurrency + CLI/App wiring

> Status: Implemented (2026-02-10).

## Goal
Deliver the Phase 04 end-to-end user story:
**PDF page → layout regions → crop → per-region GLM-OCR → merge into Markdown**, with:
- structured `OCRDocument` output,
- auto-tuned concurrency + cancellation,
- CLI/App flags to turn layout mode on/off and emit JSON.

## Prerequisites
- Phase 04.6 (layout detector inference produces ordered regions).
- Phase 04.4 (formatter exists).
- Phase 04.1 (crop helper exists).

## Scope
### 1) New orchestration actor (GLMOCRAdapter)
Add `Sources/ModelAdapters/GLMOCR/GLMOCRLayoutPipeline.swift`:

Responsibilities:
- Ensure both models are loaded:
  - `GLMOCRPipeline.ensureLoaded()`
  - `PPDocLayoutV3Detector.ensureLoaded()` (in `DocLayoutAdapter`)
- Page ingestion:
  - reuse existing PDF render path (`VisionIO.loadCIImage(fromPDF:page:dpi:)`)
- Layout detection:
  - run detector on the full page CIImage; get ordered regions
- Region OCR:
  - for each region with `taskType != .skip`:
    - crop CIImage via `VisionIO.cropRegion`
    - run OCR using GLM-OCR with task preset mapping:
      - `.text → OCRTask.text`, `.table → .table`, `.formula → .formula`
    - store content into `OCRRegion.content`
  - for `.skip` (images): keep the region with `content = nil` for markdown placeholders
- Merge:
  - call `LayoutResultFormatter` to produce merged Markdown + `OCRDocument`
  - return `OCRResult(text: ..., document: ...)`

### 2) Refactor `GLMOCRPipeline` for CIImage inputs (internal-only)
In `Sources/ModelAdapters/GLMOCR/GLMOCRPipeline.swift`:
- extract the “CIImage → pixelValues → generate” part into an internal helper:
  - `func recognize(ciImage: CIImage, task: OCRTask, options: GenerateOptions) async throws -> OCRResult`
- keep the public `recognize(.file(...))` behavior unchanged.

### 3) Auto-tuned parallelism + cancellation
Add `GLMOCRLayoutOptions`:
- `var concurrency: LayoutConcurrencyPolicy = .auto`
- `var maxConcurrentRegionsCap: Int = 2` (hard safety cap)
- `.auto` computation:
  - use `ProcessInfo.processInfo.physicalMemory`:
    - `< 24GB`: 1
    - `>= 24GB`: 2
  - clamp to `[1, maxConcurrentRegionsCap]`

Implementation:
- use `withThrowingTaskGroup` to OCR regions concurrently up to the computed limit (async semaphore recommended)
- call `Task.checkCancellation()`:
  - before layout detection
  - before each crop
  - before scheduling each region
- on cancellation or first thrown error:
  - cancel remaining group tasks
  - return/throw promptly (no partial success in Phase 04)

### 4) CLI/App wiring
#### CLI (`Sources/GLMOCRCLI/GLMOCRCLI.swift`)
- Add flags:
  - `--layout/--no-layout`
    - default: `true` for PDFs, `false` for non-PDF unless explicitly set
  - `--layout-parallelism auto|1|2` (default `auto`)
  - `--emit-json <path>` (optional): write canonical block-list JSON (examples-compatible; `[[{index,label,content,bbox_2d}, ...], ...]`)
  - `--emit-ocrdocument-json <path>` (optional): write `OCRResult.document` as structured `OCRDocument` JSON (pretty-printed)
- When layout enabled, use `GLMOCRLayoutPipeline`; otherwise keep current `GLMOCRPipeline`.

#### App (`Sources/GLMOCRApp/ContentView.swift`)
- Minimal Phase 04 change:
  - add a toggle “Layout mode” (default on for PDFs)
  - store structured JSON in memory for later export (Phase 05 can add UI)

## Verification
### Tests
- `swift test`

### Manual CLI check (Phase 04 exit criteria)
- `swift run GLMOCRCLI --input <A4_scanned.pdf> --page 1 --layout --emit-json out.json`
  - `stdout`: Markdown with sane reading order; if images are present, the CLI writes crops to `./imgs/` (relative to `out.json`) and replaces image placeholders.
  - `out.json`: canonical block-list JSON (examples-compatible)
  - Use `--emit-ocrdocument-json` for the structured `OCRDocument` schema.

### Cancellation check
- Start a multi-region job, then cancel (Ctrl-C in CLI) and confirm region tasks stop quickly.

## Exit criteria
- Phase 04 overall exit criteria are met (see index plan).
- Conventions respected: `VLMRuntimeKit` remains model-agnostic; PP-DocLayout-V3 code lives outside `GLMOCRAdapter`.
