# Reference projects

This document captures the detailed survey of reference Swift OCR projects (DeepSeek-OCR / DeepSeek-OCR2 / PaddleOCR-VL)
and adjacent “inference scaffolding” repos, including reusable component inventory and architecture comparison.

---

## 1) Project survey table

| Project                                | What it is                                                | Stack / deps                                                            | Why it’s relevant to a GLM-OCR Swift port                                                                                                                         |
| -------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mzbac/deepseek-ocr.swift`             | SwiftPM library + signed CLI for DeepSeek-OCR             | MLX Swift + HF `swift-transformers` (`Tokenizers`, `Hub`)               | Clean “Pipeline → ImageProcessor → Generator → Model” layering; good template for a minimal, shippable macOS runner. ([GitHub][4])                                |
| `mzbac/deepseek-ocr2.swift`            | SwiftPM library + CLI + tests for DeepSeek-OCR-2          | MLX Swift + HF `Tokenizers`/`Hub` + custom weights + KV-cache utilities | Strongest reusable **weights loading** + **KV cache** + **generation loop** patterns; closer to what you’ll need for a production-grade VLM runner. ([GitHub][5]) |
| `mlx-community/paddleocr-vl.swift`     | SwiftPM library + CLI for PaddleOCR-VL                    | MLX Swift + HF `swift-transformers`                                     | Best “dynamic resolution / patching” image preprocessing patterns; useful if you want robust PDF/page scaling and multi-task prompts. ([GitHub][6])               |
| `ml-explore/mlx-swift-lm`              | Actively maintained LLM/VLM implementations for MLX Swift | MLX Swift LM                                                            | If GLM-OCR’s architecture can be integrated, this is the most future-proof “inference core” to build on vs bespoke per-model code. ([GitHub][7])                  |
| `ml-explore/mlx-swift-examples`        | Reference macOS/iOS apps + model download patterns        | MLX Swift + MLX Swift LM                                                | “How to ship a SwiftUI MLX app” reference (model download, UI responsiveness, simple chat UX). ([GitHub][8])                                                      |
| `preternatural-explore/mlx-swift-chat` | Multi-platform SwiftUI frontend for local LLMs            | SwiftUI + MLX                                                           | High-signal SwiftUI patterns for local inference apps (UX, model switching, responsiveness). ([GitHub][9])                                                        |

---

## 2) Reusable component inventory

Below are the *highest leverage* reuse candidates for a GLM-OCR Swift implementation, with the **exact types** and what they buy you. I’m listing **file paths + key APIs/types**, and giving GitHub “exact file” links in code blocks (copy/paste).

**Validation:** checked against local checkouts on **2026-02-09** and pinned to these commits:

* `mzbac/deepseek-ocr.swift` @ `5930b620433c866e615341fe2dc52acc4431cc48`
* `mzbac/deepseek-ocr2.swift` @ `637449ccf08069bede24fdc4ef17eb853e1a383a`
* `mlx-community/paddleocr-vl.swift` @ `b31d5ab0bdb87a77ae80b74ec3380fed99f5b706`

### A) `deepseek-ocr.swift` (minimal, very “template-able”)

**1) Public pipeline surface (good “product API” shape)**

* **Type:** `DeepSeekOCRPipeline`
* **Why reuse:** It’s the right abstraction boundary for a macOS GUI app: “construct once → recognize many → batch support”.
* **Refactor for GLM-OCR:** Rename to `GLMOCRPipeline`; swap prompt template + model adapter + vision preprocess.

```text
https://github.com/mzbac/deepseek-ocr.swift/blob/5930b620433c866e615341fe2dc52acc4431cc48/Sources/DeepSeekOCR/DeepSeekOCRPipeline.swift
```

**2) Image preprocessing (CoreImage → MLXArray, padding/resize, normalization)**

* **Types:** `DeepSeekOCRImageProcessor`, `ProcessedImages`, `BatchProcessedImages`, `ProcessingMode`
* **Why reuse:** The end-to-end “CIImage → normalized MLXArray(bfloat16)” plumbing is exactly what you want for drag/drop images and PDF-rendered pages.
* **Refactor for GLM-OCR:** Replace its mode/token-count assumptions with GLM-OCR’s expected vision encoder input sizing; keep the CoreImage/CGImage/MLX conversion utilities.

```text
https://github.com/mzbac/deepseek-ocr.swift/blob/5930b620433c866e615341fe2dc52acc4431cc48/Sources/DeepSeekOCR/ImageProcessor.swift
```

**3) Generation loop (token-by-token decode; easy to add cancellation)**

* **Types:** `DeepSeekOCRGenerator`, `GenerationResult`, `BatchGenerationResult`
* **Why reuse:** Straightforward decode loop that can be upgraded to:

  * `AsyncStream<Token>` streaming for UI
  * cooperative cancellation (`Task.isCancelled`) per token
* **Refactor for GLM-OCR:** Replace special tokens/EOS logic + integrate GLM-OCR’s image-token insertion scheme.

```text
https://github.com/mzbac/deepseek-ocr.swift/blob/5930b620433c866e615341fe2dc52acc4431cc48/Sources/DeepSeekOCR/Generator.swift
```

**4) Weight loading + key-munging patterns**

* **Types:** `DeepSeekOCRModel.load(from:)` (plus internal `loadWeights(for:from:)` and `sanitizeWeights(_:)` key mapping)
* **Why reuse:** Even if GLM-OCR is architecturally different, the *pattern* (read config → load safetensors → rename keys → postprocess tensors → init modules) is the core of any Swift port.
* **Refactor for GLM-OCR:** Implement GLM-OCR-specific key mapping; keep the structure.

```text
https://github.com/mzbac/deepseek-ocr.swift/blob/5930b620433c866e615341fe2dc52acc4431cc48/Sources/DeepSeekOCR/DeepSeekOCRModel.swift
```

**5) CLI UX + distribution pattern (signed artifact, “model download then run”)**

* **Types:** `DeepSeekOCRCommand`, `OCRCommand`, `QuantizeCommand`
* **Why reuse:** ArgumentParser wiring and “download/cache model folder then run” maps directly to “GUI: pick model → download → run”.

```text
https://github.com/mzbac/deepseek-ocr.swift/blob/5930b620433c866e615341fe2dc52acc4431cc48/Sources/DeepSeekOCRCLI/main.swift
```

---

### B) `deepseek-ocr2.swift` (most “production-grade” core utilities)

**1) Weights loader (the single biggest reuse win)**

* **Type:** `WeightsLoader` (plus `WeightsLoaderError`)
* **Why reuse:** Centralizes **dtype selection**, **multi-file safetensors loading**, and **MLX array construction**. You will need an equivalent for GLM-OCR.
* **Refactor for GLM-OCR:** Keep as-is; only adapt how you enumerate shards / index and how you map parameter names.

```text
https://github.com/mzbac/deepseek-ocr2.swift/blob/637449ccf08069bede24fdc4ef17eb853e1a383a/Sources/DeepSeekOCR2/Weights/WeightsLoader.swift
```

**2) KV cache utilities (especially for batch + long documents)**

* **Types:** `KVCache`, `KVCacheRagged`, `KVCacheSimple`, `KVCacheRaggedSimple`
* **Why reuse:** GLM-OCR can emit long Markdown; KV cache correctness and memory behavior will dominate performance.
* **Refactor for GLM-OCR:** Usually minimal—cache is “decoder generic” as long as attention implementation matches.

```text
https://github.com/mzbac/deepseek-ocr2.swift/blob/637449ccf08069bede24fdc4ef17eb853e1a383a/Sources/DeepSeekOCR2/Utils/KVCache.swift
```

**3) Prompt splitting for multimodal `<image>` insertion**

* **Type:** `DeepseekOCR2Generator.tokenizePromptParts(prompt:)` (private helper)
* **Why reuse:** This is the exact pattern you’ll need if GLM-OCR uses an `<image>` placeholder or equivalent “image then text” chat template.
* **Refactor for GLM-OCR:** Change special token ids / image token budget logic.

```text
https://github.com/mzbac/deepseek-ocr2.swift/blob/637449ccf08069bede24fdc4ef17eb853e1a383a/Sources/DeepSeekOCR2/DeepseekOCR2/DeepseekOCR2Generator.swift
```

**4) Image processor that encodes “vision token budget” explicitly**

* **Types:** `DeepseekOCR2ImageProcessor`, `DeepseekOCR2ProcessedImages`
* **Why reuse:** Nice precedent for validating input sizes and calculating image-token counts.
* **Refactor for GLM-OCR:** Replace constants (image size, patch size, token count formula) with GLM-OCR/CogViT expectations.

```text
https://github.com/mzbac/deepseek-ocr2.swift/blob/637449ccf08069bede24fdc4ef17eb853e1a383a/Sources/DeepSeekOCR2/DeepseekOCR2/DeepseekOCR2ImageProcessor.swift
```

**5) Pipeline shape + model injection pattern**

* **Types:** `DeepseekOCR2Pipeline`, `DeepseekOCR2InjectedForCausalLM`
* **Why reuse:** Clean separation between “pipeline orchestration” and “model core”, including injection/hooking patterns you may need for GLM-OCR connector layers.

```text
https://github.com/mzbac/deepseek-ocr2.swift/blob/637449ccf08069bede24fdc4ef17eb853e1a383a/Sources/DeepSeekOCR2/DeepseekOCR2/DeepseekOCR2Pipeline.swift
https://github.com/mzbac/deepseek-ocr2.swift/blob/637449ccf08069bede24fdc4ef17eb853e1a383a/Sources/DeepSeekOCR2/DeepseekOCR2/DeepseekOCR2Model.swift
```

---

### C) `paddleocr-vl.swift` (best “robust preprocessing” patterns)

**1) Smart resize strategy (min/max pixels → stable quality/perf tradeoff)**

* **Type:** `PaddleOCRVLImageProcessor` dynamic-resize flow (`processDynamicResolution` + private `smartResize(width:height:)`)
* **Why reuse:** For a GUI OCR app, you’ll process:

  * huge PDFs (A4 scans, 300–600 DPI)
  * phone photos (wide variance)
    Smart resizing is essential for latency + avoiding OOM.
* **Refactor for GLM-OCR:** Keep the strategy, change constants to match GLM-OCR vision encoder’s preferred operating range.

```text
https://github.com/mlx-community/paddleocr-vl.swift/blob/b31d5ab0bdb87a77ae80b74ec3380fed99f5b706/Sources/PaddleOCRVL/ImageProcessor.swift
```

**2) Pipeline supports “task presets” (OCR/table/formula style workflows)**

* **Types:** `PaddleOCRVLPipeline`, `PaddleOCRTask`
* **Why reuse:** GLM-OCR explicitly supports different prompt scenarios (“Text / Formula / Table”, plus structured extraction). Modeling that as a first-class “task” improves UX. ([Hugging Face][10])

```text
https://github.com/mlx-community/paddleocr-vl.swift/blob/b31d5ab0bdb87a77ae80b74ec3380fed99f5b706/Sources/PaddleOCRVL/PaddleOCRVLPipeline.swift
https://github.com/mlx-community/paddleocr-vl.swift/blob/b31d5ab0bdb87a77ae80b74ec3380fed99f5b706/Sources/PaddleOCRVL/Configuration.swift
```

## 2.5) Borrowing map (source → target module)

Validated against the local sibling checkouts in this workspace:

* `../deepseek-ocr.swift`
* `../deepseek-ocr2.swift`
* `../paddleocr-vl.swift`

Planned landing zones in this repo:

* `VLMRuntimeKit/ModelStore`: HF snapshot download + cache conventions (DeepSeek OCR repos’ Hub patterns; Phase 01)
* `VLMRuntimeKit/VisionIO`: CIImage/PDFKit decode → MLXArray + normalization (DeepSeek OCR), plus smart resize policy (PaddleOCR-VL; Phase 02)
* `VLMRuntimeKit/TokenizerKit`: `<image>` placeholder splitting + “prompt parts” tokenization patterns (DeepSeek OCR2; Phase 02)
  * Keep special token ids and image-token budgeting constants in `GLMOCRAdapter`
* `VLMRuntimeKit/Weights`: sharded safetensors loading + dtype selection (DeepSeek OCR2 `WeightsLoader`; Phase 03)
  * Keep GLM-OCR weight name mapping in `GLMOCRAdapter`
* `VLMRuntimeKit/Generation`: token-by-token greedy decode skeleton (DeepSeek OCR) + KV cache utilities (DeepSeek OCR2; Phase 02/03)
* `GLMOCRAdapter`: config parsing, model-specific prompt formatting, vision sizing policy, token ids, and connector glue (Phase 02/03)
* `GLMOCRApp`: job queue + responsiveness patterns (mlx-swift-chat / mlx-swift-examples; Phase 05)

License/attribution notes when copying code:

* `deepseek-ocr.swift`: MIT (per README)
* `deepseek-ocr2.swift`: Apache-2.0 (`LICENSE`)
* `paddleocr-vl.swift`: MIT (`LICENSE`)

---

## 3) Architecture comparison

| Dimension              | deepseek-ocr.swift                                | deepseek-ocr2.swift                                     | paddleocr-vl.swift                        |
| ---------------------- | ------------------------------------------------- | ------------------------------------------------------- | ----------------------------------------- |
| Dependency strategy    | MLX Swift + `swift-transformers`                  | MLX Swift + `Tokenizers`/`Hub` + more custom infra      | MLX Swift + `swift-transformers`          |
| Model abstraction      | “Single model, clean pipeline”                    | More modular + utilities (weights, cache, tests)        | Single model + task presets               |
| Preprocessing posture  | Fixed-ish modes; padding/resize; good batch hooks | Explicit token budgeting + multi-image prompt splitting | Strong “smart resize” for real-world docs |
| Generation             | Straightforward decode loop                       | More advanced prompt splitting; better cache patterns   | Similar to deepseek-ocr.swift             |
| Best reuse for GLM-OCR | Pipeline/API shape + CI→MLX conversion            | WeightsLoader + KVCache + multimodal prompt insertion   | Smart resize + task preset UX             |

---

## 4) What GLM-OCR implies for your Swift design

From the model card: GLM-OCR is a **GLM-V encoder–decoder** with a **CogViT** visual encoder + connector + **GLM-0.5B** decoder, and the “full pipeline” is **layout analysis (PP-DocLayout-V3) + parallel recognition**. ([Hugging Face][10])

From the official MLX example: the reference Apple-Silicon path is currently Python-centric and integrates into an API/service style workflow. ([GitHub][11])

**Implication:** for a macOS GUI app, you should plan for two milestones:

1. **MVP**: single-image / single-page GLM-OCR → Markdown/text
2. **Quality parity**: add a **layout stage** (DocLayout) and multi-region OCR orchestration (parallel runs + merge)

---

## 5) Decision: standalone GLM-OCR vs consolidated multi-model project

### Recommendation

**Start as a standalone GLM-OCR Swift project**, but architect it as **“core + adapter”** from day one so consolidation is a mechanical refactor, not a rewrite.

This matches your “Apple-native end state” goal while avoiding early scope creep, and aligns with a direct-download/notarized distribution path that stays lightweight and offline-first. (You can still add DeepSeek-OCR/PaddleOCR-VL later as adapters if you want a single “OCR workbench” app.)

### Proposed structure (module boundaries)

* `VLMRuntimeKit` (shared core)

  * `ModelStore` (HF snapshot/download + local cache)
  * `Weights` (safetensors loading, dtype/quant selection)
  * `TokenizerKit` (chat template + multimodal placeholder splitting)
  * `VisionIO` (CIImage/CGImage/PDFKit decode + resize/normalize)
  * `Generation` (decoder loop, KV cache, streaming)
* `GLMOCRAdapter` (model-specific; lives at `Sources/ModelAdapters/GLMOCR`)

  * `GLMOCRConfig`, `GLMOCRProcessor`, `GLMOCRModel`, `GLMOCRPipeline`
* `GLMOCRApp` (SwiftUI)

  * drag/drop images + PDFs, clipboard import
  * task presets: Text / Formula / Table + JSON extraction mode ([Hugging Face][10])
  * job queue + cancellation + progress + export (Markdown/JSON)

### Suggested public API for the shared core (so future consolidation is easy)

```swift
public protocol OCRPipeline {
  associatedtype Input
  func recognize(_ input: Input, task: OCRTask, options: GenerateOptions) async throws -> OCRResult
}

