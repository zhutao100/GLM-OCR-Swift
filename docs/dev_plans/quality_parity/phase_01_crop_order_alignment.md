# Phase 01 - layout, crop, and order alignment

**Goal:** eliminate the remaining high-leverage drift caused by coordinate conversion, crop semantics, region filtering, reading order, and page/crop handling.

**Status (2026-03-06):** completed. The bbox conversion, crop rounding, filter rules, and ordering tie-breaks are regression-tested, and the layout path now reuses a single loaded page image for both detection and region cropping.

---

## 1. Why this phase comes first

The checked-in reports show the largest remaining deficits on examples such as `page` and `code`. Those examples are highly sensitive to:

- which regions survive layout filtering
- which pixels are included in the crop
- the order in which regions are emitted and concatenated
- whether crops are polluted by neighboring content

Until those contracts are stable, generation tuning will be noisy and misleading.

---

## 2. Scope

### In scope

- normalized bbox conversion rules
- crop pixel-bound rounding and clamping
- min-size and large-image filtering parity
- deterministic order sequencing / tie-breaking
- page reuse to avoid duplicate load/raster paths when that can perturb results or cost
- targeted PDF + PNG parity checks on representative examples

### Out of scope

- mask-derived polygon extraction itself (Phase 02)
- decode presets and sampler/runtime policy (Phase 03)

---

## 3. Workstreams

## Workstream A - bbox and crop contract audit

Confirm, codify, and regression-test the exact contract used for:

- normalization to `[0, 1000]`
- de-normalization back to pixels
- clamping at page/image boundaries
- behavior for near-zero or invalid boxes

**Primary touchpoints**

- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`
- `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift`
- `Tests/DocLayoutAdapterTests/PPDocLayoutV3BBoxConversionTests.swift`
- `Tests/VLMRuntimeKitTests/VisionCropTests.swift`

## Workstream B - filter parity

Audit and close any remaining difference in:

- min-size prefilter behavior
- `filter_large_image` handling or equivalent behavior
- discard / retain rules for edge-case boxes

**Primary touchpoints**

- DocLayout postprocess code and tests under `Tests/DocLayoutAdapterTests/`

## Workstream C - order and region sequence parity

For dense pages, small ordering differences can change both markdown and the OCR text concatenation context.

Tasks:

1. record current ordering on `page`, `paper`, `GLM-4.5V_Page_1`, and `GLM-4.5V_Pages_1_2_3`
2. compare against the reference examples and upstream intended reading order
3. make tie-breaking deterministic and testable
4. keep order rules documented, not implicit

## Workstream D - page/crop reuse

The current layout path should avoid needless double-loading or double-rasterizing page/image inputs when it risks extra cost or divergent handling.

Tasks:

1. document the current page load/raster path
2. reuse page rasters between layout detection and region cropping where safe
3. keep the behavior deterministic and covered by tests

This is partly a performance improvement, but it also reduces hidden parity drift from duplicated image-processing paths.

---

## 4. Suggested acceptance examples

The first serious validation set for this phase should be:

- `page`
- `paper`
- `code`
- `GLM-4.5V_Page_1`
- `GLM-4.5V_Pages_1_2_3`

Reasoning:

- `page` and `code` are currently the clearest hard examples
- the GLM-4.5V PDFs exercise the existing parity-integration lane
- `paper` exercises dense mixed-layout behavior

---

## 5. Exit criteria

This phase is complete when all of the following are true:

- bbox and crop math are locked by regression tests
- no known filter or clamp rule remains implicit or unexplained
- ordering differences on representative examples are either closed or documented as intentional
- page/crop reuse is deterministic and not duplicated accidentally
- the remaining hard-example drift can no longer be explained mainly by crop/order defects

The current example-eval baseline still flags `page` and `code` as the hardest examples, but after the verified Phase 01 pass there are no significant remaining regressions attributable to bbox conversion, crop rounding, filter parity, or order tie-breaking in the maintained Swift path.
