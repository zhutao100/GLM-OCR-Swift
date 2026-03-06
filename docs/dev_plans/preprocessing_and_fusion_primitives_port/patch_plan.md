Below is a **surgical, file-by-file patch plan** for `GLM-OCR-Swift`.

Tracking / phase status: `docs/dev_plans/preprocessing_and_fusion_primitives_port/tracker.md`.

Conventions used here:

- Each “Commit N” is treated as a phase (verify with `swift test`, then commit).
- New “parity knobs” are **opt-in** (via options/env vars) so default behavior stays unchanged unless explicitly enabled.

This plan:

1. ports `glm-ocr.swift`’s **deterministic preprocessing modes** into `VLMRuntimeKit/VisionIO` + `GLMOCRImageProcessor` (behind toggles),
2. replaces fusion with a **vectorized** implementation, and
3. adds a **minimal chat-template conformance harness**.

I’m framing this as **4 small commits** so you can bisect regressions cleanly.

---

# Commit 1 — VisionIO: deterministic raster path + JPEG round-trip + RGB→tensor

### Goal

Add **model-agnostic** primitives to `VLMRuntimeKit/VisionIO` so adapters can choose:

* current CoreImage resize pipeline (existing),
* or **deterministic CPU bicubic** resize (ported from `glm-ocr.swift`),
* plus optional **post-resize JPEG round-trip**.

### New files (VLMRuntimeKit)

**(new)** `Sources/VLMRuntimeKit/VisionIO/VisionRaster.swift`

* Add lightweight raster containers:

  ```swift
  public struct RGBA8Image: Sendable { public let data: Data; public let width: Int; public let height: Int }
  public struct RGB8Image: Sendable  { public let data: Data; public let width: Int; public let height: Int }
  ```
* Add a rasterizer to turn `CIImage` → `RGBA8Image` deterministically:

  * Uses `CIContext.render(... format: .RGBA8, colorSpace: sRGB)` (same approach as current `ImageTensorConverter`).

**(new)** `Sources/VLMRuntimeKit/VisionIO/VisionResizeBicubic.swift`

* Port these from `glm-ocr.swift/Sources/GLMOCR/GLMOCRImageProcessor.swift`:

  * `ResizeCoeff`, `buildResizeCoeffs`, `resizeBicubicRGB(...)`
* Keep the API minimal and model-agnostic:

  ```swift
  public enum VisionResizeError: Error, Sendable { case invalidDimensions; case invalidBufferSize }
  public enum VisionResize {
      public static func bicubicRGB(from rgba: RGBA8Image, toWidth: Int, toHeight: Int) throws -> RGB8Image
  }
  ```
* Parallelization heuristic can be retained (it’s in the source you’re porting).

**(new)** `Sources/VLMRuntimeKit/VisionIO/VisionJPEG.swift`

* Port `jpegRoundTripRGB(...)` and helpers from `glm-ocr.swift`:

  * `rgbToRGBA`, `rgbaToRGB`, `makeRGBAImage`, `encodeJPEGData`
* Public API:

  ```swift
  public enum VisionJPEGError: Error, Sendable { case invalidInput; case encodeFailed; case decodeFailed }
  public enum VisionJPEG {
      public static func roundTrip(_ rgb: RGB8Image, quality: Double) throws -> RGB8Image
  }
  ```

### Modify existing file

**(modify)** `Sources/VLMRuntimeKit/VisionIO/VisionIO.swift`

* Keep existing `VisionIO` API intact.
* Add small “bridge” helpers via `extension VisionIO` if you prefer the namespacing:

  * `VisionIO.renderRGBA8(_:)`
  * (or keep them as `VisionRaster`, `VisionResize`, `VisionJPEG`—either is fine; pick one style and stick to it)

**(modify)** `Sources/VLMRuntimeKit/VisionIO/VisionIO.swift` (ImageTensorConverter section)

* Add an overload to convert **RGB bytes** to `[1,H,W,3]` tensor:

  ```swift
  public static func toTensor(_ rgb: RGB8Image, options: ImageTensorConversionOptions = .init()) throws -> ImageTensor
  ```

  Implementation mirrors the existing `CIImage` path:

  * `MLXArray(rgb.data, [h,w,3], type: UInt8.self) → float32`
  * `/ 255.0`
  * optional `(x - mean) / std`
  * cast to `options.dtype`
  * reshape to `[1,h,w,3]`

### Acceptance criteria

* No adapter code changed yet; everything builds.
* (Optional) Add **unit tests** under `VLMRuntimeKitTests` for:

  * `renderRGBA8` shape correctness,
  * bicubic resize output length checks,
  * JPEG round-trip sanity (`output.data.count == width*height*3`).

---

# Commit 2 — GLMOCRImageProcessor: add preprocessing backends + parity toggles

### Goal

Keep current fast path as default, but allow:

