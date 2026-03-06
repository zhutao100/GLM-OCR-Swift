# Phase 02 - polygon and mask geometry parity

**Goal:** move from bbox-only geometry to upstream-faithful mask-derived polygon handling when PP-DocLayout-V3 provides the necessary mask outputs, while only enabling polygon OCR crops where parity evidence is positive.

**Status (2026-03-06):** completed. The DocLayout adapter now keeps mask-aligned detections through postprocess, derives polygons from masks when available, and falls back to bbox polygons explicitly when mask geometry is missing or invalid. Structured `OCRDocument` output preserves those polygons, and the runtime uses polygon crops for table OCR while formula OCR intentionally stays on bbox crops after broader polygon-crop trials regressed checked-in examples.

---

## 1. Why this phase matters

Dense pages, formulas, and some tables are disproportionately harmed by bbox-only crops. Even if the correct region is selected, rectangular crops can drag in neighboring text, rule lines, captions, or adjacent formulas.

Mask-derived polygons reduce that contamination and align better with the upstream postprocess behavior exposed in the selected `transformers` files.

---

## 2. Scope

### In scope

- exposing `out_masks` or equivalent final masks from the DocLayout path
- selecting the masks using the same query-selection logic as labels/scores/boxes
- contour extraction and polygon simplification
- fallback rules when masks are missing or unusable
- normalized polygon storage and polygon-aware cropping
- targeted formula/table parity checks

### Out of scope

- decoder/generation changes
- markdown export formatting changes unrelated to geometry

---

## 3. Required behavior contract

The Swift path should preserve the following behavior classes:

1. **happy path**
   - valid mask -> contour -> simplified polygon -> normalized polygon points -> polygon-aware crop or polygon-preserving export according to the validated class policy

2. **fallback path**
   - invalid box -> rectangle polygon
   - no contour -> rectangle polygon
   - too few points -> rectangle polygon
   - obviously degenerate polygon -> rectangle polygon

3. **recording path**
   - downstream block models and JSON export should preserve polygon information when available

---

## 4. Implementation strategy

## Workstream A - mask exposure and selection

Tasks:

1. expose final masks from the PP-DocLayout output path
2. ensure masks are filtered with the same top-query selection used for boxes/scores/labels
3. add tests confirming mask-to-region alignment is stable

## Workstream B - contour extraction spike

Recommended search order:

1. evaluate an Apple-native binary-contour route if it can preserve semantics closely enough
2. if that drifts too much, implement a compact local external-contour path
3. use heavier validation tooling only as a temporary parity oracle, not as a required shipping dependency

## Workstream C - polygon normalization and crop support

Tasks:

1. preserve polygon coordinates in a normalized contract consistent with the existing bbox path
2. make `VisionIO` able to crop from polygons deterministically
3. ensure polygons round-trip through OCR result models and JSON export without silent loss

## Workstream D - targeted end-to-end validation

Target examples:

- `paper`
- `page`
- formula-heavy PDF pages
- at least one table-dense sample

The first success criterion is not a perfect score. It is a visible reduction in contamination and a measurable gain in structure/content metrics on the targeted examples.

---

## 5. Risks

- **Contour-semantic mismatch risk:** some contour APIs may smooth or order contours differently enough to create output drift.
- **False precision risk:** a polygon path that looks more advanced but does not improve real crops is not a parity win.
- **Serialization loss risk:** polygons can be computed correctly and still be lost before export unless every downstream model preserves them.

---

## 6. Exit criteria

This phase is complete when:

- masks flow through the selected-layout path reliably
- valid masks produce non-rectangular polygons where appropriate
- polygon-aware crops are used by default only for classes that pass parity validation (currently tables)
- fallback behavior is documented and regression-tested
- formula/table-heavy examples show a measurable reduction in contamination-driven errors

The maintained export contract stays intentionally split: examples-style block-list JSON remains bbox-based for compatibility, while `OCRDocument` JSON carries polygon geometry for downstream consumers. The runtime currently uses polygon-aware crops only for table OCR; formula polygons are still exported but OCR keeps bbox crops until a future phase proves a broader policy is safe.
