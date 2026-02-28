# Phase 01 - crop and ordering alignment

**Objective:** eliminate avoidable parity drift caused by coordinate conversion, crop pixel-bound semantics, and missing layout heuristics.

**Status (2026-02-28):** implemented rounding + pre-filters + unit tests; ordering follow-up remains for `page` (see `docs/dev_plans/quality_parity/tracker.md`).

---

## 1. Why this phase comes first

After the formula-label and JSON-label fixes, the next most plausible source of parity drift is not model quality but geometry handling:

- upstream bbox normalization truncates to integer space
- the Swift path currently expands max edges via ceil-like behavior
- the cropper repeats that expansion when converting normalized bbox values back to pixels

That means the recognizer is often seeing slightly larger crops than the upstream path, which is especially damaging for formulas and dense scientific text.

If this is not fixed first, Phase 02 and Phase 03 results become much harder to interpret.

---

## 2. Upstream behaviors to mirror

### 2.1 Normalized bbox conversion

Upstream converts floating-point `xyxy` boxes into `[0, 1000]` normalized integer coordinates using truncation semantics.

**Swift code to revisit**

- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`
  - `toNormalizedBBox(...)`

### 2.2 Crop de-normalization

Upstream converts normalized bbox coordinates back into pixel coordinates using integer truncation.

**Swift code to revisit**

- `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift`
  - `cropRegion(...)`

### 2.3 Min-size validity pre-filter

The upstream detector masks logits for boxes smaller than one mask cell before post-processing. That can change the set of surviving detections even when NMS matches.

**Swift code to revisit**

- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`
  - raw output selection path before `postProcessObjectDetection(...)`

### 2.4 Large-image filtering

The upstream layout postprocess includes `filter_large_image`, which drops extremely large image regions under specific conditions.

**Swift code to revisit**

- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Postprocess.swift`
- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Detector.swift`

---

## 3. Recommended implementation steps

### Workstream A - rounding contract

1. Add a small test matrix for `toNormalizedBBox(...)` using edge-near values.
2. Change the normalization path from expand-on-max-edge to upstream-style truncation.
3. Add a matching test matrix for `VisionIO.cropRegion(...)` that validates exact crop rectangles against the same contract.
4. Re-run representative examples and record bbox-delta changes.

**Important rule:** do not silently change both the detector and cropper without tests. The repo needs to be able to explain the chosen arithmetic contract later.

### Workstream B - missing heuristics

1. Mirror the min-size validity mask before post-process selection.
2. Mirror `filter_large_image` as closely as practical.
3. Keep these behaviors explicit in code comments and diagnostics rather than burying them in opaque constants.

### Workstream C - ordering cleanup

Only after Workstreams A and B land:

1. inspect whether `order_seq` still causes unstable tie ordering
2. if needed, tighten the fallback/tie-break path
3. avoid changing ordering heuristics in the same patch as rounding changes unless a failing test requires it

---

## 4. Tests to add

### Unit tests

- bbox normalization cases covering values just below and above integer boundaries
- crop rectangle conversion cases for page-edge boxes and tiny formula boxes
- min-size validity filter fixture using a synthetic raw output that should be suppressed upstream
- `filter_large_image` behavior fixture with one large image box and one smaller content box

### Integration checks

At minimum, rerun and compare:

- `paper`
- `page`
- `table`
- `GLM-4.5V_Pages_1_2_3`

If the bbox tolerance report tightens without increasing block-count mismatches, the phase is moving in the right direction.

---

## 5. Acceptance criteria

This phase is done when all of the following are true:

- normalization and crop rounding are protected by regression tests
- the missing upstream heuristics are either implemented or intentionally documented as non-goals
- parity reports no longer show obvious bbox drift attributable to arithmetic expansion
- the tracker does not list any remaining "easy geometry mismatch" items
