# Layout Mode Parity Gap Technical Analysis
**Date:** 2026-02-27
**Scope:** `GLM-OCR-Swift` (Swift/MLX) vs reference outputs in `examples/reference_result/*` and upstream implementations in the official `GLM-OCR` Github project and the Python `transformers` library.

---

## 1. Executive summary

Layout-mode parity gaps in `GLM-OCR-Swift` are dominated by **structural** failures (missing regions / wrong labels), followed by **crop fidelity** and **generation** differences.

### High-confidence / “definite” root causes (fix first)
1. **All formula regions are being dropped before OCR** due to a **label-string taxonomy mismatch** between:
   - the layout model snapshot (`PP-DocLayoutV3_safetensors` HF `config.json`) which emits label string `"formula"` for class IDs **5** and **15**, and
   - Swift mappings which only recognize `"display_formula"` / `"inline_formula"` and therefore classify `"formula"` as `.abandon`.

   Result: formula blocks never reach OCR → no `$$ … $$` blocks → large block-count deficits (e.g. `paper`: 19 vs 30).

2. **Block-list JSON export collapses everything to `"text"` except images**, even when the document contains tables/formulas.
   Result: JSON parity fails even when Markdown may look OK (e.g. `table.json` label mismatch).

### High-impact secondary causes (address after the above)
3. **PP-DocLayoutV3 post-processing is incomplete vs Transformers / upstream GLM-OCR:**
   - no `out_masks` → **no polygon_points** → crops are rectangle-only (more contamination, worse OCR on dense math/tables),
   - bbox normalization + crop rounding differs (Swift uses floor/ceil; upstream uses truncation),
   - order-seq uses **1-based ranks** in Swift while Transformers uses **0-based**, and Swift discards `order == 0`.

4. **GLM-OCR generation is hard-greedy argmax** and ignores `GenerateOptions.temperature/topP` (and lacks top_k / repetition penalty).
   Result: content-level drift such as `Q→O`, `x_n→x_2`, punctuation/spacing differences.

---

## 2. Baseline symptom profile (as observed in repo examples)

The most diagnostic pattern is **“missing formula blocks”**:

- `examples/reference_result/paper/paper.json` contains multiple blocks with `"label": "formula"`, while
  `examples/result/paper/paper.json` contains **only `"label": "text"`** and has fewer blocks overall.
- Similar pattern for `page` and `GLM-4.5V_Pages_1_2_3`.

A second, independent symptom is **export-label collapse**:
- `examples/reference_result/table/table.json` uses `"label": "table"` but Swift emits `"label": "text"` even when table Markdown is close.

These two symptoms have two correspondingly high-certainty causes (Sections 3.1 and 3.2).

---

## 3. Detailed findings and root causes

### 3.1 Root cause #1 (definite): PP-DocLayout label-string mismatch drops formulas as `.abandon`

#### What’s happening
The HF `PP-DocLayoutV3_safetensors/config.json` defines:
- id2label[5]  = `"formula"`
- id2label[15] = `"formula"`
(and duplicates for header/footer/text)

Swift’s mapping file `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Mappings.swift` does **not** contain the `"formula"` label in either:
- `labelTaskMapping` (used to determine OCR task / drop behavior),
- `labelToVisualizationKind` (used to format and canonicalize output kinds).

Relevant code (Swift):
- `PPDocLayoutV3Postprocess.apply()` resolves `taskType` via:
  `PPDocLayoutV3Mappings.labelTaskMapping[label] ?? .abandon`
- `PPDocLayoutV3Detector.detect()` drops regions where `taskType == .abandon` before returning regions to the pipeline.
- `LayoutResultFormatter` only formats formulas if `region.kind == .formula`; missing mapping yields `.unknown`.

#### Evidence (Swift code pointers)
- Missing `"formula"` in mapping: `PPDocLayoutV3Mappings.swift` lines 33–35 and 57–60 show only `display_formula` / `inline_formula`.
- Regions dropped: `PPDocLayoutV3Detector.detect()` filters `.abandon` before constructing `OCRRegion` output.

#### Why this exactly matches the observed diffs
If formulas are filtered during layout detection:
- block counts drop (removing all formula regions),
- Markdown loses all `$$ … $$` formula blocks,
- subsequent blocks “shift upward” in index and ordering.

This is exactly what `paper.json` exhibits: the reference has multiple formula blocks; Swift has none.

