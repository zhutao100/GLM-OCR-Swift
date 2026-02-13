# Phase 04.3 Implementation Plan — Layout postprocess (NMS + merge + ordering)

> Status: Complete (2026-02-12) — implemented; kept in archive for reference.

## Goal
Port the official PP-DocLayout-V3 postprocess logic into deterministic Swift primitives so that:
- raw detector outputs can be converted into ordered regions,
- unit tests can cover tricky cases (NMS/containment/order) without needing a real model.

Primary reference: `../GLM-OCR/glmocr/utils/layout_postprocess_utils.py`.

## Prerequisites
- Phase 04.2 (`DocLayoutAdapter` exists, config + label/task mappings are available).
- Phase 04.1 for public bbox/polygon runtime types.

## Scope
Add `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Postprocess.swift`:

### Inputs
Define an adapter-local raw output container (names can differ, but keep them explicit):
- `scores: [Float]`
- `labels: [Int]` (or `[String]` if the model emits label names)
- `boxes: [OCRNormalizedBBox]` (recommended) or pixel-space boxes + image size for normalization
- `orderSeq: [Int]?` (reading order key; optional)
- `polygons: [[OCRNormalizedPoint]]?` (optional)

### Behavior (mirror official algorithms)
- Class-aware NMS using the same `iou_same`/`iou_diff` constants.
- Optional `unclip_ratio` expansion if the model/config requires it.
- Containment-based merge modes (`large`/`small`) using the per-class map from config.
- Ordering:
  - Prefer `order_seq` sorting when available.
  - If missing, fallback to a stable reading order sort like `(bbox.y1, bbox.x1)` and emit a diagnostic (log or debug-only trace) so the difference is discoverable.

### Output
Convert to an ordered list of regions (adapter-local or directly to public `OCRRegion`) with:
- `index`: contiguous index after filtering/merges
- `nativeLabel`: preserved label name
- `taskType`: derived from `labelTaskMapping`
- `bbox` normalized to **0–1000**
- `polygon` normalized to **0–1000** (synthesize from bbox if absent)

## Tests (default-running)
Add `Tests/DocLayoutAdapterTests/PPDocLayoutPostprocessTests.swift` with synthetic boxes:
- NMS keeps the best score and removes overlaps (same-class and different-class paths).
- Containment merges behave for both “large” and “small” policies.
- Ordering respects `order_seq` and falls back deterministically when absent.

## Verification
- `swift test`

## Exit criteria
- Postprocess results are deterministic for the same inputs.
- Unit tests cover NMS, containment merge, and ordering (including fallback).
