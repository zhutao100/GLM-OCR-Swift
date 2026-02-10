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

### 6) Minimize version drift in preprocessing

Hugging Face processors can change behavior across versions and “fast vs slow” implementations.

Guideline:

- Treat the image processor/tokenizer configuration as part of the golden fixture.
- Prefer recording the reference library versions and any critical processor flags (e.g. `use_fast`) in the fixture metadata or the generator output.

## Repo-specific switches (parity workflow)

- `GLMOCR_TEST_MODEL_FOLDER=<snapshot_path>` points tests at a local HF snapshot.
- `GLMOCR_RUN_GOLDEN=1` enables opt-in golden checks (and may enable “parity mode” numeric settings).
- `GLMOCR_DEBUG_VISION=1` prints vision embedding stats in the forward-pass golden test to help localize drift.

## Practical checklist (when adding or updating a golden fixture)

1. Generate the fixture from the reference stack (`scripts/generate_glmocr_golden.py`).
2. Ensure the fixture metadata records enough to reproduce:
   - snapshot hash, prompt, preprocessing config summary
   - device + dtype (and any forced-float32 blocks); if not embedded in JSON, ensure it is printed/logged by the generator script output.
3. Run the opt-in test:
   - `GLMOCR_TEST_MODEL_FOLDER=<snapshot> GLMOCR_RUN_GOLDEN=1 swift test`
4. If it fails:
   - turn on `GLMOCR_DEBUG_VISION=1`
   - validate dtype/device alignment first
   - then validate layout + RoPE conventions