#### Fix (minimal and correct)
Add `"formula"` to **both** mappings in `PPDocLayoutV3Mappings`:

- `labelTaskMapping["formula"] = .formula`
- `labelToVisualizationKind["formula"] = .formula`

This alone should restore formula-region survival and formula rendering.

#### Fix (more robust)
Instead of trusting `config.json` label strings, use a **canonical mapping by class ID** aligned with upstream `glmocr/config.yaml`. This avoids future drift when HF snapshots collapse/rename labels (e.g. footer/header duplicates).

---

### 3.2 Root cause #2 (definite): Block-list JSON export collapses labels to text/image

#### What’s happening
`Sources/VLMRuntimeKit/OCRBlockListExport.swift` implements:

- `"image"` if `.image`
- `"text"` for all other kinds (including `.table` and `.formula`)

This contradicts the repository’s own reference JSON fixtures which use `text/table/formula/image`.

#### Fix (minimal and correct)
Export `OCRRegionKind` faithfully:

- `.text -> "text"`
- `.table -> "table"`
- `.formula -> "formula"`
- `.image -> "image"`
- `.unknown -> "text"` (or `"unknown"` if you prefer strictness)

If you want to mirror upstream more precisely, mimic the upstream “bucketization” logic (many native labels map into those four canonical buckets).

---

### 3.3 PP-DocLayoutV3 post-processing mismatches (high impact after #1/#2)

This is the next most important cluster for **layout-mode quality** once formula regions exist.

#### 3.3.1 Missing `out_masks` → missing polygon_points → rectangle-only crops
Transformers’ `PPDocLayoutV3ImageProcessorFast.post_process_object_detection()`:
- gathers `outputs.out_masks` aligned to top-k selections,
- thresholds masks, and
- extracts `polygon_points` via contouring (`findContours`, `approxPolyDP`),
- returns polygon_points for each selected box.

Upstream GLM-OCR then uses polygon masking in `crop_image_region()` to whiten pixels outside the polygon, reducing contamination.

Swift:
- `PPDocLayoutV3Model.postProcessObjectDetection()` returns `polygons: nil`,
- `PPDocLayoutV3Postprocess` falls back to bbox rectangle polygons,
- `VisionIO.cropRegion` supports polygon masking, but it never gets a real polygon.

**Impact:** crops include more neighboring content; math/table OCR quality degrades.

**Recommended implementation approach (Swift)**
1. Extend `PPDocLayoutV3Model.RawOutputs` to also return `outMasks` (and their spatial size).
2. In `postProcessObjectDetection`, gather top-k masks aligned with selected indices (matching Transformers).
3. Threshold masks and implement mask→polygon conversion:
   - Minimal viable: compute a tight polygon via marching squares / contour tracing on a binary mask.
   - Match Transformers: approximate the largest contour, simplify with an epsilon ratio ~0.004, then apply the “custom vertices” logic.
4. Scale polygons to original image coordinates using the same scale ratios used by Transformers (note the `/4` scaling in their implementation).

Even a simplified polygonization (largest contour, no fancy vertex customizations) is likely to noticeably improve OCR quality.

#### 3.3.2 BBox normalization and crop rounding semantics differ from upstream
Upstream GLM-OCR:
- normalizes bbox coords with `int(...)` truncation for **all** components,
- de-normalizes bbox to pixels again using `int(...)` truncation for **all** components.

Swift:
- `PPDocLayoutV3Model.toNormalizedBBox` uses floor for x1/y1 and **ceil** for x2/y2,
- `VisionIO.cropRegion` uses floor for x1/y1 and **ceil** for x2/y2 again.

**Impact:** systematic crop expansion on bottom-right edges → more contamination → OCR drift.

**Fix**
- Change bbox normalization to truncation for all components (match Python `int`).
- Change crop de-normalization to truncation for all components (match Python crop).

Also consider matching polygon-point rounding (Python truncates polygon points to int pixels; Swift currently uses float points into CGContext).

#### 3.3.3 Order sequence indexing (0-based vs 1-based) and dropping 0
Transformers `_get_order_seqs` returns ranks in `[0..N-1]`.
Swift `computeOrderSeq` currently returns ranks in `[1..N]` and later code treats `order <= 0` as “missing”.

This likely doesn’t change *relative* ordering, but it can affect edge cases and debug comparability.

**Fix**
- Return 0-based ranks (remove `+1`).
- Preserve `order == 0` instead of converting it to `nil`.

