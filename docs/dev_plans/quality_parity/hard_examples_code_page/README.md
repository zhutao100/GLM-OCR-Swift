# Hard examples: `code` and `page`

**Status (2026-03-11):** first-pass runtime/preprocessing corrections landed. `code` improved materially, `page` stayed stable, and the remaining `page` gap is now tracked as a residual follow-up rather than a reason to broaden the resize-policy change.

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

#### Suspect A — runtime vision-input dtype alignment (resolved)

The maintained repo now aligns image tensors to the loaded vision-weight dtype by default, with explicit debug overrides via `GLMOCR_ALIGN_VISION_DTYPE` and `GLMOCR_VISION_INPUT_DTYPE`.

On the pinned parity snapshot, the loaded GLM vision weights resolve to `bfloat16`, so this was a correctness hardening step rather than the lever that moved the checked-in `code` score.

#### Suspect B — resize backend choice (accepted, adaptive)

Artifact-backed A/B runs under `.build/hard_example_probes/*` showed:

- the pinned parity snapshot still uses `bfloat16` vision weights
- switching **all** OCR crops to deterministic CPU bicubic raised `code` to `0.8988`, held `table` flat, and regressed `page` to `0.7046`
- restricting deterministic resize to short, wide text-line crops recovered `code` to `0.9016` while keeping `page` and `table` effectively unchanged

The maintained policy is therefore: keep Core Image as the general default, but adaptively use deterministic CPU bicubic for layout text-line crops where the crop is both short and wide.

#### Suspect C — algorithm/code formatting normalization gap (resolved)

The maintained formatter now normalizes XML-like `algorithm` blocks from ` ```html ` to ` ```xml ` while preserving real HTML content. This did not drive the `code` score improvement by itself, but it removes a known structure/style gap.

## Working interpretation

The first-pass execution result is now:

1. default-on vision-input dtype alignment is in place
2. preprocess artifact capture is available through `GLMOCRPreprocessDebugCLI`
3. adaptive deterministic resize is accepted for short, wide layout text-line crops
4. algorithm/code fence normalization is in place

The remaining `page` gap should now be treated as a later crop/layout or formatting follow-up, not as evidence that the repo should switch the entire OCR path to deterministic resize.

## Non-goals

- no broad architecture rewrite
- no silent rebaseline of `examples/result/*`
- no new CI gating until the hard-example behavior is understood and stabilized

Use `tracker.md` in this folder for the ordered execution plan.
