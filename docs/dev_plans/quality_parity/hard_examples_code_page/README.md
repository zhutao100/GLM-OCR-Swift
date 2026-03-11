# Hard examples: `code` and `page`

**Status (2026-03-11):** active focused investigation. This folder exists because the remaining gap is no longer best described as a broad parity-program issue; it is a narrow hard-example problem with concrete runtime/preprocessing suspects.

## Scope

This workstream is for:

- `examples/source/code.png`
- `examples/source/page.png`
- closely related dense mixed-layout examples that are likely affected by the same GLM-OCR preprocessing/runtime choices

It is **not** the place for fresh layout-architecture work, app polish, or broad artifact-contract changes.

## Evidence basis

The current investigation is anchored to these checked-in artifacts and code paths:

- current main-project eval records
  - `examples/eval_records/latest/agent_report.md`
  - `examples/eval_records/latest/examples/code/report.md`
  - `examples/eval_records/latest/examples/page/report.md`
- peer-port eval records
  - `../glm-ocr.swift/examples/eval_records/latest/agent_report.md`
  - `../glm-ocr.swift/examples/eval_records/latest/examples/code/report.md`
- checked-in result/reference artifacts for `code`
  - `examples/result/code/*`
  - `examples/reference_result/code/*`
  - `../glm-ocr.swift/examples/result/code/*`
- maintained repo runtime paths
  - `Sources/ModelAdapters/GLMOCR/GLMOCRImageProcessor.swift`
  - `Sources/ModelAdapters/GLMOCR/GLMOCRPipeline.swift`
  - `Sources/ModelAdapters/DocLayout/LayoutResultFormatter.swift`
- peer-port comparison paths
  - `../glm-ocr.swift/Sources/GLMOCR/GLMOCRImageProcessor.swift`
  - `../glm-ocr.swift/Sources/GLMOCR/GLMOCRPipeline.swift`
  - `../glm-ocr.swift/Sources/GLMOCR/GLMOCRResultFormatter.swift`
- upstream/reference context
  - `../GLM-OCR_github/glmocr/utils/image_utils.py`
  - `../transformers_repo_glm_ocr_files/src/transformers/models/glm_ocr/modeling_glm_ocr.py`

## Current cross-validation summary

### 1. The `code` quality gap is real and large

Current checked-in score signal:

- main repo `code`: `0.7744`
- peer Swift port `code`: `0.9457`

That gap is too large to treat as evaluator noise or a trivial formatter issue.

### 2. The current `code` failure pattern is mostly **per-region OCR quality**, not a fresh full-page layout collapse

The main repo's `code` output still finds the expected region structure, but it degrades content badly inside the recognized regions:

- `JNDI` → `INDI`
- `<local-jndi-name>` → `<local-indi-name>`
- `AddressEJB` → `AddressJDBC`
- malformed XML tags and missing punctuation/fences

The peer port preserves substantially more of the same content from almost the same regions.

### 3. Layout boxes differ, but not enough to explain the whole gap by themselves

The two Swift ports' `code` region boxes are broadly aligned, and the large code-block region is especially close. Treat bbox drift as a possible contributor, but not as the primary current explanation.

### 4. The strongest current root-cause suspects are in the GLM-OCR image preprocessing/runtime path

#### Suspect A — runtime vision-input dtype alignment (high priority)

The maintained repo currently defaults `GLMOCRImageProcessingOptions.dtype` to `.bfloat16`, and only aligns the image tensor dtype to the loaded vision-weight dtype when:

- `GLMOCR_ALIGN_VISION_DTYPE=1`, or
- `GLMOCR_RUN_GOLDEN=1`

The peer Swift port, by contrast, casts `pixel_values` to the model vision dtype on every inference path.

For blurry, glyph-dense crops, this is a plausible accuracy loss multiplier.

#### Suspect B — default resize backend choice (high priority)

The maintained repo defaults to `CoreImage` bicubic resize.
The peer Swift port uses a deterministic CPU bicubic resize path.

For `code`, this matters because at least one critical algorithm-line crop is extremely short in height and must be rescaled into the model's grid-aligned target size. For such thin text lines, a slightly softer resize path can materially reduce legibility.

#### Suspect C — algorithm/code formatting normalization gap (secondary but worth fixing)

The peer port normalizes `algorithm` regions into fenced XML code blocks where appropriate.
The maintained repo currently lacks that algorithm-specific normalization.

This does not explain the whole text-fidelity deficit, but it does affect user-visible structure and some evaluator dimensions.

## Working interpretation

For the current `code` gap, the most credible near-term plan is:

1. fix runtime vision-input dtype alignment first
2. compare resize backends on the hard examples with artifact capture
3. close the algorithm/code formatting gap
4. only then decide whether a deeper crop/layout investigation is still necessary

The `page` example should travel with the same workstream, because it is another dense mixed-layout case likely to react to the same preprocessing/runtime changes.

## Non-goals

- no broad architecture rewrite
- no silent rebaseline of `examples/result/*`
- no new CI gating until the hard-example behavior is understood and stabilized

Use `tracker.md` in this folder for the ordered execution plan.
