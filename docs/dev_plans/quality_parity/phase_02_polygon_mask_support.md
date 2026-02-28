# Phase 02 - polygon and mask support

**Objective:** bring the Swift layout path from bbox-only crops to mask-derived polygon crops, matching the intent of the upstream PP-DocLayout-V3 inference path closely enough to improve OCR content parity.

**Status (2026-02-27):** planned.

---

## 1. Why this phase matters

The current Swift code already supports polygon masking in `VisionIO.cropRegion(...)`, but the detector path never supplies real polygons. As a result:

- every crop is effectively rectangular
- formulas, tables, and irregular regions can include more surrounding pixels than upstream
- the OCR model has to parse extra visual noise that the reference pipeline attempts to remove

This is the most likely remaining reason formula-heavy crops still differ after structural parity was restored.

---

## 2. Upstream reference behavior to mirror

The Transformers PP-DocLayout-V3 postprocess path does the following:

1. takes final `out_masks`
2. thresholds them into binary masks
3. crops each mask to its box window
4. rescales the cropped mask back to the box size
5. extracts an outer contour and polygon approximation
6. falls back to the box rectangle when the polygon is missing or too small

The Swift plan should mirror that high-level behavior, even if the contour-extraction backend differs.

---

## 3. Swift solution search order

This phase should not assume a from-scratch contour implementation until the alternatives are evaluated.

### Option A - Apple-native contour extraction spike

**What to evaluate**

- extracting contours from binary masks using Apple-native image-analysis primitives
- whether the returned contour ordering and simplification are stable enough for parity work

**Why try it first**

- keeps the shipping path Apple-native
- minimizes dependency cost
- may be sufficient for external-contour extraction on clean binary masks

**Why it might fail parity needs**

- hidden preprocessing or contour smoothing can drift from the OpenCV-style semantics used upstream
- contour approximation behavior may not match the upstream fallback rules closely enough

### Option B - small local contour extractor

If Option A does not preserve the needed semantics, implement a narrow local solution that mirrors the upstream intent:

- binary external-contour tracing
- polygon simplification
- upstream-compatible fallback rules

This is preferred over a large dependency if the implementation remains small and testable.

### Option C - OpenCV-backed validation aid

Keep OpenCV out of the default shipping path.

If needed, use it only as a validation oracle during development for a few fixtures, not as the primary runtime dependency.

---

## 4. Recommended implementation plan

### Workstream A - plumb masks through the detector

**Files**

- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`
- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Postprocess.swift`

**Tasks**

1. extend the raw output type so final masks are available to post-process code
2. gather masks with exactly the same top-query selection used for scores/labels/boxes
3. preserve ordering consistency with `order_seq`

### Workstream B - implement polygon extraction utility

**Suggested landing zone**

- a dedicated helper under `Sources/ModelAdapters/DocLayout/` or `Sources/VLMRuntimeKit/VisionIO/`

**Tasks**

1. crop mask to the bbox window
2. resize mask to the bbox dimensions using nearest-neighbor behavior
3. extract the external contour
4. simplify to polygon points
5. normalize/fallback exactly as needed by the OCR pipeline

### Workstream C - wire polygons into crop generation

**Files**

- `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift`
- `Sources/ModelAdapters/GLMOCR/GLMOCRLayoutPipeline.swift`

**Tasks**

1. pass real polygons into `VisionIO.cropRegion(...)`
2. confirm existing polygon-mask fill stays consistent with the upstream white-fill intent
3. verify that bbox fallback still works for invalid polygons

---

## 5. Compatibility rules to preserve

The Swift path should preserve these upstream-style fallback behaviors:

- invalid or empty bbox -> rectangle fallback
- no contour found -> rectangle fallback
- fewer than four polygon points -> rectangle fallback
- polygon count mismatch vs detections -> diagnostics + rectangle fallback

This ensures the polygon feature improves crops without making the pipeline fragile.

---

## 6. Tests to add

### Unit tests

- contour extraction from a simple rectangular mask
- contour extraction from an L-shaped or irregular mask
- fallback when the mask is empty
- fallback when the extracted polygon is too small
- normalization and clamping of polygon coordinates into `[0, 1000]`

### Integration checks

Re-run at least:

- `paper`
- `page`
- `GLM-4.5V_Pages_1_2_3`

The acceptance signal is not just markdown similarity. It should also include qualitative crop inspection for formula regions.

---

## 7. Acceptance criteria

This phase is done when:

- real mask-derived polygons are available end-to-end
- bbox fallback remains robust
- formula-heavy examples show reduced contamination and improved parity signal
- the chosen contour backend is justified in docs and protected by tests
