# Multi-page PDF support — plan options

**Status (2026-02-13):** draft (design/options); Option B is recommended below.

**Implemented (2026-02-17):** Option B shipped (with `--page` removed outright); see `docs/dev_plans/multi_page_pdf/tracker.md`.

Below are three implementation plans (from “surgical” to “proper API”) to replace `--page` with an optional fuzzy `--pages` and add a matching page specifier in the SwiftUI app, while keeping the **multi-page Markdown/JSON output style** consistent with `examples/reference_result/GLM-4.5V_Pages_1_2_3`.

---

## Parsing spec (shared across all options)

### CLI/App input grammar (fuzzy)

Accept (case-insensitive, whitespace-tolerant):

* omitted → **ALL pages** (PDF only)
* `all` → **ALL pages**
* `1` → page **1**
* `1-3` or `[1-3]` → pages **1,2,3**
* `1,2,4` → pages **1,2,4**
* Mixed lists allowed: `1, [3-5], 9`

### Normalization rules

* Pages are **1-based** at the API boundary (consistent with current `VisionIO.loadCIImage(fromPDF:page:)`).
* Deduplicate and sort ascending (stable output).
* Disallow mixing `all` with other tokens (error), to avoid accidental “oops I OCR’d everything” runs.
* Validate:

  * page must be `>= 1`
  * if PDF page count is known: page must be `<= pageCount`
  * invalid tokens → a clear error (`"--pages: could not parse token '…'"`)

### Indexing + output invariants

These are easy to get subtly wrong; writing them down up-front helps keep CLI/App/tests aligned.

* **User-facing pages are 1-based** (`--pages 1` means “first page”).
* **`OCRPage.index` is 0-based** (see `Sources/VLMRuntimeKit/OCRDocumentTypes.swift`).
* Layout Markdown image placeholders also use **0-based** `pageIndex`:

  * `![](page=<pageIndex>,bbox=[...])` where `<pageIndex> == OCRPage.index`.
  * When rendering PDF page `p` (1-based), use `pageIndex = p - 1`.

* For non-contiguous selections (e.g. `--pages 1,3`), keep `OCRPage.index` as the original PDF index (`0` and `2`), even if there are gaps.

### Implementation shape

Create a single shared type in `VLMRuntimeKit` so CLI + App don’t diverge:

```swift
public enum PDFPagesSpec: Sendable, Equatable {
    case all
    case explicit([ClosedRange<Int>]) // 1-based ranges, normalized + merged
}

public enum PDFPagesSpecError: Error, Sendable { ... }

public extension PDFPagesSpec {
    static func parse(_ raw: String?) throws -> PDFPagesSpec
    func resolve(pageCount: Int) throws -> [Int] // 1-based list
}
```

Also add a PDF page count helper:

* `VisionIO.pdfPageCount(url:) -> Int`

---

## Option A — Minimal surface change (loop in CLI + App; no pipeline API changes)

### What changes

**Keep**:

* `GLMOCRPipeline.recognize(.file(url, page:))` (single page)
* `GLMOCRLayoutPipeline.recognize(.file(url, page:))` (single page)

**Add**:

* `--pages: String?` (replacing `--page`)
* CLI loops pages and aggregates results
* App adds a pages text field and loops pages

### Code touchpoints

#### 1) CLI flag replacement

File: `Sources/GLMOCRCLI/GLMOCRCLI.swift`

* Replace:

  * `@Option var page: Int = 1`
  * validation `page > 0`
* With:

  * `@Option(help: "PDF pages...") var pages: String?`
  * validation: if `pages != nil` then must be parseable and non-empty

Behavior:

* If input is PDF:

  * `pages == nil` → resolve to all pages
* If input is not PDF:

  * `pages != nil` → either **error** (“only valid for PDFs”) or ignore (I’d error)

#### 2) Aggregation logic in CLI

Layout mode (`GLMOCRLayoutPipeline`):

* For each selected page:

  * call `pipeline.recognize(.file(inputURL, page: p), ...)`
  * collect `result.text` (Markdown for that page)
  * collect `result.document.pages[0]` (should be exactly one page per call)
