# Tracker - gateway input preprocessing experiments

**Objective:** run a narrow, evidence-driven experiment program for deterministic lightweight gateway preprocessing, without destabilizing the repo's accepted artifact contract.

**Status (2026-03-18):** in progress; multiple Tier-1 prototypes are implemented and measured on the degraded lane, but none are accepted as default-on yet.

---

## 0. Success conditions

A candidate is accepted only when:

- it measurably improves the targeted degraded-input lane
- it does not materially regress the clean checked-in corpus
- the trigger can be expressed as a deterministic observable heuristic
- intermediate artifacts can be inspected and recorded
- the implementation stays lightweight enough for normal CLI/app use

---

## 1. Ordered workstreams

### Workstream A — build the degraded-input evaluation lane

**Goal:** create a reproducible, report-only challenge lane that stresses the kinds of defects a gateway preprocessor is meant to fix.

**Tasks**

- [x] Define a deterministic synthetic degradation recipe set over selected checked-in examples.
- [x] Start with the most relevant source images:
  - [x] `examples/source/page.png`
  - [x] `examples/source/table.png`
  - [x] `examples/source/paper.png`
  - optionally selected crops from layout-mode examples
- [x] Add at least these degradation families:
  - [x] dark-border / overscan margin injection
  - [x] small-angle skew
  - [x] perspective warp
  - [x] low-contrast / uneven illumination
  - [x] light noise / compression degradation
- [x] Record exact generation parameters so the lane is reproducible.
- [x] Keep this lane report-only until a stable signal emerges.

**Implementation**

- Manifest: `docs/dev_plans/quality_parity/gateway_preprocessing/degraded_lane_manifest.json`
- Generator: `scripts/gateway_preprocessing_generate_degraded_lane.py`
- Runner + scorer: `scripts/verify_gateway_preprocessing_degraded_lane.sh`

**Exit criteria**

- [x] one repeatable degraded-input lane exists
- [x] reports can compare baseline vs gateway branch on a defect-family basis (`--label` + `--baseline-label`)

---

### Workstream B — border / canvas cleanup

**Goal:** test whether cheap background-margin cleanup helps degraded inputs without touching interior glyph statistics too much.

**Tasks**

- [x] Add a model-agnostic border-analysis primitive in `VLMRuntimeKit`.
- [x] Implement a conservative content-box proposal with confidence scoring.
- [x] Preserve a small safety border instead of hard edge crops.
- [x] Capture before/after page artifacts for inspected examples.
- [x] Evaluate on the degraded border/margin lane.
- [ ] Evaluate on the clean corpus if considering default-on.

**Implementation**

- Model-agnostic primitive:
  - `VisionIO.proposeBorderCleanupCrop(...)` + `VisionIO.applyBorderCleanupCrop(...)` / `VisionIO.applyBorderCleanupMask(...)`
- Experiment toggles (env):
  - `GLMOCR_GATEWAY_BORDER_CLEANUP=1`
  - `GLMOCR_GATEWAY_BORDER_CLEANUP_MODE=mask|crop` (default: `mask`)
  - `GLMOCR_GATEWAY_BORDER_CLEANUP_MIN_CONFIDENCE=...` (default: `0.60`)
  - `GLMOCR_GATEWAY_BORDER_CLEANUP_MAX_ANALYSIS_DIM=...` (default: `512`)
  - `GLMOCR_GATEWAY_ARTIFACT_DIR=...` (writes before/after JPEGs + proposal JSON when the heuristic triggers)

**Current evidence (2026-03-18)**

Using the synthetic degraded lane from Workstream A:

- crop mode (`GLMOCR_GATEWAY_BORDER_CLEANUP_MODE=crop`, min_conf=0.60)
  - improves `paper_border_dark_margin` materially, but regresses `page_border_dark_margin`
  - net signal is mixed; not stable enough for default-on acceptance
- mask mode (`GLMOCR_GATEWAY_BORDER_CLEANUP_MODE=mask`, min_conf=0.60)
  - smaller deltas, but still no consistent uplift on the `page_*` degraded border case

