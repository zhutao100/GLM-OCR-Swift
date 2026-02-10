# Phase 03 Implementation Plan — MVP single image / single PDF page → text

## Summary
Deliver true end-to-end OCR for **one image** or **one PDF page** by filling the remaining stubs in:
- `VLMRuntimeKit/VisionIO` (PDF render + CIImage→MLX tensor conversion)
- `GLMOCRAdapter` (GLM-OCR chat template + image token alignment + greedy decode loop)
- `GLMOCRCLI` / `GLMOCRApp` (PDF page selection + wiring to new runtime)

Target outcomes match `docs/dev_plans/03_mvp_single_image.md` exit criteria:
- `swift run GLMOCRCLI --input <path>` prints OCR text for image/PDF-page
- App runs OCR for dropped image/PDF and shows output
- Manual parity check vs official MLX Python example on 3–5 images

---

## Decisions (locked for implementer)
1. **PDF page selection**
   - CLI: add `--page` (1-based, default `1`) used only when input is a PDF.
   - App: MVP always uses page `1` for PDFs (no UI yet).
2. **PDF render quality**
   - Render using PDFKit at `dpi = 200` (matches `../GLM-OCR/glmocr/config.yaml`), then pass through GLM smart-resize before tensorization.
3. **Vision preprocessing ownership**
   - `VLMRuntimeKit/VisionIO` provides *generic primitives*: decode, render, resize helpers, CIImage→RGB tensor, optional normalization.
   - `GLMOCRAdapter` owns *GLM-specific policy*: smart-resize constants, temporal replication (`D=2`), token count computation, mean/std defaults.
4. **Smart resize policy (GLM-OCR defaults)**
   - Use the official pipeline defaults as Swift defaults (overrideable later):
     - `t_patch_size = 2`
     - `patch_expand_factor = 1`
     - `min_pixels = 12544`
     - `max_pixels = 71372800`
   - Enforce `H` and `W` divisible by `patch_size * spatial_merge_size * patch_expand_factor` (i.e. `14 * 2 * 1 = 28`).
5. **Normalization**
   - Load mean/std from `preprocessor_config.json` if present.
   - Fallback mean/std = `(0.5, 0.5, 0.5)` (DeepSeek/Paddle patterns), with scaling `uint8 / 255`.
6. **Generation**
   - Implement **greedy decoding** (`argmax`) with:
     - stop on `eosId` or `maxNewTokens`
     - `Task.checkCancellation()` each step
   - Start with **no KV-cache** (correctness-first), then add KV-cache as a second pass if performance is unacceptable; both are specified below so the implementer does not need to decide later.

---

## Public API / interface changes (explicit)
### 1) Runtime generation API becomes multimodal
Update `VLMRuntimeKit/Generation/Generation.swift`:
- Change `CausalLM.generate` to accept image inputs:
  - Option A (minimal): `func generate(prompt: String, pixelValues: MLXArray?, options: GenerateOptions) async throws -> (text: String, tokenIDs: [Int]?)`
  - Update `GreedyGenerator.run(...)` accordingly.

Rationale: OCR cannot run without `pixelValues`; avoiding hidden mutable state is more testable.

### 2) Pipeline input supports PDF page index
Update `GLMOCRAdapter` input type:
- Change `GLMOCRInput.fileURL(URL)` → `GLMOCRInput.file(URL, page: Int?)` (where `page` is 1-based; nil means “auto”, but we will always pass a concrete value).
- Keep `.predecodedText(String)` unchanged for UI wiring.

---

## Implementation steps (by task in `03_mvp_single_image.md`)

### A) VisionIO — PDF page rendering (PDFKit → CIImage)
Files:
- `Sources/VLMRuntimeKit/VisionIO/VisionIO.swift`
- `Package.swift` (link PDFKit to `VLMRuntimeKit` target)

Work:
1. Add `import PDFKit` under macOS.
2. Add `VisionIO.loadCIImage(fromPDF url: URL, page: Int, dpi: CGFloat = 200) throws -> CIImage`
   - Validate file exists, load `PDFDocument(url:)`, select `page-1`.
   - Render into `CGContext`:
     - page rect via `page.bounds(for: .mediaBox)`
     - compute pixel size = rect(in points) * (dpi / 72)
     - fill white background, draw PDF page, produce `CGImage`, wrap into `CIImage`.
3. Define `VisionIOError.cannotRenderPDF(URL)` and (if needed) `cannotLoadPDFPage(url:page:)` for better diagnostics.

Acceptance:
- Unit/integration test can confirm rendering returns non-zero extent for a known tiny PDF (see tests section).

---

### B) VisionIO — CIImage → MLX tensor conversion + normalization
Files:
- `Sources/VLMRuntimeKit/VisionIO/VisionIO.swift` (or split into `ImageTensorConverter.swift` if preferred)