#### 3.3.4 Upstream “min-size validity” pre-filter exists; Swift omits it
Upstream `glmocr/layout/layout_detector.py` applies a validity check based on mask resolution to suppress too-small boxes by setting corresponding logits to -100. This reduces noisy micro-boxes.

Swift does not apply an equivalent pre-filter.

**Fix**
If you implement out_masks, port the same check:
- compute min normalized width/height thresholds as `1/maskW`, `1/maskH`,
- mask invalid queries in logits before top-k.

#### 3.3.5 Upstream `filter_large_image` step is not mirrored
Upstream `apply_layout_postprocess` removes “image” detections that cover too much of the page (threshold depends on orientation).

Swift does not implement this step. This can change block counts/ordering on image-heavy pages.

---

### 3.4 OCR generation mismatch (content-level drift)

Swift’s GLM-OCR generation (`Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`) is:
- greedy argmax at every step,
- ignores `GenerateOptions.temperature` and `topP`,
- does not implement `top_k` / repetition penalty present in upstream config defaults.

Upstream GLM-OCR config defaults:
- temperature 0.8, top_p 0.9, top_k 50, repetition_penalty 1.1.

**Impact:** frequent token-level divergences, especially on ambiguous glyphs common in math.

**Fix**
1. Expand `GenerateOptions` to include:
   - `topK: Int?`
   - `repetitionPenalty: Float`
   - `seed: UInt64?` (for deterministic tests)
2. Implement sampling in `GLMOCRModel.generate`:
   - apply temperature scaling,
   - apply repetition penalty on logits,
   - apply top-k and/or nucleus filtering,
   - sample (or choose argmax if temperature==0).
3. Make `/nothink` prompt suffix configurable (confirm it matches your reference generation prompts).

---

## 4. Prioritized remediation plan

### Phase 0 — restore structural parity (fast, high certainty)
1. **Add `"formula"` handling** in `PPDocLayoutV3Mappings`:
   - task mapping + visualization mapping.
2. **Fix block-list JSON export labels** (`OCRBlockListExport`).
3. Add a quick regression test/harness:
   - run layout mode on `examples/input/paper.*`,
   - assert output contains at least one `.formula` region and JSON export uses `"formula"` labels.

Expected outcome: block counts and label distribution approach reference immediately.

### Phase 1 — align layout crops + ordering
1. Match bbox rounding/truncation semantics to upstream (both normalization and crop).
2. Align order_seq to 0-based and preserve 0.
3. Implement upstream `filter_large_image` (optional but recommended).

Expected outcome: fewer spurious region differences; cleaner crops.

### Phase 2 — implement mask→polygon path
1. Output `out_masks` from PPDocLayoutV3 forward pass.
2. Implement polygon extraction and pass polygon points through to `VisionIO.cropRegion`.

Expected outcome: better OCR quality on rotated/irregular regions and dense math/table pages.

### Phase 3 — align generation
1. Implement sampling parameters and defaults matching upstream.
2. Add deterministic mode (seed + fixed sampling) for tests.
3. Validate on a small corpus of “math-heavy” crops.

Expected outcome: reduced text-level drift (Q/O, x_n/x_2, punctuation).

---

## 5. Validation strategy and acceptance criteria

### 5.1 Structural parity metrics (should be automated)
For each example (paper/page/table):
- total region count per page,
- counts by canonical label `{text, table, formula, image}`,
- presence of formulas on known formula pages.

**Acceptance:** After Phase 0, formulas are present and JSON labels match canonical buckets.

### 5.2 Crop fidelity metrics
- compare bbox_2d deltas vs reference,
- visualize crops for a subset of regions (especially formulas) and confirm tightness.

**Acceptance:** bbox deltas largely within ±1–2 normalized units and no systematic bottom-right expansion.

### 5.3 OCR content parity metrics
- token-level diff or Levenshtein distance on markdown blocks,
- “glyph confusion” rate on a curated list (Q/O, 1/l, n/2 in subscripts).

**Acceptance:** after Phase 3, drift is reduced and stable across repeated runs when seeded.

---

## 6. Concrete “patch checklist” (file-level)

### Must-do (Phase 0)
- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Mappings.swift`
  - add `"formula"` mappings for task + visualization.
- `Sources/VLMRuntimeKit/OCRBlockListExport.swift`
  - export table/formula labels.

### Recommended (Phase 1–2)
- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`
  - order_seq 0-based; keep order==0
  - bbox normalization truncation
  - return masks + polygon extraction (Phase 2)