**Decision (for now):** keep border/canvas cleanup behind experiment toggles; do not enable by default.

**Exit criteria**

- [x] content-box detection is deterministic and inspectable
- [ ] clean-corpus regressions are absent or negligible
- [ ] border-degraded examples show a meaningful improvement signal

---

### Workstream C — page crop + perspective rectification

**Goal:** improve photographed-page inputs, especially `table.png`-like cases.

**Tasks**

- [x] Implement or prototype a deterministic page-on-background detector.
- [x] Add quad estimation with confidence gating.
- [x] Add a perspective-warp helper at the model-agnostic vision layer.
- [x] Run focused A/B on `table.png` and synthetic perspective-warp cases.
- [ ] Confirm that clean scan/PDF inputs do not spuriously enter this path if considering default-on.

**Implementation**

- Model-agnostic primitive:
  - `VisionIO.proposeDocumentRectification(...)` + `VisionIO.applyDocumentRectification(...)`
  - rectangle quad via `CIDetectorTypeRectangle`, rectification via `CIPerspectiveCorrection`
- Experiment toggles (env):
  - `GLMOCR_GATEWAY_PERSPECTIVE_RECTIFY=1`
  - `GLMOCR_GATEWAY_PERSPECTIVE_MIN_CONFIDENCE=...` (default: `0.60`)
  - `GLMOCR_GATEWAY_PERSPECTIVE_MIN_AREA_FRACTION=...` (default: `0.45`)
  - `GLMOCR_GATEWAY_PERSPECTIVE_MAX_AREA_FRACTION=...` (default: `0.98`)
  - `GLMOCR_GATEWAY_PERSPECTIVE_MAX_ANALYSIS_DIM=...` (default: `768`)
  - `GLMOCR_GATEWAY_ARTIFACT_DIR=...` (writes before/after JPEGs + proposal JSON when the heuristic triggers)

**Current evidence (2026-03-18)**

Using the synthetic degraded lane from Workstream A:

- degraded lane label: `geo_rectify_v1` (baseline: `geo_baseline`)
- env: `GLMOCR_GATEWAY_PERSPECTIVE_RECTIFY=1`, `GLMOCR_GATEWAY_PERSPECTIVE_MIN_CONFIDENCE=0.60`
- by family (final overall mean deltas vs baseline):
  - `border_dark_margin`: **+0.0205**
  - `perspective_warp`: **+0.0023** (mostly `table_perspective_warp`)
- representative per-example parity uplifts vs baseline:
  - `page_border_dark_margin`: **0.7382 → 0.7647**
  - `paper_border_dark_margin`: **0.9231 → 0.9504**
  - `table_perspective_warp`: **0.9761 → 0.9830**

Known limitations from artifact inspection:

- The rectangle detector triggers reliably for photographed-page-on-contrast-background cases.
- It often does **not** trigger for the synthetic `*_perspective_warp` variants that fill with pure white (white-on-white boundary → weak quad edges).

**Decision (for now):** keep perspective rectification behind experiment toggles; do not enable by default.

**Exit criteria**

- photographed-page cases improve clearly
- false-positive triggering on clean scans stays rare
- the added latency remains acceptable

---

### Workstream D — deskew

**Goal:** test whether a small-angle deskew stage improves camera/scanner slant cases.

**Tasks**

- [x] Prototype a deterministic skew-angle estimator.
- [x] Restrict correction to high-confidence, small-angle cases first.
- [x] Evaluate page-level vs region-level application order.
- [x] Record a “no-op when uncertain” fallback.

**Implementation**

- Model-agnostic primitive:
  - `VisionIO.estimateDeskewAngle(...)` + `VisionIO.applyDeskew(...)`
  - edge-orientation histogram on a downsampled `RGBA8` analysis raster
  - correction via `CIStraightenFilter`