Work:
1. Replace the `ImageTensorConverter.toTensor(_:)` stub with a working implementation:
   - Render via `CIContext.render(... toBitmap: ...)` into RGBA8.
   - Convert to `MLXArray` of shape `[1, H, W, 3]` float32 in `[0,1]`.
2. Add an options struct (model-agnostic):
   - `ImageTensorConversionOptions(dtype: DType = .bfloat16, mean: (Float,Float,Float)?, std: ...?)`
   - If mean/std provided, apply `(x - mean) / std` using MLX broadcasting.
3. Keep color space explicit: sRGB.

Acceptance:
- `VisionIO` conversion yields correct shape and approximate values for a synthetic CIImage (constant color) test.

---

### C) GLMOCRAdapter — image preprocessing policy + token alignment
Files:
- `Sources/ModelAdapters/GLMOCR/GLMOCRProcessor.swift`
- Add: `Sources/ModelAdapters/GLMOCR/GLMOCRImageProcessor.swift` (new)

Work:
1. Implement `GLMOCRImageProcessor`:
   - Inputs: `CIImage`, `GLMOCRConfig` (for `patchSize`, `temporalPatchSize`, `spatialMergeSize`, `imageSize` if needed)
   - Smart-resize:
     - port `smart_resize` logic from `../GLM-OCR/glmocr/utils/image_utils.py` (deterministic pure function)
     - enforce divisibility by `factor = patchSize * spatialMergeSize * patchExpandFactor` (default 28)
     - enforce pixel budget using defaults listed above
   - Resize with `CIFilter.bicubicScaleTransform()` (consistent with reference repos).
2. Convert to tensor:
   - Use `ImageTensorConverter.toTensor(image, options: ...)` to get `[1,H,W,3]`.
   - Expand to GLM-required `pixelValues` of shape `[1, D, H, W, 3]` where `D = temporalPatchSize` by repeating along depth.
   - Choose dtype via options (default `.bfloat16` for runtime; parity/golden fixtures may require `.float16` depending on the reference stack/device).
3. Compute `numImageTokens` deterministically from final size:
   - `gridH = H / patchSize`, `gridW = W / patchSize`
   - `downH = gridH / spatialMergeSize`, `downW = gridW / spatialMergeSize`
   - `depthTokens = D / temporalPatchSize` (for static: `1`)
   - `numImageTokens = depthTokens * downH * downW`

Acceptance:
- For the current default path (resized to 336×336), `numImageTokens` matches the existing forward-pass harness expectation.

---

### D) GLMOCRAdapter — real chat template + tokenization correctness
Files:
- `Sources/ModelAdapters/GLMOCR/GLMOCRProcessor.swift`
- Add: `Sources/ModelAdapters/GLMOCR/GLMOCRChatTemplate.swift` (new)

Work:
1. Keep `GLMOCRProcessor.instruction(for:)` usage, but adjust prompt construction to match GLM-OCR expectations:
   - Use `<image>` placeholder at the correct position (still supported).
   - Add `/nothink` suffix for OCR determinism (per `docs/GLM-OCR_model.md`).
2. Implement `GLMOCRChatTemplate.buildInputIDs(prompt: String, tokenizer: GLMOCRTokenizer, numImageTokens: Int) throws -> [Int]`:
   - Split prompt by `<image>` using `PromptTemplate(imagePlaceholder:\"<image>\")`.
   - Compose IDs in this exact order:
     1. `[gMASK]`, `<sop>`
     2. `<|user|>` (and include newline tokens by encoding `\"\\n\"` explicitly)
     3. tokenized `prefix`
     4. `<|begin_of_image|>`, then `<|image|>` repeated `numImageTokens`, then `<|end_of_image|>`
     5. tokenized `suffix`
     6. newline, `<|assistant|>`, newline
   - Do not add tokenizer “special tokens” implicitly; rely on explicit IDs + raw encodes.
3. Add a “single-turn OCR prompt builder” helper that returns both:
   - `inputIds: [Int]`
   - `promptTokenCount` and `imageTokenCount` for diagnostics

Acceptance:
- Integration test (requires local snapshot) asserts the prefix/sentinel/role token IDs exist in the expected positions and `<|image|>` count equals `numImageTokens`.

---

### E) GLMOCRAdapter — greedy decode loop (+ cancellation) and (optional) KV-cache pass
Files:
- `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`
- (Optional, second pass) Add: `Sources/VLMRuntimeKit/Generation/KVCache.swift` and modify model layers.

Work — Pass 1 (correctness-first, no cache):
1. Implement `GLMOCRModel.generate(prompt:pixelValues:options:)` (per updated `CausalLM` protocol):
   - Build `inputIds` using `GLMOCRChatTemplate` with `numImageTokens` derived from `pixelValues` shape.
   - Loop for `maxNewTokens`:
     - `Task.checkCancellation()`
     - Run `forward(inputIds: fullSequence, pixelValues: firstStepOnly ? pixelValues : nil)`
     - Take last-position logits, `argmax` to `nextId`
     - Append `nextId`; stop on `eosId`
   - Decode final tokens to string using `tokenizer.tokenizer.decode(tokens:)`.
   - Strip any leading assistant markers if they appear (keep deterministic cleanup rules minimal and tested).
