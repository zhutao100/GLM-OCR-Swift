# Tracker - gateway input preprocessing experiments

**Objective:** run a narrow, evidence-driven experiment program for deterministic lightweight gateway preprocessing, without destabilizing the repo's accepted artifact contract.

**Status (2026-03-17):** proposed; no gateway preprocessing branch has been accepted yet beyond the existing resize-backend/runtime work.

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

- [ ] Define a deterministic synthetic degradation recipe set over selected checked-in examples.
- [ ] Start with the most relevant source images:
  - `examples/source/page.png`
  - `examples/source/table.png`
  - `examples/source/paper.png`
  - optionally selected crops from layout-mode examples
- [ ] Add at least these degradation families:
  - [ ] dark-border / overscan margin injection
  - [ ] small-angle skew
  - [ ] perspective warp
  - [ ] low-contrast / uneven illumination
  - [ ] light noise / compression degradation
- [ ] Record exact generation parameters so the lane is reproducible.
- [ ] Keep this lane report-only until a stable signal emerges.

**Exit criteria**

- one repeatable degraded-input lane exists
- reports can compare baseline vs gateway branch on a defect-family basis

---

### Workstream B — border / canvas cleanup

**Goal:** test whether cheap background-margin cleanup helps degraded inputs without touching interior glyph statistics too much.

**Tasks**

- [ ] Add a model-agnostic border-analysis primitive in `VLMRuntimeKit`.
- [ ] Implement a conservative content-box proposal with confidence scoring.
- [ ] Preserve a small safety border instead of hard edge crops.
- [ ] Capture before/after page artifacts for inspected examples.
- [ ] Evaluate on the clean corpus and degraded border/margin lane.

**Exit criteria**

- content-box detection is deterministic and inspectable
- clean-corpus regressions are absent or negligible
- border-degraded examples show a meaningful improvement signal

---

### Workstream C — page crop + perspective rectification

**Goal:** improve photographed-page inputs, especially `table.png`-like cases.

**Tasks**

- [ ] Implement or prototype a deterministic page-on-background detector.
- [ ] Add quad estimation with confidence gating.
- [ ] Add a perspective-warp helper at the model-agnostic vision layer.
- [ ] Run focused A/B on `table.png` and synthetic perspective-warp cases.
- [ ] Confirm that clean scan/PDF inputs do not spuriously enter this path.

**Exit criteria**

- photographed-page cases improve clearly
- false-positive triggering on clean scans stays rare
- the added latency remains acceptable

---

### Workstream D — deskew

**Goal:** test whether a small-angle deskew stage improves camera/scanner slant cases.

**Tasks**

- [ ] Prototype a deterministic skew-angle estimator.
- [ ] Restrict correction to high-confidence, small-angle cases first.
- [ ] Evaluate page-level vs region-level application order.
- [ ] Record a “no-op when uncertain” fallback.

**Exit criteria**

- skew correction helps the skewed degraded lane
- no meaningful regressions appear on already-upright inputs

---

### Workstream E — conservative contrast normalization

**Goal:** test whether luma-only contrast correction improves faint or low-contrast text while keeping the RGB-first path intact.

**Tasks**

- [ ] Prototype mild percentile stretch on luma.
- [ ] Prototype conservative luma-only CLAHE.
- [ ] Gate both by measurable contrast/illumination heuristics.
- [ ] Apply to OCR crops first, not layout-detector page inputs.
- [ ] Capture crop-level artifacts via the existing preprocess debug path.

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

- [ ] Keep raw image operations model-agnostic in `VLMRuntimeKit`.
- [ ] Keep enablement policy in `GLMOCRAdapter` / `DocLayoutAdapter`.
- [ ] Do not widen the CLI/app user-facing surface until at least one branch proves stable.
- [ ] Prefer hidden experiment toggles or test-only wiring first.
- [ ] Preserve the existing accepted resize-backend/runtime policy unless a new branch clearly supersedes it.

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