- Experiment toggles (env):
  - `GLMOCR_GATEWAY_DESKEW=1`
  - `GLMOCR_GATEWAY_DESKEW_STAGE=page|ocr` (default: `ocr`)
  - `GLMOCR_GATEWAY_DESKEW_MAX_ANALYSIS_DIM=...` (default: `1024`)
  - `GLMOCR_GATEWAY_DESKEW_MAX_DEG=...` (default: `5.0`)
  - `GLMOCR_GATEWAY_DESKEW_STEP_DEG=...` (default: `0.5`)
  - `GLMOCR_GATEWAY_DESKEW_EDGE_THRESHOLD=...` (default: `55`)
  - `GLMOCR_GATEWAY_DESKEW_SAMPLE_STRIDE=...` (default: `2`)
  - `GLMOCR_GATEWAY_DESKEW_IGNORE_BORDER_FRACTION=...` (default: `0.06`)
  - `GLMOCR_GATEWAY_DESKEW_MIN_APPLY_DEG=...` (default: `0.75`)
  - `GLMOCR_GATEWAY_DESKEW_MIN_CONFIDENCE=...` (default: `0.08`)
  - `GLMOCR_GATEWAY_ARTIFACT_DIR=...` (page stage only; writes before/after JPEGs + estimate JSON)

**Current evidence (2026-03-18)**

Using the synthetic degraded lane from Workstream A:

- page-level deskew (stage: `page`)
  - degraded lane label: `geo_deskew_v2` (baseline: `geo_baseline`)
  - net signal is negative on the skew family:
    - `page_skew_small_angle` parity **0.7874 → 0.7457** (regression)
  - table-like inputs sometimes improve, suggesting layout interaction rather than pure OCR gain:
    - `table_skew_small_angle` parity **0.9753 → 0.9830**
- OCR-input deskew (stage: `ocr`, applied to layout crops)
  - degraded lane label: `geo_deskew_ocr_v1` (baseline: `geo_baseline`)
  - no uplift on `page_skew_small_angle`, and a regression appears on the paper skew case:
    - `paper_skew_small_angle` parity **0.9439 → 0.9160**

**Decision (for now):** keep deskew behind experiment toggles; do not enable by default.

**Exit criteria**

- skew correction helps the skewed degraded lane
- no meaningful regressions appear on already-upright inputs

---

### Workstream E — conservative contrast normalization

**Goal:** test whether luma-only contrast correction improves faint or low-contrast text while keeping the RGB-first path intact.

**Tasks**

- [x] Prototype mild percentile stretch on luma.
- [ ] Prototype conservative luma-only CLAHE (deferred; no Core Image primitive, custom CLAHE likely too heavy for Tier 1).
- [x] Gate by measurable contrast heuristics.
- [x] Apply to OCR crops first, not layout-detector page inputs.
- [x] Capture crop-level artifacts via the existing preprocess debug path.

**Implementation**

- Model-agnostic primitive:
  - `VisionIO.proposeLumaContrastStretch(...)` + `VisionIO.applyLumaContrastStretch(...)`
  - analysis: luma percentile probe on a downsampled `RGBA8` raster (with optional border ignore)
  - apply: deterministic per-channel linear stretch in `RGBA8` space (to avoid Core Image color-space surprises)
- Experiment toggles (env):
  - `GLMOCR_GATEWAY_CONTRAST=1`
  - `GLMOCR_GATEWAY_CONTRAST_MIN_CONFIDENCE=...` (default: `0.25`)
  - `GLMOCR_GATEWAY_CONTRAST_MAX_ANALYSIS_DIM=...` (default: `512`)
  - `GLMOCR_GATEWAY_CONTRAST_IGNORE_BORDER_FRACTION=...` (default: `0.04`)
  - `GLMOCR_GATEWAY_CONTRAST_LOWER_P=...` (default: `0.02`)
  - `GLMOCR_GATEWAY_CONTRAST_UPPER_P=...` (default: `0.98`)
  - `GLMOCR_GATEWAY_CONTRAST_STRENGTH=...` (default: `0.65`)
  - `GLMOCR_GATEWAY_CONTRAST_MIN_LUMA_RANGE=...` (default: `18`)
  - `GLMOCR_GATEWAY_CONTRAST_MIN_SCALE=...` (default: `1.05`)
  - `GLMOCR_GATEWAY_CONTRAST_MAX_SCALE=...` (default: `1.60`)

