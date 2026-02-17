# Multi-page PDF support

**Objective:** extend PDF OCR to multiple pages (CLI + App) by replacing `--page` with an optional fuzzy `--pages` spec. For PDFs, omitting `--pages` processes **all** pages. Output should match `examples/reference_result/GLM-4.5V_Pages_1_2_3`.

**Status (2026-02-17):** implemented (Option B) — multi-page PDF support shipped in CLI + App; `--page` removed.

## Plan options (design)
- `docs/dev_plans/multi_page_pdf/plan_options.md` (Option B recommended)

## Key decisions (lock before coding)
- **Indexing:** user `--pages` and `VisionIO.loadCIImage(fromPDF:page:)` are **1-based**; `OCRPage.index` and Markdown `![](page=<n>,bbox=...)` are **0-based** (`pageIndex = page - 1`).
- **Ordering:** resolve `--pages` into a **deduped, ascending** list for stable output (ignore user input order).
- **Non-PDF behavior:** if `--pages` is provided for a non-PDF input, **error** (avoid silent no-op).
- **Back-compat:** remove `--page` outright (no deprecated alias).

## Scope
- Runtime (`VLMRuntimeKit`):
  - `PDFPagesSpec` parser/resolver (+ unit tests).
  - `VisionIO.pdfPageCount(url:)` (+ unit tests).
- Adapters (`GLMOCRAdapter`): multi-page entrypoints that loop existing single-page logic and merge Markdown + `OCRDocument`.
- CLI (`GLMOCRCLI`): replace `--page` with `--pages`, route to multi-page entrypoints, and keep `--emit-json`/`--emit-ocrdocument-json` examples-compatible.
- App (`GLMOCRApp`): add a PDF-only pages specifier UI and use the same `PDFPagesSpec` semantics.

## Tasks (Option B)
- [x] Lock the decisions above (alias, ordering, non-PDF behavior).
- [x] Add `PDFPagesSpec` + tests (`Tests/VLMRuntimeKitTests/`).
- [x] Add `VisionIO.pdfPageCount(url:)` + tests (create a multi-page temp PDF).
- [x] Add multi-page entrypoints:
  - [x] `GLMOCRLayoutPipeline.recognizePDF(url:pagesSpec:options:)`
  - [x] `GLMOCRPipeline.recognizePDF(url:pagesSpec:task:options:)`
- [x] Update CLI flags + help + validation (`--pages` optional; PDF + omitted == all pages).
- [x] Update CLI cropping path to render **only** PDF pages referenced by Markdown placeholders (via `MarkdownImageCropper.extractImageRefs`), not every selected page.
- [x] Update App UI + wiring (PDF-only page spec input + validation).
- [x] Extend examples parity coverage for `examples/source/GLM-4.5V_Pages_1_2_3.pdf` (opt-in; requires local snapshots like the existing page-1 parity test).
- [x] Update docs (`README.md`; `docs/architecture.md` if public API shape changes).

## Exit criteria
- CLI:
  - PDF + no `--pages` == `--pages all` → processes **all pages**.
  - PDF + `--pages 1-3` and `--pages [1-3]` → processes pages 1–3 only.
  - PDF + `--pages 1,2,4` → processes pages 1,2,4 only.
  - Non-PDF + `--pages ...` → clear validation error.
- Output:
  - Layout Markdown joins pages with exactly `\n\n` (no page headers), matching `examples/reference_result/GLM-4.5V_Pages_1_2_3`.
  - `--emit-json` emits `[[...], ...]` with `count == selectedPages.count` and stable page ordering.
- App: PDF pages spec UI matches CLI semantics and runs multi-page OCR.
