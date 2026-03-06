# Context: Preprocessing and fusion primitives porting: GLM-OCR-Swift vs glm-ocr.swift

This document compares the two Swift ports of GLM-OCR (GLM-OCR-Swift and glm-ocr.swift) with a focus on their preprocessing and fusion implementations. It evaluates their parity with the official Python SDK and Hugging Face Transformers implementation, as well as their architectural design and implementation quality. Finally, it provides concrete recommendations for improving GLM-OCR-Swift’s fidelity while maintaining its architectural strengths.

## Background

You’ve effectively got **two Swift/MLX “local inference” ports** that are trying to match two distinct references:

1. **Official `zai-org/GLM-OCR` GitHub repo (Python SDK)**

   * This repo’s default OCR path is *service/client-driven* (`OCRClient` → `/v1/chat/completions`), not in-process model execution.
   * The **ground-truth behaviors to match** from this repo are mainly:

     * **prompt policy** (`default_prompt`, `task_prompt_mapping`)
     * **image resize policy** (`smart_resize` + pixel-budget divisibility)
     * **layout postprocess + formatting** (`layout_postprocess_utils`, `result_formatter`)

2. **Hugging Face Transformers implementation (model semantics)**

   * This is the real source of truth for:

     * **tensor shapes / weight mapping**
     * **RoPE/mRoPE details**
     * **vision encoder math + merge/downsample behavior**
     * **PP-DocLayout-V3 architecture + decoder/postprocess expectations**

So, below “parity quality” is split into:

* **SDK parity** (prompting, resize policy, layout formatting)
* **Transformers parity** (numerics/architecture/weights)

---

## Executive summary

### If you want one “mainline” repo

**`GLM-OCR-Swift` is the stronger foundation** for a long-lived port:

* clearer modular architecture (`VLMRuntimeKit` + adapters)
* materially stronger **documentation and parity tooling** (golden fixtures, intermediate probes, etc.)
* broader test coverage (32 test files vs 12)

### If you care about “last-mile fidelity” today

**`glm-ocr.swift` has the more faithful and configurable “processor-level” implementation** in a few critical places:

* image preprocessing is much closer to the **GLM46V/GLM-OCR processor conventions** (explicit patch packing order + optional JPEG round-trip)
* fusion and batch handling are more vectorized/efficient
* generation is more featureful (sampling/params surfaced)

### Practical recommendation

Use **`GLM-OCR-Swift` as the canonical repo**, and **selectively port the best “fidelity primitives”** from `glm-ocr.swift` into it (details below). Treat `glm-ocr.swift` as a valuable reference implementation / staging area.

---

## Side-by-side evaluation

### 1) Parity quality

| Area                                                 |          GLM-OCR-Swift | glm-ocr.swift | Notes / evidence                                                                                                                                                                                                                                           |
| ---------------------------------------------------- | ---------------------: | ------------: | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Prompt policy parity (SDK)**                       |               **High** |          High | Both encode the official `default_prompt` + task prompts; `GLMOCRProcessor` in GLM-OCR-Swift mirrors config defaults.                                                                                                                                      |
| **Chat-template mechanics parity**                   |        **Medium–High** |        Medium | GLM-OCR-Swift builds token IDs structurally (`GLMOCRChatTemplate`) and appends `/nothink`; `glm-ocr.swift` uses a hardcoded string template in `GLMOCRPrompt`. Template drift risk exists in both, but GLM-OCR-Swift is easier to validate token-by-token. |
| **Image resize policy parity (SDK)**                 |                   High |          High | Both implement the same *divisibility + pixel-budget* logic from `smart_resize` (official `image_utils.py`).                                                                                                                                               |
| **Image preprocessing fidelity (Transformers-like)** |             **Medium** |      **High** | `glm-ocr.swift` explicitly patchifies into the merge-block ordering and supports JPEG round-trip; GLM-OCR-Swift uses a simpler CIImage→tensor path without the same “processor knobs.” This is the biggest parity differentiator.                          |
| **Weight mapping correctness**                       |                   High |     **High+** | Both transpose conv weights (`patch_embed`, `downsample`). `glm-ocr.swift` detects “already-MLX” layout and drops `position_ids` keys; GLM-OCR-Swift does not, so it’s slightly more brittle to variant checkpoints.                                       |
| **RoPE / mRoPE parity**                              |               **High** |          High | GLM-OCR-Swift has a direct, constrained port of `get_rope_index` for the single-image case and a careful text rotary implementation. `glm-ocr.swift` is also close, but has at least one suspicious default (`mropeSection` fallback).                     |
| **PP-DocLayout-V3 parity**                           | **High (engineering)** |   Medium–High | GLM-OCR-Swift has a full adapter split into many files + explicit intermediate probe infrastructure. `glm-ocr.swift` appears complete but is less “parity-instrumented.”                                                                                   |
| **Layout formatting parity (SDK)**                   |                   High |          High | Both have formatter logic that clearly targets the official `ResultFormatter` behaviors.                                                                                                                                                                   |

### 2) Architecture / layout / design principles

**GLM-OCR-Swift**

* **Strong separation of concerns**:

  * `VLMRuntimeKit` (generation, tokenization wrapper, model store, vision IO)
  * `ModelAdapters/GLMOCR` vs `ModelAdapters/DocLayout`
  * pipeline as an **actor** (`GLMOCRPipeline`, `GLMOCRLayoutPipeline`) with `Sendable` boundaries
* Includes explicit “parity culture” artifacts: `docs/golden_checks.md`, generator scripts, intermediate probes.

**glm-ocr.swift**

* More of a **single-package “vertical slice”**:

  * `Sources/GLMOCR` contains model, processor, layout pipeline, formatter, etc.
