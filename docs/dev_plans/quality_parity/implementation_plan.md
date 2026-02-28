# Implementation plan - quality parity after structural layout recovery

**Objective:** convert the findings from `docs/debug_notes/layout_parity/layout_parity_analysis.md` into a concrete execution plan that closes the remaining layout-mode parity gaps and then makes them enforceable.

**Status (2026-02-27):** active. Phase 00 is complete. The current repo has crossed from "unknown structural mismatch" into "known remaining sources of drift".

---

## 1. Current state

### Completed

The following are now treated as fixed and verified:

- formula label aliasing (`formula` -> `.formula`) in PP-DocLayout-V3 label mapping
- block-list JSON export preserving `table` / `formula` labels instead of collapsing them to `text`

These fixes restore the major missing-formula structural gap in the parity lane.

### Remaining likely sources of drift

The remaining diffs are best grouped into four buckets:

1. **Crop semantics**
   - bbox normalization rounds differently from upstream
   - crop de-normalization rounds differently from upstream
   - missing layout heuristics can still perturb which regions survive

2. **Polygon support**
   - upstream produces `polygon_points` from `out_masks`
   - Swift currently falls back to bbox polygons for every region

3. **Decoder policy**
   - Swift is greedy-only today
   - `GenerateOptions` does not yet represent the knobs used by the upstream SDK path
   - upstream sources themselves expose multiple potential "defaults" that need to be reconciled before parity claims are meaningful

4. **Validation policy**
   - the repo has a strong report-only harness
   - the repo does not yet lock stable examples with thresholds in a way that is friendly to day-to-day development

---

## 2. Recommended strategy

Do not attempt to solve all remaining drift with one giant pass.

Use the following order:

### Step A - stabilize the crop contract

Before touching decoding policy, make sure the detector and cropper agree with the upstream coordinate contract closely enough that region content is comparable.

This is Phase 01.

### Step B - upgrade region geometry from rectangles to polygons

Once bbox math is no longer drifting, bring `out_masks` into the Swift path and evaluate polygon crops on the formula-heavy examples.

This is Phase 02.

### Step C - make decoding policy explicit and reproducible

Only after Steps A and B should the project decide what "generation parity" means for this repo:

- parity to the Hugging Face model's direct generation config
- parity to the official SDK pipeline defaults
- or an explicit repo-owned parity profile used for example regeneration

This is Phase 03.

### Step D - lock the stable subset

Use the existing report harness to convert the stable examples into thresholded checks. This protects the recovered parity work from regressions without making the default developer loop too expensive.

This is Phase 04.

---

## 3. Swift-solution guidance for the remaining Python-side behaviors

The remaining upstream behaviors fall into three implementation categories.

### 3.1 Crop math and postprocess heuristics

**Python-side behavior:** mostly plain arithmetic and deterministic filtering.

**Recommended Swift path:** stay within the existing adapter + `VisionIO` + postprocess code. No external dependency is justified here.

This includes:

- normalized bbox rounding policy
- crop pixel-bound rounding policy
- min-size validity filtering
- `filter_large_image`
- any remaining order-sequence tie-breaking cleanup

### 3.2 Mask to polygon extraction

**Python-side behavior:** the Transformers implementation uses OpenCV contour extraction and polygon simplification on binary masks.

**Recommended Swift search order:**

1. Apple-native contour extraction spike for binary masks
2. compact local contour-tracing implementation if the Apple-native path does not preserve the needed semantics
3. OpenCV-backed validation tooling only if needed to de-risk the local implementation

Rationale:

- The shipping OCR path should remain Apple-native and lightweight if possible.
- However, parity work cares more about semantic equivalence than about using a fashionable API.
- If an Apple-native contour API adds smoothing, thresholding, or contour ordering behavior that drifts too far from the OpenCV semantics used upstream, a small local implementation becomes the more faithful choice.

This decision point is made explicit in Phase 02.

### 3.3 Decoding policy and sampling

**Python-side behavior:** the SDK request builder and the direct HF model path expose different generation defaults.

**Recommended Swift path:** extend `VLMRuntimeKit/Generation` and borrow proven sampler / generation-loop structure from the MLX-Swift-style projects already surveyed in `docs/reference_projects.md`, instead of adding ad hoc logic directly into `GLMOCRModel.generate(...)`.

That keeps sampling policy reusable across adapters and avoids hard-coding parity-specific behavior inside the model core.

---

## 4. Phase summary

| Phase | Goal | Main files expected to change |
|---|---|---|
| Phase 01 | Match upstream crop and filtering semantics closely enough that bbox-driven parity stops shifting for avoidable reasons | `PPDocLayoutV3Model.swift`, `VisionCrop.swift`, `PPDocLayoutV3Detector.swift`, `PPDocLayoutV3Postprocess.swift`, targeted tests |
| Phase 02 | Produce and consume real polygon crops from `out_masks` | `PPDocLayoutV3Model.swift`, `PPDocLayoutV3Postprocess.swift`, new polygon utility, `VisionCrop.swift`, new tests |
| Phase 03 | Support explicit decoding policies and choose the repo's parity target profile | `OCRTypes.swift`, `Generation/*`, `GLMOCRModel.swift`, CLI/app plumbing, integration tests |
| Phase 04 | Turn stable examples into opt-in gated checks with clear thresholds | `scripts/compare_examples.py`, example notes, quality tracker, integration tests |

Detailed work breakdown lives in the per-phase docs in this folder.

---

## 5. Cross-phase acceptance rules

A phase is only complete if all three conditions hold:

1. **Implementation landed**
   - code paths exist and are wired into the real end-to-end layout pipeline

2. **Example-level evidence recorded**
   - at least one parity report or targeted before/after note is recorded in docs or tracker

3. **Regression protection added**
   - a unit test, integration test, or harness rule exists for the specific defect class that was fixed

This prevents the project from accumulating one-off debugging wins that are not protected.

---

## 6. Immediate next actions

1. Execute Phase 01 in full.
2. Create the Phase 02 spike branch and compare at least `paper`, `page`, and `GLM-4.5V_Pages_1_2_3` before choosing the final polygon-extraction strategy.
3. Resolve the parity decoding contract in Phase 03 before implementing sampler knobs beyond greedy.
4. After the first stable subset emerges, start Phase 04 immediately instead of waiting for the entire corpus.

---

## 7. Exit condition for this workstream

The quality parity plan is complete when all of the following are true:

- the remaining layout-mode diffs are documented as either fixed or intentional
- the crop and polygon paths are no longer known sources of avoidable drift
- decoding policy is explicit and reproducible
- representative PDF and PNG examples are protected by opt-in thresholds
- the tracker no longer contains any "unknown likely cause" items for the active example set