- `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift`
  - crop bbox de-normalization truncation; align polygon rounding
- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Detector.swift`
  - allow processor dtype = float32 for parity runs

### Recommended (Phase 3)
- `Sources/VLMRuntimeKit/OCRTypes.swift`
  - extend `GenerateOptions` (topK, repetitionPenalty, seed)
- `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`
  - implement sampler; honor options
- `Sources/ModelAdapters/GLMOCR/GLMOCRChatTemplate.swift`
  - make `appendNoThink` configurable if needed for parity.

---

## 7. Notes on earlier analysis efforts

The two prior efforts correctly identified the two “definite” causes (formula-drop + JSON export collapse) and correctly flagged polygon/mask and generation mismatches as likely next-order drivers.

One correction:
- Upstream layout path uses `iou_diff=0.98` in its NMS call inside `apply_layout_postprocess` (even though the helper `nms()` default is 0.95). Swift currently uses 0.98, which is consistent with the actual upstream call in layout mode.

---

## Appendix A — quick diff targets (minimal code sketches)

### A.1 Add `"formula"` mapping
```swift
// PPDocLayoutV3Mappings.swift
"formula": .formula
// ...
"formula": .formula
```

### A.2 Fix JSON export
```swift
private func canonicalLabel(for kind: OCRRegionKind) -> String {
  switch kind {
  case .text: "text"
  case .table: "table"
  case .formula: "formula"
  case .image: "image"
  case .unknown: "text"
  }
}
```

### A.3 Align bbox truncation
```swift
let nx1 = Int(x1 * 1000)
let ny1 = Int(y1 * 1000)
let nx2 = Int(x2 * 1000)
let ny2 = Int(y2 * 1000)
```

### A.4 Align crop rounding (VisionCrop)
Use truncation (`rounded(.down)` everywhere, or `Int(...)`) for x1/x2/y1/y2 pixel edges.

---


## Appendix B — key evidence pointers (file + line numbers)

### B.1 Layout model snapshot emits `"formula"` (HF config)
File: `PP-DocLayoutV3_safetensors_huggingface/config.json`
- id2label[5] and id2label[15] are `"formula"` (not `display_formula` / `inline_formula`):
```text
63: "5": "formula"
73: "15": "formula"
```

### B.2 Swift mapping lacks `"formula"` (drop-to-abandon trigger)
File: `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Mappings.swift`
- Only `display_formula` / `inline_formula` are mapped (no `"formula"`): lines 33–35, 57–60.

### B.3 Swift detector drops `.abandon` regions before OCR
File: `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Detector.swift`
- Processor uses bf16: line 86
- Abandon filter: line 108 (`if region.taskType == .abandon { continue }`)
- Visualization kind uses mapping (missing `"formula"` leads to `.unknown`): line 110.

### B.4 Reference JSON contains formulas; Swift result does not
File: `examples/reference_result/paper/paper.json`
- First formula block: lines 25–35 (`"label": "formula"`)

File: `examples/result/paper/paper.json`
- Early blocks are all `"label": "text"`; formula blocks absent (see lines 25–35).

### B.5 Swift JSON exporter collapses table/formula to `"text"`
File: `Sources/VLMRuntimeKit/OCRBlockListExport.swift`
- `canonicalLabel` returns `"text"` for all non-image kinds: lines 48–55.

### B.6 Layout bbox/order/polygon mismatches are in PPDocLayoutV3Model
File: `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`
- polygons are always `nil` in RawDetections: line 856
- order_seq is 1-based (`rank + 1`): line 889
- bbox normalization uses floor for min and ceil for max: lines 909–912.

### B.7 Crop rounding differs from upstream
Swift file: `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift`
- uses ceil for max edges: lines 37–40.

Upstream file: `glmocr/utils/image_utils.py`
- truncates all edges via `int(...)`: lines 198–201.

### B.8 Transformers PPDocLayoutV3 postprocess uses masks → polygon_points
File: `src/transformers/models/pp_doclayout_v3/image_processing_pp_doclayout_v3_fast.py`
- uses `outputs.out_masks`: line 246
- binarizes masks and extracts polygons: lines 275–292
- polygon extraction code: lines 185–223.

### B.9 GLM-OCR generation is greedy argmax in Swift
File: `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`
- ignores temperature/topP and always uses argmax: lines 152 and 177.
