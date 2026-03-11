# Numerical parity & golden fixtures

This repo sometimes needs **numerical parity checks** against an external reference implementation (typically Python/Transformers) while porting models to **MLX Swift**.

These checks are intentionally:

- **opt-in** (so `swift test` stays fast and hermetic by default)
- **deterministic** (fixed inputs + small slices)
- **diagnostic** (designed to localize drift quickly)

## Core principles (portable to any model)

### 1) Make the inputs deterministic

- Use a deterministic prompt and a deterministic synthetic image (or a tiny fixed fixture file).
- Make preprocessing deterministic: explicit resize policy, explicit color space, explicit mean/std.
- Record the exact snapshot/version you used (HF snapshot hash, config summary).

### 2) Align numerics end-to-end (device + dtype)

Golden parity is only meaningful if **the reference run and Swift run use the same numerical regime**:

- **Device** (CPU vs GPU/MPS) can change kernels and accumulation order.
- **DType** (FP16 vs BF16 vs FP32) can change intermediate rounding and saturation.
- Some reference stacks force **float32** for specific blocks (common for rotary/positional math).

Guideline: when a golden fixture is produced under a given device/dtype, the Swift test should **force both weights and inputs** to the same dtype for that parity run. Casting only one side (weights *or* inputs) is a common source of “mysterious” drift.

### 3) Localize drift early (compare intermediates before logits)

When a golden check fails, avoid jumping straight to “logits mismatch”:

1. Compare **vision embeddings** (post-vision encoder or post-merger). Small drift here will amplify downstream.
2. Compare **text embeddings** (token embedding output).
3. Compare **position IDs / RoPE inputs** used by attention.
4. Only then compare logits/top-k.

Prefer summary statistics (mean/std/l2 + a few elements) over full tensors.

### 4) Treat layout/conventions as part of the model

Ports often fail due to *convention mismatches* rather than “math bugs”:

- Tensor layout (channels-first vs channels-last, patch packing order, flatten order)
- Weight layout expectations (e.g., conv kernels)
- RoPE conventions (rotate-half variant, cos/sin expansion, any model-specific indexing)
- Decoder block ordering (norm/residual placement)

Always cross-check against the **reference implementation’s code**, not just config values.

### 5) Avoid non-contiguity pitfalls in reference tooling

In Python/PyTorch, tensors coming from preprocessors or device transfers may be non-contiguous.

- Prefer `.reshape(...)` over `.view(...)` unless you know the tensor is contiguous.
- If you must use `.view(...)`, use `.contiguous()` explicitly first.

This reduces “works on CPU, fails on GPU/MPS” issues in fixture generation scripts.

### 6) Beware in-place mutation when instrumenting the Python reference

When building “intermediate parity” fixtures, be careful with Python containers passed into modules:

- some models mutate lists/dicts of tensors in-place (e.g. reassigning feature levels),
- which can silently corrupt what you think you are recording.

Example: Transformers’ `PPDocLayoutV3HybridEncoder` mutates its input features list (it reassigns `feats[level]` for `encode_proj_layers`), so fixture generators must pass a copy to keep “pre-encoder” tensors stable.

### 7) Minimize version drift in preprocessing

Hugging Face processors can change behavior across versions and “fast vs slow” implementations.

Guideline:

- Treat the image processor/tokenizer configuration as part of the golden fixture.
- Prefer recording the reference library versions and any critical processor flags (e.g. `use_fast`) in the fixture metadata or the generator output.

### 8) If the model performs internal selection, record the indices

Many detectors are effectively “two-stage”: the decoder queries are created by selecting top-scoring encoder locations.
Tiny numeric drift (device kernels, dtype promotions, half precision rounding) can change the **ordering** of that selection even when the underlying features are close.

Golden probes that assume “query i is query i” become meaningless if the query identities differ.

Guideline:

- Capture the reference selection indices (e.g. encoder `topk_ind`, kept indices after masking) in the fixture.
- In Swift, either:
  - override the selection indices during the parity run, or
  - map “python query i” → “swift query j” by matching the underlying selected encoder index.

This makes golden slices compare like-for-like, instead of accidentally comparing different objects.

### 9) Use dtype-appropriate sentinel values for masking

Masking often uses “very large” numbers so that invalid entries disappear under `min/max/topk`.
In half precision, `Float.greatestFiniteMagnitude` does **not** fit and becomes `inf`, which can turn downstream ops into `NaN` (especially if you later apply `log`, `exp`, or reduce across mixed valid/invalid values).

Guideline:

- Use dtype-aware finite maxima (e.g. `Float16.greatestFiniteMagnitude` when running FP16).
- Be deliberate about dtype promotions in comparisons (some backends compare FP16 values against FP32 scalars).

### 10) Boundary-sensitive ops can amplify tiny errors

`grid_sample(align_corners=false)` and deformable attention are highly sensitive to sampling locations near the `[0, 1]` boundary.
In FP16, rounding can push an “almost-in-bounds” coordinate slightly out of bounds, triggering zero padding and disproportionately large downstream drift.

Guideline:

- Keep the sampling-location math faithful to the reference implementation (including dtype).
- When diagnosing parity, always include at least one probe that is fully in-bounds to separate “core math mismatch” from “OOB/border effects”.
- Prefer probe indices that are stable across backends; if an index is consistently border-sensitive, replace it with a nearby index that exercises the same codepaths.