* deterministic CPU resize,
* optional post-resize JPEG round-trip,
* dtype alignment to the model’s vision conv weights.

### Modify adapter options

**(modify)** `Sources/ModelAdapters/GLMOCR/GLMOCRImageProcessor.swift`

Add a backend enum + new option fields:

```swift
public enum GLMOCRResizeBackend: Sendable {
    case coreImageBicubic
    case deterministicBicubicCPU
}

public struct GLMOCRImageProcessingOptions: Sendable {
    ...
    public var resizeBackend: GLMOCRResizeBackend
    public var postResizeJPEGRoundTripQuality: Double?   // nil = disabled
    public var alignDTypeToVisionWeights: Bool           // default false; enable for parity/golden runs
}
```

Default:

* `resizeBackend = .coreImageBicubic`
* `postResizeJPEGRoundTripQuality = nil`
* `alignDTypeToVisionWeights = false` (recommended to enable for parity/golden runs)

### Update `process(_:config:)` to branch

**(modify)** `GLMOCRImageProcessor.process(_ image: CIImage, config: GLMOCRConfig)`

Keep `smartResize(...)` and token budgeting exactly as-is. Only change the “resize → tensor” segment:

* **Path A (current behavior):**

  * `resizeDirectly(CIImage, width, height)`
  * `ImageTensorConverter.toTensor(resizedCIImage, options: ...)`

* **Path B (deterministic + optional JPEG):**

  * `let rgba = try VisionRaster.renderRGBA8(image)` (or `VisionIO.renderRGBA8`)
  * `let resizedRGB = try VisionResize.bicubicRGB(from: rgba, toWidth: targetWidth, toHeight: targetHeight)`
  * `if let q { resizedRGB = try VisionJPEG.roundTrip(resizedRGB, quality: q) }`
  * `let imageTensor = try ImageTensorConverter.toTensor(resizedRGB, options: ...)`

Then proceed with the existing stacking to `[1,D,H,W,C]`.

### Ensure dtype alignment is actually wired

Right now the pipeline never sets `imageOptions.dtype`, so it defaults to `.bfloat16`. For parity runs, you typically want `pixelValues.dtype == visionWeight.dtype`.

To align dtype, you need one tiny “query hook”:

**(modify)** `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`

* Add:

  ```swift
  public var visionInputDType: DType {
      state.core.model.visual.patchEmbed.proj.weight.dtype
  }
  ```

**(modify)** `Sources/ModelAdapters/GLMOCR/GLMOCRPipeline.swift`

* When creating `imageOptions` (inside `Task.detached`), set:

  ```swift
  if imageOptions.alignDTypeToVisionWeights {
      imageOptions.dtype = model.visionInputDType
  }
  ```
* Add optional **parity env toggles** (easy to enable without API churn):

  * `GLMOCR_PREPROCESS_BACKEND=deterministic` → sets `resizeBackend = .deterministicBicubicCPU`
  * `GLMOCR_POST_RESIZE_JPEG_QUALITY=0.95` → sets `postResizeJPEGRoundTripQuality`
  * `GLMOCR_ALIGN_VISION_DTYPE=1` → sets `alignDTypeToVisionWeights = true` (and thus sets `imageOptions.dtype = model.visionInputDType`)
  * `GLMOCR_RUN_GOLDEN=1` → also enables dtype alignment in the pipeline (parity default)
  * Keep parsing conservative (invalid values: ignore or throw in CLI only).

### Acceptance criteria

* Default behavior unchanged unless toggles/options enabled.
* Deterministic path produces correct shapes and token counts.
* (Optional) Add an adapter test that ensures deterministic mode doesn’t crash and yields identical `numImageTokens` as the fast path for a known image size.

---

# Commit 3 — GLMOCRFusion: swap to vectorized replacement (batched-safe)

### Goal

Replace the slow per-token mutation loop with a vectorized gather/where approach (ported from `glm-ocr.swift`, but adapted to `[B,N,H]`).

### Modify fusion implementation

**(modify)** `Sources/ModelAdapters/GLMOCR/Model/GLMOCRFusion.swift`

Replace the body of `fuse(...)` with:

1. Compute mask: `[B,S] bool`

```swift
let mask = (inputIds .== MLXArray(imageTokenId))
```

2. Validate counts per batch row (host-side check is fine; B is tiny)

```swift
let counts = mask.asType(.int32).sum(axis: 1).asArray(Int32.self).map(Int.init)
guard counts.allSatisfy({ $0 == visionEmbeddings.dim(1) }) else { throw ... }
```

3. Build per-row indices via cumsum over **axis 1**:

```swift
let featureIndex = cumsum(mask.asType(.int32), axis: 1) - MLXArray(Int32(1))  // [B,S]
let safeIndex = which(mask, featureIndex, zeros([batch, seqLen], dtype: .int32))
```

4. Flatten + add batch offsets to gather from flattened vision embeddings:

```swift
let n = visionEmbeddings.dim(1)
let hidden = textEmbeddings.dim(2)

let offsets = (MLXArray(Array(0..<batch)).asType(.int32).reshaped(batch, 1) * MLXArray(Int32(n)))
let flatIndex = (safeIndex + offsets).reshaped(batch * seqLen)

let flatVision = visionEmbeddings.reshaped(batch * n, hidden)
let gathered = flatVision[flatIndex]                      // [B*S, H]

let flatText = textEmbeddings.reshaped(batch * seqLen, hidden)
let outFlat = which(mask.reshaped(batch * seqLen, 1), gathered, flatText)
return outFlat.reshaped(batch, seqLen, hidden)
```

### Add regression tests

**(new)** `Tests/GLMOCRAdapterTests/GLMOCRFusionVectorizedTests.swift`

* Build tiny deterministic arrays:

  * `inputIds`: shape `[2, 6]` with known `<|image|>` positions
  * `textEmbeddings`: `[2,6,4]` with increasing values
  * `visionEmbeddings`: `[2,3,4]` with distinct values per batch
* Validate:

  * Vectorized == old “naive” reference (implement naive in test only)
  * Throws on mismatch counts.

### Acceptance criteria

* Fusion no longer does per-position mutation.
* Tests cover multi-batch correctness (even if production mostly uses B=1).

---

# Commit 4 — Chat template conformance harness (minimal, no Jinja engine)

### Goal

Catch accidental drift in `GLMOCRChatTemplate.buildInputIDs(...)` by verifying it matches the tokenizer’s **string encoding** of the intended template.

This avoids implementing a full Jinja interpreter while still giving you a strong invariant:

> “If I render the intended template string with special tokens literally present, does the tokenizer produce the same IDs as our manual ID construction?”

### New test

**(new)** `Tests/GLMOCRAdapterTests/GLMOCRChatTemplateConformanceTests.swift`

Test structure:

1. Load snapshot tokenizer/config via existing `GLMOCRTestEnv.modelFolderURL`.
2. Compute `numImageTokens` (same as existing integration test).
3. Get prompt from `GLMOCRProcessor().makePrompt(for: .text)`.
4. Build IDs via `GLMOCRChatTemplate.buildInputIDs(...)`.
5. Build **reference template string** (single-turn case) and encode it:

Reference string:

```text
[gMASK]<sop>\n
<|user|>\n
{prefix}<|begin_of_image|><|image|>...<|end_of_image|>{suffix}\n
/nothink\n
<|assistant|>\n
```

Implementation details:

* Use `PromptTemplate(imagePlaceholder: "<image>").splitByImagePlaceholder(prompt)` to get `{prefix, suffix}`.
* Build `imageTokens = String(repeating: "<|image|>", count: numImageTokens)`.
* Encode:

  ```swift
  let expected = tokenizer.tokenizer.encode(text: rendered, addSpecialTokens: false)
  XCTAssertEqual(expected, inputIdsFromBuilder)
  ```

### Optional “snapshot sanity” (nice-to-have, still minimal)

In the same test file, add a second test that *only* checks presence of key markers if the snapshot contains the file:

* If `<snapshot>/chat_template.jinja` exists:

  * assert it contains `"[gMASK]"`, `"<sop>"`, `"<|user|>"`, `"<|assistant|>"`, and either `"/nothink"` or `"enable_thinking"`.

This doesn’t prove full conformance, but it detects “wrong snapshot / wrong family” failures early.

### Acceptance criteria

* The new test passes when a GLM-OCR snapshot is available locally (auto-resolved from HF cache; override via `GLMOCR_SNAPSHOT_PATH`).
* If chat-template logic changes, this test fails with a crisp diff in token IDs.

---

# Summary of the patch surface

### New (VLMRuntimeKit)

* `VisionRaster.swift`
* `VisionResizeBicubic.swift`
* `VisionJPEG.swift`

### Modified (VLMRuntimeKit)

* `VisionIO.swift` (add RGB→tensor overload; optionally add render helper)

### Modified (GLMOCRAdapter)

* `GLMOCRImageProcessor.swift` (backend enum + deterministic path)
* `GLMOCRModel.swift` (expose `visionInputDType`)
* `GLMOCRPipeline.swift` (wire dtype alignment + env toggles)

### Modified (GLMOCRAdapter / Model)

* `GLMOCRFusion.swift` (vectorized implementation)

### New tests (GLMOCRAdapterTests)

* `GLMOCRFusionVectorizedTests.swift`
* `GLMOCRChatTemplateConformanceTests.swift`

---

If you want, I can also add a **tiny CLI surface** in `GLMOCRCLI` to expose:

* `--preprocess-backend coreimage|deterministic`
* `--post-resize-jpeg-quality 0.0...1.0`
  without relying on env vars. This is a clean follow-up commit once the core patches land.