2. Ensure `pixelValues` is only provided on the first forward call to avoid re-encoding.

Work — Pass 2 (performance, KV-cache):
1. Add `KVCacheSimple` (borrow from `../deepseek-ocr2.swift/.../KVCache.swift`) into `VLMRuntimeKit/Generation`.
2. Thread per-layer KV caches through:
   - `GLMOCRSelfAttention` to accept cache + offset and return updated cache
   - apply `RoPE(..., offset:)` using the correct absolute token position
3. Update `GLMOCRModel.generate` to:
   - prompt-fill once (full sequence, caching keys/values)
   - then decode with `seqLen=1` steps using cache

Acceptance:
- Pass 1 must satisfy MVP functionality.
- Pass 2 must reduce latency significantly for long outputs; keep Pass 1 as fallback behind a simple toggle if needed.

---

### F) Wiring — Pipeline, CLI, App
Files:
- `Sources/ModelAdapters/GLMOCR/GLMOCRPipeline.swift`
- `Sources/GLMOCRCLI/GLMOCRCLI.swift`
- `Sources/GLMOCRApp/ContentView.swift`

Work:
1. Pipeline:
   - On `.file(url,page:)`:
     - if `.pdf`: `VisionIO.loadCIImage(fromPDF:page:dpi:)`
     - else: `VisionIO.loadCIImage(from:)`
   - Run `GLMOCRImageProcessor` → `pixelValues`
   - Call `GreedyGenerator.run(model:prompt:pixelValues:options:)`
2. CLI:
   - Add `@Option var page: Int = 1`
   - When input ends with `.pdf`, call `pipeline.recognize(.file(url,page:page), ...)`
3. App:
   - For dropped PDFs, call `.file(url,page:1)`
   - Update UI hint text (“PDF supported”) once implemented
   - Optional: add a “Cancel” button that cancels the running Task (uses Task cancellation already in decode loop)

Acceptance:
- CLI works for both images and PDFs (first page by default).
- App shows OCR output for dropped image/PDF.

---

## Tests (additions + updates)

### 1) VLMRuntimeKitTests
- New: `VisionIOPDFRenderTests`
  - Render a tiny bundled PDF resource (1 page) and assert non-empty `CIImage.extent`.
- New: `ImageTensorConverterTests`
  - Convert a small synthetic CIImage (e.g., solid color) and assert:
    - shape `[1,H,W,3]`
    - value range and normalization approximately correct.

### 2) GLMOCRAdapterTests (integration-style, env-gated)
- New: `GLMOCRChatTemplateIntegrationTests`
  - Env: `GLMOCR_TEST_MODEL_FOLDER`
  - Build prompt for `.text`, assert:
    - prefix IDs include `gMaskId`, `sopId`, `userId`
    - `<|image|>` repeated exactly `numImageTokens` for a known input size (use a synthetic CIImage preprocessed to a known H/W).
- New: `GLMOCRSingleImageEndToEndIntegrationTests`
  - Env: `GLMOCR_TEST_MODEL_FOLDER`, `GLMOCR_TEST_IMAGE_PATH`
  - Run `GLMOCRPipeline.recognize(...)` and assert output is non-empty (do not golden-text assert yet).

### 3) Update existing tests if signatures change
- Update `GreedyGenerator` calls and any conformance to updated `CausalLM` protocol.

---

## Docs updates (must stay truthful)
1. Update `docs/dev_plans/03_mvp_single_image.md`:
   - tick completed checkboxes, update status date, add a short “Known gaps” note if KV-cache is deferred.
2. If `CausalLM` / generation public API changes, update `docs/architecture.md` to reflect multimodal generation input shape.
3. If KV-cache is implemented, add a short ADR in `docs/decisions/` describing:
   - cache interface choice
   - RoPE offset handling
   - why “pixelValues only on first step” is correct for this model

---

## Acceptance checklist (what “done” means)
- `swift test` passes without env vars.
- With `GLMOCR_TEST_MODEL_FOLDER` set (and `mlx.metallib` colocated), integration tests pass.
- `swift run GLMOCRCLI --input ./some.png` prints OCR text.
- `swift run GLMOCRCLI --input ./some.pdf --page 1` prints OCR text.
- App: drop image/PDF → Run → output appears.
- Manual parity: run official MLX Python example on 3–5 images and compare outputs qualitatively (layout + key text); record notes in `docs/dev_plans/03_mvp_single_image.md`.

---

## Assumptions
- Model snapshot includes `preprocessor_config.json`; if not, fallback mean/std and resizing defaults are acceptable for MVP.
- PDFKit is available on macOS 14 (target platform).
- Performance is acceptable with Pass 1 (no KV-cache) for initial MVP; KV-cache Pass 2 is executed immediately if decode is too slow for typical OCR lengths.