**Current evidence (2026-03-18)**

Using the synthetic degraded lane from Workstream A:

- default stretch settings
  - degraded lane label: `geo_contrast_v1` (baseline: `geo_baseline`)
  - env: `GLMOCR_GATEWAY_CONTRAST=1` (defaults otherwise)
  - by family (final overall mean deltas vs baseline):
    - `low_contrast_shadow`: **+0.0001**
    - all other families: ~**+0.0000**
- more aggressive stretch settings
  - degraded lane label: `geo_contrast_aggressive_v1` (baseline: `geo_baseline`)
  - env: `GLMOCR_GATEWAY_CONTRAST=1`, `GLMOCR_GATEWAY_CONTRAST_STRENGTH=1.0`, `GLMOCR_GATEWAY_CONTRAST_MAX_SCALE=2.2`
  - by family (final overall mean deltas vs baseline):
    - `low_contrast_shadow`: **+0.0002**
    - `noise_and_jpeg`: **-0.0001**

This suggests the current synthetic `low_contrast_shadow` family is either already handled well by the model path or not
well targeted by a *global* stretch; a CLAHE-like or illumination-normalization branch would likely be required for a
meaningful uplift.

**Decision (for now):** keep the stretch branch behind experiment toggles; do not enable by default. Defer CLAHE unless
future evidence shows the need (implementation cost + risk of amplifying noise/texture on handwriting and seals).

**Exit criteria**

- low-contrast degraded cases improve
- clean dense text (`code`, dense CJK) does not regress materially
- one contrast branch clearly outperforms the other or both are rejected

---

### Workstream F — light denoise

**Goal:** determine whether any minimal denoise branch is worth keeping.

**Tasks**

- [ ] Start with a very small median-filter branch.
- [ ] Keep stronger denoise variants behind an explicit experiment flag only.
- [ ] Evaluate primarily on noise/compression degraded inputs.
- [ ] Verify that tiny stroke detail is not softened unacceptably.

**Exit criteria**

- noise-lane benefit is visible
- `code` / thin-stroke regressions remain negligible

---

### Workstream G — experimental monochrome branch

**Goal:** answer whether thresholding/morphology is worth keeping as an opt-in niche path.

**Tasks**

- [ ] Restrict to OCR-region experiments only.
- [ ] Add a gating heuristic for near-monochrome/shaded-paper cases.
- [ ] Test adaptive threshold variants before morphology.
- [ ] Add morphology only if thresholded outputs still show measurable speck/bleed problems.
- [ ] Explicitly compare against the RGB-first branch on handwriting, seals, and mixed-layout cases.

**Exit criteria**

- either a tightly gated niche branch is justified by evidence
- or the repo records that this family is not worth maintaining

---

## 2. Integration rules

- [x] Keep raw image operations model-agnostic in `VLMRuntimeKit`.
- [x] Keep enablement policy in `GLMOCRAdapter` / `DocLayoutAdapter`.
- [x] Do not widen the CLI/app user-facing surface until at least one branch proves stable.
- [x] Prefer hidden experiment toggles or test-only wiring first.
- [x] Preserve the existing accepted resize-backend/runtime policy unless a new branch clearly supersedes it.

---

## 3. Reporting requirements

Every experiment report should record:

- candidate mechanism name
- trigger heuristic and parameter values
- whether it ran at page level or OCR-region level
- affected examples / crops
- clean-corpus score delta
- degraded-lane score delta
- representative artifact captures
- keep / reject / defer recommendation

---

## 4. Explicit non-goals

The following are out of scope for this tracker unless the repo strategy changes:

- learned image restoration models
- super-resolution
- full document dewarp pipelines
- heavy classical scanner pipelines applied to every input
- example-specific hardcoded preprocessing policies

---

## 5. Proposed acceptance order

Only consider default-on adoption in this order:

1. border / canvas cleanup
2. page crop + perspective rectification
3. deskew
4. conservative contrast normalization
5. light denoise
6. experimental monochrome branch

This order is intentional: fix geometry and obvious background issues before changing local pixel distributions.
