# Layout Mode Parity Gap Technical Analysis
**Created:** 2026-02-27
**Last updated:** 2026-02-28
**Scope:** `GLM-OCR-Swift` (Swift/MLX) vs parity baseline outputs in `examples/reference_result/*`, cross-checked against upstream `GLM-OCR` (Python) and HF snapshot metadata.

This doc is intentionally “debug-notes style”: it records hypotheses, investigation evidence, fixes made, and what was ruled out.

---

## 0. Current status (as of 2026-02-28)

### ✅ Fixed (verified)
1. **Formula regions were dropped before OCR (structural failure)** due to a **label-string taxonomy mismatch**:
   - HF snapshot `PP-DocLayoutV3_safetensors/config.json` emits `"formula"` for the formula class IDs, while
   - Swift mappings only handled `"display_formula"` / `"inline_formula"`.

   Fix: add `"formula"` as an alias in `PPDocLayoutV3Mappings` so those regions survive layout detection and are OCR’d/formatted as formulas.

2. **Block-list JSON export mislabeled tables/formulas as `"text"`** (schema mismatch vs `examples/reference_result/*/*.json`).

   Fix: export `"table"` / `"formula"` labels in `OCRDocument.toBlockListExport()`.

### ✅ Verified impact (structural parity restored for the “missing formulas” class of diffs)
After the fixes above, running the CLI in layout mode on key examples produces the same **block-count + label distribution** as the reference JSON:

- `paper.png`: **30 blocks** → `19 text + 11 formula` (previously `19 text` only).
- `page.png`: **28 blocks** → `22 text + 6 formula` (previously `22 text` only).
- `table.png`: **1 block** labeled `table` (previously exported as `text`).
- `GLM-4.5V_Pages_1_2_3.pdf`: formulas now appear on the correct page(s) (e.g. Page 3 shows `+2` formula blocks), matching the reference’s label distribution.

These were the dominant layout-mode parity gaps observed in `examples/result/*` vs `examples/reference_result/*`.

> Note: `examples/result/*` is generated output. The committed `examples/result/*` in git will still reflect the pre-fix state until `scripts/run_examples.sh --clean` is rerun and outputs are updated.

### Still open (likely next-order causes of content-level drift)
- **Polygon/mask-based crops** (`polygon_points` from `out_masks`): Swift currently uses bbox-only crops (polygons are `nil`).
- **Crop rounding semantics**: Swift tends to expand bottom/right edges (floor/ceil) vs upstream truncation (`int(...)`).
- Upstream layout heuristics not mirrored:
  - `filter_large_image` (drops huge “image” regions),
  - “min-size validity” pre-filter that masks logits for too-small boxes.
- **Generation policy mismatch**: Swift is hard-greedy argmax and the CLI forces `temperature=0, topP=1`, while upstream config defaults are sampling-heavy (temperature/top_p/top_k + repetition penalty).

---

## 1. Executive summary

The biggest parity discrepancies in layout mode were not “model quality” issues—they were **structural pipeline mismatches**:

- **Formulas disappeared entirely** because the layout detector’s label strings differed from the mapping table used to decide which regions to OCR vs abandon.
- Even when OCR was correct, the emitted **examples-style JSON schema** was wrong because labels were collapsed.

Once these two were fixed, the remaining parity differences are primarily **content-level** (OCR text differences) and are more plausibly explained by:

- crop tightness / polygon masks (more background contamination → worse OCR on math),
- rounding differences,
- generation/sampling differences.

---

## 2. Baseline symptom profile (pre-fix)

The most diagnostic pattern was “**missing formula blocks**”:

- `examples/reference_result/paper/paper.json`: `19 text + 11 formula` (30 blocks total)
- `examples/result/paper/paper.json`: `19 text` only (19 blocks total)

Similar deficits existed for:

- `page` (`+6` formulas missing),
- `GLM-4.5V_Pages_1_2_3` (`+2` formulas missing).

This was corroborated by the repo’s report harness:

- `python3 scripts/compare_examples.py --lane both` (pre-fix) produced:
  - `paper`: `blocks expected/actual: 30/19`, multiple `label mismatch expected='formula' actual='text'`
  - `table`: `label mismatch expected='table' actual='text'` (content OK but schema label wrong)

