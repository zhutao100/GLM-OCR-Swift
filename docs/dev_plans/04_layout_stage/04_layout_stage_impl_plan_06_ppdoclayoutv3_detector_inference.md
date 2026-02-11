# Phase 04.6 Implementation Plan — PP-DocLayout-V3 detector: inference outputs + postprocess wiring

## Goal
Implement PP-DocLayout-V3 inference locally in MLX Swift and produce the raw outputs needed by postprocess:
- `scores`, `labels`, `boxes`, `order_seq`
- `polygon_points` (if available; otherwise synthesize polygons from bbox)

Then wire inference → postprocess (Phase 04.3) to produce ordered regions.

This is the largest Phase 04 sub-task; keep it narrowly scoped to detector parity and measurable output invariants.

## Prerequisites
- Phase 04.5 (snapshot download, processor, weights inventory).
- Phase 04.3 (postprocess exists and is unit-tested).

## Scope
### 1) Model + weights mapping (MLX Swift)
Add `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`:
- Implement the HF Transformers `PPDocLayoutV3ForObjectDetection` equivalent in MLX Swift.
- Ensure the forward pass returns a typed output struct with:
  - `scores`, `labels`, `boxes`, `orderSeq`, `polygonPoints?`

Weight loading requirements:
- Use `WeightsLoader` to load all tensors.
- Map/reshape/cast into MLXNN layers deterministically.
- Fail with typed errors on:
  - missing key
  - incompatible shape
  - unexpected dtype that cannot be safely cast

### 2) Detector API
Extend `PPDocLayoutV3Detector`:
- `func detect(ciImage: CIImage) async throws -> [OCRRegion]` (or an adapter-local region type that later converts to `OCRRegion`)
  - preprocess image
  - run model forward
  - normalize boxes/polygons to 0–1000
  - call postprocess to get ordered regions (with `taskType` derived from config mappings)

### 3) Ordering fallback
If the chosen snapshot does not provide `order_seq`:
- fallback to a stable `(y1, x1)` sort
- record a diagnostic note (log/debug-only) so the behavior difference is visible.

## Optional integration test (skipped by default)
If env var `LAYOUT_SNAPSHOT_PATH` is set:
- load model + run a forward pass on a bundled tiny image
- assert:
  - output arrays have consistent lengths
  - postprocess returns a non-empty region list
  - all emitted bboxes are within `[0, 1000]` and satisfy `x1 < x2`, `y1 < y2`

## Verification
- `swift test`

## Exit criteria
- Detector can run end-to-end on a real snapshot (opt-in) and produces ordered regions suitable for downstream cropping + OCR.

## Implementation note (2026-02-10)
The current `PPDocLayoutV3Model` implementation is an **encoder-only subset** (no deformable decoder) that still emits the raw detection invariants needed by `PPDocLayoutV3Postprocess`:
`scores`, `labels`, `boxes`, `order_seq` (with polygons synthesized from bbox when absent).

Rationale + follow-ups are captured in `docs/decisions/0003-ppdoclayoutv3-encoder-only-inference.md`.

Next step for parity: `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_08_ppdoclayoutv3_parity_golden.md`.
