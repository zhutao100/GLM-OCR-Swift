# Quality parity plan index

**Objective:** refresh the `GLM-OCR-Swift` parity work into a phased, faithful improvement plan that names the reference contract explicitly, closes the highest-value remaining gaps in the right order, and then locks the stable subset into the validation workflow.

**Status (2026-03-06):** active. The project has completed the reference-contract, crop/geometry, and generation-policy phases. The remaining active work is **formatting/export parity** plus the low-flake protection that keeps the stable subset locked in.

---

## What "faithful parity" means in this repo

The earlier comparison work showed that the repo needs to be precise about *which* upstream behavior it is matching.

There are three adjacent but different targets:

1. **HF / local-model semantics parity**
   - `transformers` GLM-OCR + PP-DocLayout-V3 config, preprocessing, postprocess, and generation behavior.
   - This is the most relevant target for a native local inference engine.

2. **Official Python repo behavior parity**
   - `zai-org/GLM-OCR` page loading, optional layout detection, OCR request orchestration, and result formatting.
   - This matters for example outputs and UX expectations.
   - It does **not** imply that `GLM-OCR-Swift` should copy the Python repo's service-oriented architecture.

3. **Repo-owned regression contract**
   - the exact behavior the project decides to check in under `examples/result/*`, `examples/reference_result/*`, and the parity/quality harness.
   - This must be explicit so future example updates are reproducible.

This plan treats **(1) + the user-visible parts of (2)** as the parity target, while keeping the Swift architecture native and modular.

---

## Phase map

| Phase | Focus | Primary outcome |
|---|---|---|
| Phase 00 | Reference contract + reproducibility | One written parity contract, pinned revisions, and an agreed score baseline |
| Phase 01 | Layout/crop/order alignment | Upstream-faithful bbox math, crop bounds, filtering, and reading-order behavior |
| Phase 02 | Polygon/mask geometry parity | `out_masks`-driven polygon extraction and polygon-aware crops where upstream provides them |
| Phase 03 | Generation/runtime parity | Explicit decode presets and reproducible generation behavior for parity runs |
| Phase 04 | Formatting/export parity + golden policy + CI | Stable markdown/JSON/example outputs, documented golden regeneration policy, and low-flake enforcement |

---

## Documents in this folder

- `tracker.md`
  - live status, ordered backlog, score snapshot, and exit criteria
- `implementation_plan.md`
  - master plan tying the five phases together
- `phase_00_reference_contract.md`
  - target definition, pinned revisions, and acceptance criteria for "faithful parity"
- `phase_01_crop_order_alignment.md`
  - bbox math, crop rounding, filtering, ordering, and page/crop reuse
- `phase_02_polygon_mask_support.md`
  - `out_masks` plumbing, contour extraction, and polygon crop rollout
- `phase_03_generation_alignment.md`
  - generation presets, sampler/runtime plumbing, and parity-run UX
- `phase_04_thresholds_coverage_ci.md`
  - formatting/export parity, example regeneration policy, thresholding, and CI posture

---

## Recommended execution order

1. **Land Phase 00 first.**
   - No more parity work should proceed against an unnamed upstream target.

2. **Finish Phase 01 before large-scale decoder tuning.**
   - `page` and `code` drift is still too sensitive to crop/order defects.

3. **Do Phase 02 before claiming formula/table parity.**
   - Bbox-only crops are still a likely contamination source on formula-heavy and dense-layout pages.

4. **Do Phase 03 only after the geometry path is stable.**
   - Otherwise generation tuning will mask crop and region-selection defects.

5. **Use Phase 04 to lock the stable subset immediately.**
   - Do not wait for every example to be perfect before protecting the examples that are already stable.

---

## Decision rules

### 1. Stay architecture-native

`GLM-OCR-Swift` should remain a native local Swift/MLX runtime. The goal is not to port the official Python repo's client-service layering one-for-one.

### 2. Mirror semantics, not incidental implementation details

If the upstream Python or Transformers path uses framework-specific helpers, the Swift implementation should preserve the behavior that changes outputs:

- coordinates
- filtering
- ordering
- masks/polygons
- decode policy
- formatting/export semantics

not the upstream library choice itself.

### 3. Name the parity target in every result artifact

Every regenerated example or score report should be able to answer:

- which GLM-OCR revision?
- which PP-DocLayout-V3 revision?
- which decode preset?
- which layout/crop/polygon policy?
- which formatter/export policy?