public enum OCRTask {
  case text
  case formula
  case table
  case structuredJSON(schema: String)
}

public struct OCRResult: Sendable {
  public var text: String
  public var rawTokens: [Int]?
  public var diagnostics: Diagnostics
}
```

---

## 6) GUI app solution options (macOS, Apple Silicon)

### Option 1 — **Pure SwiftUI + MLX Swift + HF Swift tooling (recommended end-state)**

* **Core idea:** replicate the reference repos’ structure; use `Hub.snapshot` + `AutoTokenizer` from HF Swift tooling for model distribution, then MLX Swift for inference. ([GitHub][12])
* **Pros:** best startup time, simplest UX, easiest to notarize; no Python/Rust runtime baggage.
* **Cons:** you must implement/port GLM-OCR model architecture + (eventually) layout stage.

### Option 2 — **SwiftUI app on top of MLX Swift LM (if GLM-OCR can be integrated)**

* **Core idea:** upstream/add GLM-OCR as a VLM model inside `mlx-swift-lm`, and use `mlx-swift-examples` / similar SwiftUI scaffolding. ([GitHub][7], [GitHub][8])
* **Pros:** least long-term maintenance; you ride an actively maintained inference core.
* **Cons:** only viable if GLM-OCR architecture fits (or you’re willing to do a non-trivial upstream port).

---

## 7) App distribution plan (macOS)

**Primary (recommended): Developer ID + notarized direct download**

* Ship a signed `.dmg` (or `.pkg`) with:

  * app binary
  * zero bundled weights by default (optional “starter pack”)
  * first-run model download into `Application Support`
* Optional: integrate Sparkle for auto-updates (outside Mac App Store).

**Secondary: Mac App Store**

* Feasible, but expect friction:

  * sandbox file access (security-scoped bookmarks)
  * very large model assets → you’ll almost certainly rely on post-install downloads
  * careful review posture around “downloading model files” (data is OK; still design conservatively)

HF Swift tooling already provides model download + progress hooks suitable for a GUI “Model Manager”. ([GitHub][12])

---

## 8) Immediate next steps (top 5 engineering tasks)

1. **Lock the GLM-OCR interface contract**

   * Define prompt presets (Text/Formula/Table/JSON extraction) and output format expectations from the model card. ([Hugging Face][10])
2. **Build `ModelStore` + downloader**

   * Use HF snapshot downloads with progress + resumability; local cache layout in `Application Support`. ([GitHub][12])
3. **Implement `VisionIO` for GUI inputs**

   * drag/drop images + **PDFKit page rendering** → CIImage → MLXArray, borrowing the reference repos’ conversion/normalize patterns.
4. **Spike GLM-OCR model load in Swift**

   * Minimal “load config + load weights + run one forward pass” harness; decide whether you can target `mlx-swift-lm` or need bespoke modules.
5. **SwiftUI job system**

   * `OCRJob` queue with cancellation + progress + streaming decode; use proven SwiftUI inference patterns from mlx-swift-chat / mlx-swift-examples. ([GitHub][9])

These map directly to the repo’s phase plans in `docs/dev_plans/`:

* Phase 01: `docs/dev_plans/01_modelstore.md`
* Phase 02: `docs/dev_plans/02_mvp_single_image.md`
* Phase 03: `docs/dev_plans/03_model_port.md`
* Phase 04: `docs/dev_plans/04_layout_stage.md`
* Phase 05: `docs/dev_plans/05_gui_polish_distribution.md`

[4]: https://github.com/mzbac/deepseek-ocr.swift "GitHub - mzbac/deepseek-ocr.swift"
[5]: https://github.com/mzbac/deepseek-ocr2.swift "GitHub - mzbac/deepseek-ocr2.swift"
[6]: https://github.com/mlx-community/paddleocr-vl.swift "GitHub - mlx-community/paddleocr-vl.swift: Native Swift + MLX port of PaddleOCR-VL, a 0.9B doc parsing VLM for OCR, tables, formulas, and charts on Apple Silicon"
[7]: https://github.com/ml-explore/mlx-swift-lm "GitHub - ml-explore/mlx-swift-lm: LLM/VLM implementations for MLX Swift"
[8]: https://github.com/ml-explore/mlx-swift-examples "GitHub - ml-explore/mlx-swift-examples: Examples using MLX Swift"
[9]: https://github.com/preternatural-explore/mlx-swift-chat "GitHub - preternatural-explore/mlx-swift-chat: A multi-platform SwiftUI frontend for running local LLMs with Apple's MLX framework."
[10]: https://huggingface.co/zai-org/GLM-OCR "zai-org/GLM-OCR · Hugging Face"
[11]: https://raw.githubusercontent.com/zai-org/GLM-OCR/refs/heads/main/examples/mlx-deploy/README.md "raw.githubusercontent.com"
[12]: https://github.com/huggingface/swift-transformers "GitHub - huggingface/swift-transformers: Swift Package to implement a transformers-like API in Swift"