* After loop:

  * `let mergedPages = collectedPages.sorted { $0.index < $1.index }`
  * `let mergedDocument = OCRDocument(pages: mergedPages)`
  * `let markdown = pageMarkdowns.joined(separator: "\n\n")` (matches `LayoutResultFormatter.format(pages:)` behavior)
  * Emit JSON exports from `mergedDocument`

Non-layout mode (`GLMOCRPipeline`):

* For each page:

  * `pipeline.recognize(.file(url, page: p), ...)`
* Join text with `\n\n` between pages (no headers), so it reads like a continuous document (closest to examples style).

#### 3) Cropping / image replacement (CLI)

Today the CLI re-renders one page image for cropping. For multi-page:

* Extract referenced pages from placeholders:

  * `let refs = MarkdownImageCropper.extractImageRefs(markdown)`
  * `let neededPageIndices = Set(refs.map(\.pageIndex))`
* Build `pageImages` sized to `max(neededPageIndices)+1` (0-based indexing).
* Render only needed PDF pages (`VisionIO.loadCIImage(fromPDF: url, page: pageIndex + 1, dpi: ...)`); use placeholders for other indices.
* Re-run `MarkdownImageCropper.cropAndReplaceImages(...)`

This keeps the “examples/reference_result/*” behavior: Markdown contains `![Image p-i](imgs/...)`, with images written to `<outputDir>/imgs`.

#### 4) App page specifier (simple)

File: `Sources/GLMOCRApp/ContentView.swift`

* Add a `TextField("Pages", text: $pagesSpec)` visible only for PDFs.
* Default to `"all"` (or empty meaning “all”).
* On Run:

  * resolve pages (if PDF), loop calls like CLI does, aggregate output.

### Pros / cons

✅ Fastest to ship; minimal API churn
✅ Pipelines remain single-page; low risk
❌ Aggregation logic duplicated in CLI and App (unless you factor into a helper)
❌ Harder to add streaming/progress per page later without refactor

### Tests to add

* `Tests/VLMRuntimeKitTests/PDFPagesSpecTests.swift` (parser + resolver)
* Extend `LayoutExamplesParityIntegrationTests` with a new test:

  * Input: `examples/source/GLM-4.5V_Pages_1_2_3.pdf`
  * Expected: `examples/reference_result/GLM-4.5V_Pages_1_2_3/*.md/.json`
  * Implement aggregation in test exactly like CLI does

---

## Option B — Add “multi-page entrypoints” to pipelines (recommended)

This keeps CLI/App thin and pushes “how to merge pages into examples-style output” into the adapter layer.

### What changes

Add new methods:

* In `GLMOCRLayoutPipeline`:

  * `recognizePDF(url:pagesSpec:options:) -> OCRResult` (multi-page; task is ignored in layout mode)
* In `GLMOCRPipeline` (non-layout):

  * `recognizePDF(url:pagesSpec:task:options:) -> OCRResult` (multi-page plain text)

### Code touchpoints

#### 1) Shared page spec in `VLMRuntimeKit`

New file:

* `Sources/VLMRuntimeKit/PDFPagesSpec.swift`

Add:

* `VisionIO.pdfPageCount(url:)`

#### 2) `GLMOCRLayoutPipeline` multi-page method

File: `Sources/ModelAdapters/GLMOCR/GLMOCRLayoutPipeline.swift`

Pseudo-flow:

1. Validate `url` is a PDF (if not, prefer throwing a clear error to avoid surprising behavior).
2. Get `pageCount` once (`VisionIO.pdfPageCount`).
3. Resolve `pages: [Int]` (1-based; sorted/deduped).
4. For each `p` in `pages` (sequential for stability; check cancellation between pages):

   * call existing single-page `recognize(.file(url, page: p), ...)`
   * append `result.text` to `pageMarkdowns`
   * append `result.document.pages[0]` to `collectedPages`
5. Merge:

   * `let pages = collectedPages.sorted { $0.index < $1.index }` (0-based indices)
   * `let markdown = pageMarkdowns.joined(separator: "\n\n")` (matches examples-style multi-page formatting)
   * `let doc = OCRDocument(pages: pages)`
   * return `OCRResult(text: markdown, document: doc, diagnostics: merged)`

Diagnostics merge:

* Keep `modelID/revision`
* Optionally accumulate per-page timings (or just keep totals)

#### 3) CLI becomes “parse pages + call pipeline.multiPage”

File: `Sources/GLMOCRCLI/GLMOCRCLI.swift`

* CLI resolves `PDFPagesSpec` and calls the multi-page pipeline method.
* JSON emit uses `result.document` directly (already multi-page).

Cropping:

* Prefer building `pageImages` from `MarkdownImageCropper.extractImageRefs(result.text)` so you only render pages that actually contain image placeholders.

#### 4) App becomes “pages text field + call pipeline.multiPage”

File: `Sources/GLMOCRApp/ContentView.swift`

* Much simpler: call `pipeline.recognizePDF(...)`

### Pros / cons

✅ Single source of truth for page resolution + document/markdown merging.
✅ Cleaner CLI/App; less duplication.
✅ Easier to extend later (progress callbacks, cancellation, per-page diagnostics).
❌ Slightly larger public API surface in `GLMOCRAdapter`.

### Tests

Same as Option A, but the multi-page parity test should call `recognizePDF(...)` directly.

---

## Option C — “Scalable PDF runner” (streaming rendering + optional per-page incremental output)

This is Option B plus two scalability upgrades:

1. **Avoid reopening/reparsing PDF per page**
2. Support **incremental output** (useful for big PDFs)

### What changes

* Add a small `PDFRenderSession` in `VisionIO`:

  * holds a `PDFDocument`
  * exposes `pageCount`
  * renders requested pages at given DPI

* Add optional CLI flag:

  * `--stdout-per-page` (or similar) to print each page as it completes (still also able to output merged final doc)

### Pros / cons

✅ Best performance for large PDFs
✅ Better UX (early results)
❌ More code + more surface area
❌ More decisions around streaming format (page separators, partial JSON, etc.)

---

## Required UX changes (App) — suggested implementations

You said “adds a corresponding page picker/specifier.” Here are two concrete UI levels:

### UI Level 1 (minimal, fastest)

* Show when PDF is selected:

  * `Pages:` text field (placeholder: `all | 1 | 1-3 | 1,2,4 | [1-3]`)
* Show validation inline (red text)
* Default: empty / `all`

### UI Level 2 (picker-ish, still reasonable)

* Toggle: `All pages`
* If off:

  * segmented control: `Single` / `Range` / `List`
  * Single: Stepper + TextField
  * Range: two Steppers (start/end)
  * List: tokenized input `1,2,4`
* Under the hood, still serialize to the same `PDFPagesSpec` string for the parser

---

## Acceptance criteria checklist

1. CLI:

* `--page` removed (or kept as deprecated alias if you want a transition)
* `--pages` optional
* PDF + no `--pages` → processes **all** pages
* PDF + `--pages 1-3` or `--pages [1-3]` → processes pages 1–3
* PDF + `--pages 1,2,4` → processes pages 1,2,4
* Non-PDF + `--pages ...` → deterministic behavior (recommend: error)

2. Output:

* Layout mode multi-page Markdown joins pages with `\n\n` and uses the same placeholder/cropper conventions so it matches `examples/reference_result/GLM-4.5V_Pages_1_2_3`
* Block-list JSON export is a `[[...], [...], ...]` list of pages (already supported by `OCRDocument.toBlockListExport()` when `document.pages` is multi-page)

3. App:

* Has a page spec UI
* Uses the same parsing/resolution logic as CLI

4. Tests:

* Parser unit tests
* Multi-page examples parity test using `examples/source/GLM-4.5V_Pages_1_2_3.pdf`

---

## Recommendation

Go with **Option B**:

* It keeps the “multi-page aggregation + examples-style formatting” logic in one place (adapter layer), and makes both CLI and SwiftUI app trivial consumers.
* It also naturally supports your future “Phase 05 multi-page workflows” roadmap without rework.

If you want, I can turn Option B into a PR-sized task breakdown (file-by-file checklist with proposed function signatures and where to thread cancellation/progress).
