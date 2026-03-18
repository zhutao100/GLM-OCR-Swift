# Gateway input preprocessing for degraded OCR inputs

**Status (2026-03-17):** proposed experiment plan.

## Objective

Evaluate a narrow set of deterministic, lightweight image preprocessing mechanisms that can be inserted at the **gateway to OCR input** for `GLM-OCR-Swift`, with two constraints:

1. improve difficult real-world inputs before they reach the GLM-OCR and PP-DocLayout-V3 model paths
2. preserve the repo's accepted artifact contract on the checked-in clean examples

This is an **incremental quality plan**, not a new architecture program. The current repo already has the major preprocessing/runtime parity seams in place. The goal here is to identify which additional gateway steps are worth adding, where they should sit in the pipeline, and which ones should stay experimental only.

## Why this work is worth doing in this repo

The current codebase already exposes the right hooks for disciplined experiments:

- `VLMRuntimeKit/VisionIO`
  - deterministic decode, PDF rasterization, region cropping, RGB tensor conversion
- `GLMOCRAdapter/GLMOCRImageProcessor`
  - smart resize, normalization, backend selection, optional post-resize JPEG round-trip, inspection helpers
- `GLMOCRPreprocessDebugCLI`
  - crop-level artifact capture for preprocess A/B work
- `GLMOCRLayoutPipeline`
  - one loaded page image reused across layout detection and OCR cropping, plus a narrow adaptive backend override for short, wide text-line crops

That means this repo is already positioned to test gateway preprocessing **without** smuggling ad hoc logic into the CLI or app.

## Current repo-specific observations

The checked-in sample corpus already suggests which gateway mechanisms are likely to matter:

- `examples/source/table.png`
  - photographed paper on a dark background with clear projective distortion
  - strongest candidate for **page crop + perspective rectification**
- `examples/source/page.png`
  - scan-like two-page spread with dark edge/binding artifacts
  - strongest candidate for **border cleanup / canvas normalization**
- `examples/source/handwritten.png`
  - handwritten notebook content on textured/lined paper
  - global binarization and morphology look risky; contrast work must stay conservative
- `examples/source/seal.png`
  - color stamp with textured background
  - grayscale-only or binarized defaults would likely throw away useful signal
- `examples/source/code.png`
  - dense small text where stroke fidelity matters more than “document cleanup” aesthetics
  - heavy denoise or morphology is more likely to hurt than help

The resulting bias is clear: favor gateway operations that **preserve RGB structure and local stroke geometry**. Avoid blanket monochrome/document-scanner transformations as the default path.

## Constraints and placement rules

### 1. Distinguish page-level vs region-level preprocessing

This repo has both:

- a **page-level layout path** through `PPDocLayoutV3Processor`
- a **region-level OCR path** through `GLMOCRImageProcessor`

A step that helps region OCR can still hurt layout detection. Therefore:

- page-level gateway preprocessing must be low-risk and mostly geometry/background cleanup
- stronger contrast or monochrome transforms should be tested first as **region-level OCR-only** experiments

### 2. Keep the default path RGB-first

Both model paths are vision models, not classical binarized OCR engines. That makes aggressive thresholding, line stripping, or morphology materially riskier here than in a Tesseract-style stack.

### 3. Preserve deterministic seams

Any accepted mechanism should be:

- deterministic on CPU
- inspectable via saved intermediate artifacts
- unit-testable on image metadata and pixel-level expectations where practical
- measurable via the existing example/eval tooling

## Candidate mechanisms and repo-specific recommendation

| Mechanism | Likely ROI | Where to apply first | Default posture | Repo-specific rationale |
|---|---:|---|---|---|
| Border / canvas cleanup | High | page input | **Promising** | Helps `page.png`-style dark edges and photographed pages without altering glyph structure |
| Page crop + perspective rectification | High on camera captures | page input | **Promising, gated** | Best fit for `table.png`; likely unnecessary for clean scans/PDF raster outputs |
| Deskew | Medium | page input, maybe region input | **Promising, gated** | Cheap if the angle estimate is reliable; should be tried before stronger pixel edits |
| Conservative luma contrast normalization | Medium | region OCR first | **Promising, gated** | May help faded or low-contrast crops without discarding RGB information |
| CLAHE on luma only | Medium | region OCR first | **Promising but second-line** | Useful for uneven local contrast, but easier to over-amplify noise on clean pages |
| Light denoise (small median / bilateral-like equivalent) | Medium-low | region OCR first | **Selective only** | Possible value on camera noise; risky for tiny code glyphs and thin CJK strokes |
| Adaptive threshold / binarization | Medium on narrow cases | region OCR only | **Experimental only** | Too risky as a page-level default for GLM-OCR and PP-DocLayout-V3 |
| Morphological opening/closing / despeckle | Low-medium | post-threshold region OCR only | **Experimental only** | Might help dust/bleed cases, but can easily deform glyphs |
| Rule-line attenuation | Niche | table/text region OCR only | **Defer** | The table path may actually depend on rule structure; low priority until evidence demands it |
| Full page dewarp / heavy restoration | Variable | page input | **Out of scope** | Not lightweight and not aligned with the repo's current maintenance posture |

## Recommended experiment order

### Tier 1 — highest-value, lowest-risk

#### A. Border and canvas cleanup

Add a deterministic border-analysis pass before layout/OCR image processing for non-PDF image inputs:

- trim large uniform dark or near-uniform light margins
- normalize to a small safety border instead of edge-to-edge crops
- keep the original content box if confidence is low

Why first:

- low computational cost
- good match for `page.png` and photographed documents
- does not alter interior text statistics much

#### B. Page crop + perspective rectification

For photographed page inputs only, test:

- document/background separation
- quad estimation
- `warpPerspective`-style rectification equivalent in the native stack

Why second:

- highest upside for `table.png`
- geometry fix is usually safer than pixel-value “enhancement”
- can be gated by a strong page-on-background detector

#### C. Deskew

Test a small-angle deskew stage after border/page crop and before model-specific resize.

Why still in Tier 1:

- cheap if the angle estimate is stable
- useful for scanner slant and phone capture tilt
- unlikely to harm clean upright inputs when confidence gating is strict

### Tier 2 — selective pixel normalization

#### D. Conservative contrast normalization

Test two variants, region OCR first:

1. mild percentile-based luma stretch
2. luma-only CLAHE with conservative clip limits

Why this tier:

- can help faded text and uneven low-contrast crops
- easier to confine to OCR crops than to the layout detector input
- should remain disabled for already high-contrast crops

#### E. Light denoise

Test only minimal filters first:

- very small median filter for salt-and-pepper-like noise
- optionally a stronger but still deterministic branch for camera-noise cases

Why not default-on:

- `code` and dense CJK text are sensitive to stroke softening
- the repo already has evidence that subtle preprocess differences can move parity materially

### Tier 3 — experimental monochrome branch

#### F. Adaptive threshold + morphology

Keep this explicitly experimental and region-OCR-only. Restrict it to crops that score highly for:

- near-monochrome foreground/background separation
- low color entropy
- obvious background shading or paper texture that obstructs characters

Why this is late-stage only:

- likely to damage handwriting, seals, colored annotations, and mixed-layout pages
- risks hurting the very VLM behavior this repo is trying to preserve

## Proposed architecture seam

### Model-agnostic primitives

Add new deterministic primitives under `VLMRuntimeKit/VisionIO` (or a closely related model-agnostic sub-area), such as:

- border statistics / candidate content box detection
- page quad candidate estimation
- perspective warp helper
- skew-angle estimation
- luma histogram / contrast heuristics
- lightweight noise heuristics

These should remain primitive operations, not policy.

### Adapter-owned policy

Keep enablement policy in the adapters:

- `DocLayoutAdapter`
  - whether page-level gateway cleanup is applied before layout detection
- `GLMOCRAdapter`
  - whether region-level OCR crops receive contrast/denoise/monochrome branches

This matches the repo rule that `VLMRuntimeKit` stays model-agnostic while model-specific policy remains in the adapters.

## What should not become the default path

The following are poor default candidates for this repo's current architecture and corpus:

- global grayscale conversion for all inputs
- blanket binarization for all page or crop inputs
- heavy denoise before every OCR request
- morphology on all text crops
- page dewarping / learned enhancement / super-resolution
- format-specific heuristics that only help a single checked-in example without a more general defect model

## Experimental design

### A. Two evaluation lanes

#### Lane 1 — clean-regression protection

Use the current checked-in corpus and reporting workflow as the “do no harm” gate:

- `scripts/run_examples.sh`
- `scripts/verify_example_eval.sh`
- existing `examples/result/*` and `examples/eval_records/latest/*`

Acceptance posture:

- no meaningful regression on the currently stable subset
- no new artifact-contract churn

#### Lane 2 — degraded-input challenge lane

Add a reproducible **degraded-input experiment set** derived from the checked-in examples.

Recommended synthetic defect families:

- dark borders / oversized margins
- small-angle skew
- perspective warp
- low-contrast / shadowed illumination
- light sensor noise / JPEG-like degradation

Why synthetic first:

- deterministic and versionable
- immediate coverage without waiting for a new manually curated corpus
- allows direct before/after comparison against the known source images

This lane should be report-only at first.

### B. Artifact capture requirements

For every candidate branch, capture:

- original input image or crop metadata
- chosen gateway actions and parameters
- gateway output artifact
- downstream resize backend and tensor summary
- final OCR output and scored eval delta

`GLMOCRPreprocessDebugCLI` is already the natural starting point for region-level artifact capture. A similar page-level capture path should be added only if Tier 1 experiments begin to show value.

## Suggested workstream order

1. build the degraded-input synthetic lane and scoring notebook/report path
2. implement border/canvas cleanup prototype
3. prototype page crop + perspective rectify for photographed documents
4. add deskew if Tier 1 evidence remains positive
5. prototype conservative contrast normalization on OCR crops
6. prototype light denoise on OCR crops
7. only then consider an experimental monochrome branch

## Preliminary acceptance criteria

A mechanism is worth keeping only if it satisfies all of the following:

1. **Improves the targeted degraded lane**
   - measurable uplift on the matching defect family
2. **Does not materially regress the clean checked-in corpus**
   - especially `code`, `page`, `paper`, and the GLM-4.5V PDF examples
3. **Can be gated by observable image properties**
   - not by hidden per-example allowlists
4. **Fits the repo's maintenance posture**
   - deterministic, lightweight, and easy to debug

## Initial recommendation

The strongest candidates for `GLM-OCR-Swift` are:

1. **border / canvas cleanup**
2. **page crop + perspective rectification for photographed documents**
3. **deskew**
4. **conservative luma contrast normalization on OCR crops**

The weakest default candidates are:

- blanket adaptive thresholding
- morphology-heavy cleanup
- any transformation that discards color or materially rewrites glyph shapes before the VLM sees them

That ordering fits both the repo's current architecture and the visible characteristics of the checked-in example corpus.