---

## 3. Root causes and fixes

### 3.1 Root cause #1 (definite): PP-DocLayout label-string mismatch dropped formulas as `.abandon` (✅ fixed)

#### What happened
The Swift layout pipeline loads `PPDocLayoutV3Config` from the HF snapshot `config.json`, then uses `config.id2label` to convert predicted class IDs into **label strings**, and finally maps those strings to:

- a `LayoutTaskType` (text/table/formula/skip/abandon) via `PPDocLayoutV3Mappings.labelTaskMapping`.

Before the fix:
- HF snapshot returned `"formula"` for the formula classes (IDs 5 and 15 in the current snapshot),
- but Swift only recognized `"display_formula"` / `"inline_formula"`,
- so `"formula"` fell through to the default `?? .abandon`,
- and `PPDocLayoutV3Detector.detect()` filtered those regions out before OCR.

#### Evidence (investigation)
- HF snapshot label strings (local cache snapshot used during investigation):
  - `~/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/snapshots/a0abee1e2bb505e5662993235af873a5d89851e3/config.json`
  - `id2label["5"] == "formula"`, `id2label["15"] == "formula"`.

- Swift code path that abandoned unknown labels:
  - `PPDocLayoutV3Postprocess.apply()` maps `taskType` via `PPDocLayoutV3Mappings.labelTaskMapping[label] ?? .abandon`.
  - `PPDocLayoutV3Detector.detect()` drops `.abandon` regions before returning `OCRRegion`s to the layout pipeline.

#### Fix applied
Add `"formula"` as an alias in BOTH mapping tables:

- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Mappings.swift`
  - `labelTaskMapping["formula"] = .formula`
  - `labelToVisualizationKind["formula"] = .formula`

Unit-test coverage was updated accordingly:
- `Tests/DocLayoutAdapterTests/PPDocLayoutV3MappingsTests.swift` now asserts the alias exists.

#### Post-fix verification (evidence)
Reruns via CLI now yield formula blocks structurally matching the reference:

- `paper.png`: `Counter({'text': 19, 'formula': 11})` and 30 total blocks.
- `page.png`: `Counter({'text': 22, 'formula': 6})` and 28 total blocks.

This demonstrates the formula “drop before OCR” issue is resolved.

#### Why this mismatch exists at all
Upstream `GLM-OCR/glmocr/config.yaml` expects `display_formula` / `inline_formula`, but the HF snapshot’s `config.json` collapses both to `"formula"`. The Swift port originally mirrored upstream config.yaml labels, which is correct for upstream code, but not robust to HF snapshot label-string variance.

This fix intentionally supports **both** taxonomies.

---

### 3.2 Root cause #2 (definite): Block-list JSON export collapsed labels to text/image (✅ fixed)

#### What happened
The “examples-compatible” JSON export (`OCRDocument.toBlockListExport()`) previously emitted:

- `"image"` for images,
- `"text"` for everything else (including tables and formulas),

even though `examples/reference_result/*/*.json` uses `"table"` and `"formula"` labels.

#### Evidence (investigation)
- Pre-fix `scripts/compare_examples.py` showed (for `table.json`): `label mismatch expected='table' actual='text'` while content matched.
- Code inspection confirmed `canonicalLabel(for:)` returned `"text"` for all non-image kinds.

#### Fix applied
Update `canonicalLabel(for:)` to preserve:

- `OCRRegionKind.table → "table"`
- `OCRRegionKind.formula → "formula"`

File:
- `Sources/VLMRuntimeKit/OCRBlockListExport.swift`

#### Post-fix verification (evidence)
Running layout mode on `table.png` now yields:

- `Counter({'table': 1})` in exported JSON labels (instead of `text`).

---

## 4. Hypotheses explored and ruled out / deprioritized (with evidence)

### H1: “NMS iou_diff mismatch is deleting formulas”
**Ruled out.** Upstream `apply_layout_postprocess(...)` calls:
- `selected_indices = nms(..., iou_same=0.6, iou_diff=0.98)`

Swift postprocess uses:
- `iouSameClass = 0.6`, `iouDifferentClass = 0.98`

So NMS thresholds match the upstream call in layout mode and cannot explain “all formulas missing”.

### H2: “Containment merge / ordering mismatch is the primary structural cause”
**Deprioritized for the missing-formula symptom.** The missing formula blocks were explained by the label→task mapping fallthrough (`"formula" → .abandon`) and confirmed fixed by the alias.

Containment merge / ordering can still cause *some* bbox drift and reordering, but it is not the root cause of the large block-count deficits.

### H3: “Chat template mismatch (/nothink) is causing missing formulas”
**Ruled out for structural loss.** The missing formulas occurred *before OCR* (regions never reached OCR). Additionally:
- HF `chat_template.jinja` appends `/nothink` to the last user message when `enable_thinking` is false and the message does not already end with `/nothink`.
- Swift `GLMOCRChatTemplate` appends `/nothink` by default.

So while generation policy may differ, the `/nothink` toggle itself is unlikely to be the source of the structural gap.

### H4: “Model snapshot revision drift explains the mismatch”
**Not a sufficient explanation.** The issue was reproducible with the pinned HF snapshots present in local cache:
- GLM-OCR: `677c6baa60442a451f8a8c7eabdfab32d9801a0b`
- PP-DocLayout-V3: `a0abee1e2bb505e5662993235af873a5d89851e3`

The failure was a deterministic label-string mismatch between snapshot `config.json` and Swift’s mapping tables.

---

## 5. Remaining likely parity/quality drivers (open)

These are still plausible drivers of the **remaining content-level drift** (even after structural parity is restored):

### 5.1 Polygon/mask crops (`out_masks` → `polygon_points`)
Upstream GLM-OCR produces polygon points and uses them in `crop_image_region(...)` to mask outside the polygon (white fill). Swift currently:

- does not expose `out_masks` → polygons are always `nil`,
- crops with bbox only (`VisionIO.cropRegion` without polygon mask),

which can introduce background contamination (especially in math-heavy regions).

### 5.2 Crop/bbox rounding semantics
Upstream crop path uses truncation (`int(...)`) for:
- bbox normalization (`x_norm = int(x / W * 1000)`),
- crop de-normalization (`x = int(x_norm * W / 1000)`).

Swift often uses floor for min edges and ceil for max edges (both when normalizing and cropping), which systematically expands crops and can worsen OCR.

### 5.3 Upstream layout heuristics not mirrored
Upstream `apply_layout_postprocess` includes:
- `filter_large_image` (drops huge image boxes),
and upstream `layout_detector.py` includes:
- a “min-size validity” pre-filter that masks logits for too-small boxes.

These can affect region counts on certain documents (likely more for PDFs with large figures).

### 5.4 Generation/sampling mismatch (content-level drift)
Upstream config defaults (from `GLM-OCR/glmocr/config.yaml`) are:
- `temperature: 0.8`, `top_p: 0.9`, `top_k: 50`, `repetition_penalty: 1.1`.

Swift currently:
- uses greedy argmax decoding in `GLMOCRModel.generate(...)`,
- CLI hard-codes `temperature=0` and `topP=1`,
- ignores sampling-related knobs (no top_k / repetition penalty).

This is consistent with observed token-level drifts (e.g. `Q→O`, subscript confusions), but still requires targeted work to align.

---

## 6. Remediation plan (updated)

### Phase 0 — structural parity (DONE)
- [x] Add `"formula"` alias in `PPDocLayoutV3Mappings` (task + visualization).
- [x] Export `table` / `formula` in block-list JSON export.

### Phase 1 — crop + ordering alignment (recommended next)
- Align bbox normalization and crop de-normalization rounding with upstream truncation.
- Evaluate whether region ordering needs to be made more “upstream identical” (only after crop/label parity is stable).
- Consider mirroring `filter_large_image` if it appears in parity diffs.

### Phase 2 — polygon/mask support
- Plumb `out_masks` through PPDocLayoutV3 inference and postprocess.
- Implement mask→polygon extraction (or an acceptable approximation) and feed polygons into `VisionIO.cropRegion(...)`.

### Phase 3 — generation alignment
- Implement sampling knobs (temperature/top_p/top_k/repetition penalty) and honor `GenerateOptions`.
- Expose CLI flags to match upstream config defaults when doing parity comparisons.

---

## 7. Quick validation commands (repeatable)

### Spot-check structural parity for a single image
```bash
swift run -c release GLMOCRCLI --layout --input examples/source/paper.png --emit-json /tmp/paper.json > /tmp/paper.md
python3 - <<'PY'
import json
from collections import Counter
data=json.load(open("/tmp/paper.json"))
c=Counter(b["label"] for page in data for b in page)
print(c, "blocks", sum(len(p) for p in data))
PY
```

### Generate full parity/quality report (repo harness)
```bash
python3 scripts/compare_examples.py --lane both
```

---

## Appendix A — key code changes made

1. **Formula alias mapping**
   - `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Mappings.swift`

2. **Correct JSON export labels**
   - `Sources/VLMRuntimeKit/OCRBlockListExport.swift`

3. **Unit test for the alias mapping**
   - `Tests/DocLayoutAdapterTests/PPDocLayoutV3MappingsTests.swift`

---

## Appendix B — investigation log (what was tried, what it proved)

This is a concise “why we believe this” timeline that maps directly to the fixes above.

1. **Diffed parity artifacts** (`examples/result/*` vs `examples/reference_result/*`):
   - `paper.json` and `page.json` had **fewer blocks** and **no `formula` labels** in Swift outputs.
   - `table.json` content was OK but label was `text` instead of `table`.

2. **Quantified the symptom (label counts)**:
   - Pre-fix `paper.json` (Swift): `Counter({'text': 19})`
   - Reference `paper.json`: `Counter({'text': 19, 'formula': 11})`

3. **Traced the layout pipeline stage where loss occurred**:
   - `GLMOCRLayoutPipeline` builds work items by mapping `nativeLabel → taskType` and throws away `.skip`/`.abandon`.
   - `PPDocLayoutV3Detector.detect()` already filters out `.abandon` regions, meaning a mapping issue upstream would prevent formula regions from ever reaching OCR.

4. **Validated the label taxonomy mismatch at the source**:
   - Opened the HF layout snapshot `config.json` and confirmed the model emits `"formula"` label strings for the formula class IDs (5 and 15 in the inspected snapshot).
   - Confirmed Swift mappings did not include `"formula"`, only `"display_formula"` / `"inline_formula"`.

5. **Applied the minimal fix + reran**:
   - Added `"formula"` alias mapping.
   - Rerun produced `paper.png: Counter({'text': 19, 'formula': 11})` and 30 blocks → structural parity restored.

6. **Investigated independent JSON schema mismatch**:
   - `OCRBlockListExport` exported `text` for everything except `image`.
   - Fixed to export `table`/`formula`, and verified `table.png` exports `label=table`.

7. **Hypotheses ruled out while localizing root cause**:
   - NMS threshold mismatch was checked against upstream `apply_layout_postprocess(...)`; both use `iou_diff=0.98` in layout mode.
   - Generation/sampling differences can explain OCR text drift, but cannot explain *missing* formula regions (which were dropped before OCR).

---

## Appendix C — evidence pointers (where to look in code)

- **HF snapshot emits `"formula"`**
  - `~/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/snapshots/a0abee1e2bb505e5662993235af873a5d89851e3/config.json`
  - Look for `id2label` entries for class IDs `5` and `15`.

- **Swift label mapping (fixed)**
  - `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Mappings.swift`
  - `labelTaskMapping["formula"] = .formula`
  - `labelToVisualizationKind["formula"] = .formula`

- **Swift JSON export labels (fixed)**
  - `Sources/VLMRuntimeKit/OCRBlockListExport.swift`
  - `canonicalLabel(for:)` now preserves `table` and `formula`.

- **Polygon crops not yet implemented (open)**
  - `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift` returns `RawDetections(polygons: nil)`.
  - `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Postprocess.swift` falls back to bbox polygons when raw polygons are missing.
  - `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift` supports polygon masking, but it is currently unused by the layout detector path.

- **Crop rounding semantics (open)**
  - `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift` bbox normalization uses floor/ceil.
  - `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift` uses floor/ceil when converting normalized bbox to pixels.
  - Upstream reference uses truncation (`int(...)`) in `../GLM-OCR/glmocr/utils/image_utils.py`.

- **Greedy decoding (open)**
  - `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`: next token chosen via `argMax()`; `GenerateOptions.temperature/topP` are currently not used for sampling.