## Repo-specific switches

### Snapshot selection

- `GLMOCR_SNAPSHOT_PATH=<snapshot_path>`
  - optional override for the auto-resolved cached snapshot of `zai-org/GLM-OCR`
- `LAYOUT_SNAPSHOT_PATH=<snapshot_path>`
  - optional override for the auto-resolved cached snapshot of `PaddlePaddle/PP-DocLayoutV3_safetensors`

When these env vars are unset, model-backed tests try to resolve the current cached snapshot from the local HF hub cache via `refs/main`. If no cached snapshot exists, those tests are skipped.

### Opt-in test lanes

- `GLMOCR_RUN_GOLDEN=1`
  - enables GLM-OCR golden checks and also turns on parity-oriented dtype alignment in the runtime
- `LAYOUT_RUN_GOLDEN=1`
  - enables PP-DocLayoutV3 golden and intermediate parity checks
- `GLMOCR_RUN_EXAMPLES=1`
  - enables the end-to-end checked-in examples parity integration tests
- `GLMOCR_TEST_RUN_FORWARD_PASS=1`
  - enables the GLM-OCR smoke forward-pass integration test
- `GLMOCR_TEST_RUN_GENERATE=1`
  - enables the GLM-OCR one-token generate integration test

### Diagnostic and preprocessing toggles

- `GLMOCR_DEBUG_VISION=1`
  - prints vision embedding stats in the GLM-OCR golden test
- `GLMOCR_PREPROCESS_BACKEND=coreimage|deterministic`
  - selects the GLM image resize backend for runtime/parity debugging
- `GLMOCR_POST_RESIZE_JPEG_QUALITY=<float>`
  - applies an optional JPEG round-trip after resize in the GLM image processor
- `GLMOCR_ALIGN_VISION_DTYPE=1`
  - aligns image tensor dtype to the model vision weights dtype without enabling the full golden lane
- `LAYOUT_DEBUG_DTYPE=1`
  - prints dtype summaries during PP-DocLayoutV3 golden runs
- `LAYOUT_FORCE_PIXEL_FLOAT32=1`
  - forces PP-DocLayoutV3 `pixel_values` to `.float32`
- `LAYOUT_WEIGHTS_DTYPE=float16|float32|bfloat16`
  - overrides the PP-DocLayoutV3 weights dtype at load time

## Practical test matrix

MLX-backed SwiftPM tests now prepare the SwiftPM metallib automatically on demand. If you want to prewarm it for direct CLI/runtime experiments, you can still run:

```bash
scripts/build_mlx_metallib.sh -c debug
```

Useful lanes:

- Default deterministic/unit coverage

  ```bash
  swift test
  ```

- GLM-OCR golden slice

  ```bash
  GLMOCR_RUN_GOLDEN=1 swift test --filter GLMOCRForwardPassIntegrationTests
  ```

- GLM-OCR smoke forward pass

  ```bash
  GLMOCR_TEST_RUN_FORWARD_PASS=1 swift test --filter GLMOCRForwardPassIntegrationTests
  ```

- GLM-OCR single-token generate smoke

  ```bash
  GLMOCR_TEST_RUN_GENERATE=1 swift test --filter GLMOCRGenerateIntegrationTests
  ```

- End-to-end examples parity tests

  ```bash
  GLMOCR_RUN_EXAMPLES=1 swift test --filter LayoutExamplesParityIntegrationTests
  ```

  The current protected subset is intentionally small and low-flake: `GLM-4.5V_Page_1` (PDF) and `table` (PNG). The broader examples corpus remains report-only through `scripts/verify_example_eval.sh`.

- PP-DocLayout-V3 MPS/FP16 golden

  ```bash
  LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenIntegrationTests
  ```

- PP-DocLayout-V3 CPU/FP32 golden

  ```bash
  LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenFloat32IntegrationTests
  ```

### PP-DocLayout-V3 intermediate parity (fixture v3)

To localize drift before touching logits/boxes, generate a CPU/float32 fixture with intermediate scalar samples:

```bash
PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py \
  --model-folder "$LAYOUT_SNAPSHOT_PATH" \
  --device cpu \
  --include-intermediates \
  --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v3.json
```

Then run the opt-in intermediate parity test:

```bash
LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3IntermediateParityIntegrationTests
```

## Practical checklist (when adding or updating a golden fixture)

1. Generate the fixture from the reference stack:
   - GLM-OCR: `scripts/generate_glmocr_golden.py`
   - PP-DocLayout-V3: `scripts/generate_ppdoclayoutv3_golden.py`
2. Ensure the fixture metadata records enough to reproduce:
   - snapshot hash, prompt, preprocessing config summary
   - device + dtype (and any forced-float32 blocks); if not embedded in JSON, ensure it is printed/logged by the generator script output.
3. Run the opt-in test:
   - `GLMOCR_RUN_GOLDEN=1 swift test`
   - `LAYOUT_RUN_GOLDEN=1 swift test`
4. If it fails:
   - turn on `GLMOCR_DEBUG_VISION=1`
   - validate dtype/device alignment first
   - then validate layout + RoPE conventions