* Less modular, but very pragmatic: exposes a lot of “real user” knobs in the parser/config and supports richer generation settings.

### 3) Implementation quality (Swift + MLX-specific)

**GLM-OCR-Swift strengths**

* Cleaner APIs, more controlled concurrency, “library-grade” error types.
* Very strong testing posture (fixtures, golden toggles, deterministic postprocessing).
* Model snapshot resolution abstraction (`ModelStore`) is a good long-term move.

**GLM-OCR-Swift weaknesses / risks**

* **Preprocessing path is simplified** relative to what GLM46V-family processors usually do.

  * Notably, it does *not* expose:

    * patchify/pack ordering controls
    * optional JPEG round-trip (important if your parity baselines were generated through the official SDK path that encodes JPEG)
* **Input dtype alignment is not explicit** in the pipeline:

  * The pipeline’s image tensor dtype defaults to `.bfloat16` in `GLMOCRImageProcessingOptions`,
  * while the model weights may be `float16` depending on snapshot; you ideally want to cast `pixelValues` to the vision weight dtype (as `glm-ocr.swift` does).

**glm-ocr.swift strengths**

* Image processor is **very explicit** and closer to “reference processor behavior”:

  * patchify includes merge-block ordering and temporal padding
  * supports post-resize JPEG round trip
* Fusion is vectorized (`mergeInputEmbedsReplacingTokens`) rather than per-token loops.
* Generation is more complete as an exposed API.

**glm-ocr.swift weaknesses / risks**

* Less modular → harder to evolve and reuse pieces cleanly.
* Some defaults look risky if config fields are absent:

  * `mropeSection` fallback is ` [16, 24, 24]` (Transformers default is `[8, 12, 12]`), so if a future config ever omits it, you could silently diverge.
* Smaller doc/test surface → higher regression risk over time.

---

## Cross-validation: the most important “deltas” between the Swift ports

### A) Image preprocessing philosophy diverges

* `glm-ocr.swift` treats the HF processor family seriously: it patchifies into a token-like matrix and supports “parity knobs” (JPEG round trip).
* `GLM-OCR-Swift` currently implements a simpler “resize + normalize + stack temporal dim” path and feeds `[B, D, H, W, C]` directly into Conv3D.

This difference **may still be semantically equivalent** for the vision encoder (Conv3D patchify on full image vs Conv3D on prepacked patches), but in practice it’s also where:

* interpolation differences
* color management differences
* JPEG round-trip differences
  tend to create visible OCR drift on hard pages (tables, thin fonts, borderline crops).

### B) Fusion implementation quality diverges

* GLM-OCR-Swift fuses embeddings by iterating token positions in Swift (`GLMOCRFusion.fuse`).
* glm-ocr.swift fuses with a vectorized mask/cumsum/gather approach.

This is mostly a **performance** difference, but it also reduces chances of subtle mutation/aliasing issues.

### C) Docs drift / repo ergonomics

One concrete example: `examples/README.md` differs; `glm-ocr.swift` documents the `verify_example_eval.sh` workflow, while GLM-OCR-Swift has a more “agentic” python workflow script but doesn’t mention it in that README. This is easy to fix, but it’s a sign GLM-OCR-Swift is moving faster than some docs.

---

## Concrete recommendations (high leverage)

### 1) Make GLM-OCR-Swift’s preprocessing “processor-faithful” (without losing its architecture)

Port the following ideas from `glm-ocr.swift` into **GLM-OCR-Swift’s `GLMOCRImageProcessor` (or into `VLMRuntimeKit` as a reusable primitive)**:

* **Optional JPEG round-trip after resize** (parity toggle)
* **Explicit patchify + pack ordering** (even if you keep the “Conv3D on full image” path, having a “processor-compatible” mode is extremely useful for golden parity)
* **Always cast `pixelValues` to the vision weight dtype** at the pipeline boundary

Why this matters: it will let you run “strict parity mode” when you need it, without forcing that cost on normal usage.

### 2) Replace GLM-OCR-Swift’s fusion loop with the vectorized fusion

Adopt `mergeInputEmbedsReplacingTokens` style logic to:

* remove per-token assignment loops
* make multi-image extension easier later

### 3) Add a first-class “chat_template conformance test”

Since both ports effectively reimplement the chat template:

* load tokenizer / special token IDs
* build the token stream for a small canonical message
* verify it matches what the tokenizer’s `chat_template` would emit (when available)

This gives you early warning if model-side templates evolve.

### 4) Normalize risky defaults in glm-ocr.swift (even if it becomes “secondary”)

If you keep it around as a reference/staging repo, I’d still fix:

* `mropeSection` fallback to `[8, 12, 12]` (Transformers default)
* tighten dtype alignment in more places (it’s already good in the pipeline)

### 5) Unify evaluation workflow messaging

Pick one repo as canonical (again: GLM-OCR-Swift), then update:

* `examples/README.md`
* root-level “how to run parity eval” docs
  so they reference the *current* scripts (`scripts/example_eval_workflow.py`, etc.).

---

## Bottom line

* **GLM-OCR-Swift** is the better-engineered “platform” repo: modular, testable, designed for long-term evolution and multiple adapters.
* **glm-ocr.swift** is the better “close-to-the-metal processor + pipeline” reference right now: preprocessing fidelity knobs, vectorized fusion, richer generation controls.

If you want the best of both: **promote GLM-OCR-Swift as canonical**, then **surgically port preprocessing + fusion primitives** from glm-ocr.swift into it behind parity toggles. That’s the highest ROI path to “both architecturally clean *and* maximally faithful.”
