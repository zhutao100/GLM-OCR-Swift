# Phase 04.4 Implementation Plan — LayoutResultFormatter (regions → Markdown)

> Status: Complete (2026-02-12) — implemented; kept in archive for reference.

## Goal
Port the official Markdown merge/formatting rules into a deterministic formatter that:
- preserves reading order,
- emits stable Markdown,
- produces a structured `OCRDocument` alongside the merged text.

Primary reference: `../GLM-OCR/glmocr/postprocess/result_formatter.py`.

## Prerequisites
- Phase 04.1 for public structured types (`OCRDocument`, `OCRPage`, `OCRRegion`).
- Phase 04.2 for `labelToVisualizationKind` (native label → `OCRRegionKind`).

## Scope
Add `Sources/ModelAdapters/DocLayout/LayoutResultFormatter.swift` (recommended location: `DocLayoutAdapter` since it’s layout-label-driven).

### Inputs
- `[OCRPage]` with `OCRRegion` items populated with `content` (nil for images / skipped).

### Behavior
Mirror `result_formatter.py` at the level of observable output:
1. Sort regions by `index`.
2. Map `nativeLabel → kind` using the visualization mapping.
3. Format `content` by kind + native label:
   - `doc_title` → `# ...`
   - `paragraph_title` → `## ...`
   - `formula` → wrap into `$ ... $` (normalize obvious variants)
   - `text` → normalize bullets and list prefixes; single newline → double newline
4. Drop empty/whitespace-only content.
5. Post-pass merges:
   - merge `formula_number` blocks into adjacent formulas (port `_merge_formula_numbers`)
   - merge hyphenated text across blocks (port `_merge_text_blocks`)
   - bullet point alignment tweaks (port `_format_bullet_points`)
6. Markdown emission:
   - For images: `![](page=<pageIndex>,bbox=[x1,y1,x2,y2])`
   - Join blocks with `\n\n`, pages with `\n\n`.

### Return
- `OCRDocument` (structured, with regions including `content`/nil)
- merged Markdown string (for `OCRResult.text`)

## Tests (default-running)
Add `Tests/DocLayoutAdapterTests/LayoutResultFormatterTests.swift` with small synthetic region lists:
- title formatting (`doc_title`, `paragraph_title`)
- formula wrapping + formula number merge
- hyphenated text merge
- image placeholder emission

## Verification
- `swift test`

## Exit criteria
- Formatter output is deterministic and covered by unit tests for the key formatting/merge rules.
