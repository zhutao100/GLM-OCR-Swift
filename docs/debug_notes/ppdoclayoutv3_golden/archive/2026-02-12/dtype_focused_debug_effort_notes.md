# Debugging PP-DocLayout-V3 golden check drift (dtype-focused notes)

This note captures a dtype-focused investigation into why **PP-DocLayout-V3 golden parity fails** while **GLM-OCR golden parity passes**.

Date: **2026-02-12**

## TL;DR

- The PP-DocLayout-V3 golden mismatch is **not explained by an obvious dtype mismatch** in the Swift pipeline.
- The Swift golden run is **already float16 end-to-end** (inputs + weights), matching the Python/Transformers MPS fixture (`torch_dtype=float16`).
- Forcing alternate dtypes (pixel values to float32, or weights to float32) **does not make the MPS/float16 fixture pass**.
- New evidence (fixture v3 intermediates): encoder-side intermediates match on CPU/float32 at sampled points, while output logits/boxes still drift → drift is very likely **inside the decoder** (multi-scale deformable attention / `grid_sample` / bbox refinement), not preprocessing/backbone/encoder.

## Reproduce

### 1) PP-DocLayout-V3 golden (Python fixture: MPS/float16)

```bash
LAYOUT_SNAPSHOT_PATH=<snapshot_path> LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenIntegrationTests
```

To print dtype summaries during the test:

```bash
LAYOUT_SNAPSHOT_PATH=<snapshot_path> LAYOUT_RUN_GOLDEN=1 LAYOUT_DEBUG_DTYPE=1 \
  swift test --filter PPDocLayoutV3GoldenIntegrationTests
```

### 2) GLM-OCR golden (passes)

```bash
GLMOCR_TEST_MODEL_FOLDER=<snapshot_path> GLMOCR_RUN_GOLDEN=1 \
  swift test --filter GLMOCRForwardPassIntegrationTests/testForwardPass_goldenSlice_matchesPython
```

## What the Python PP-DocLayout fixture actually encodes

`Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_v1.json` records (among other things):

- `metadata.device = "mps"`
- `metadata.dtype = "float16"`
- `processor.pixel_values_shape = [1, 3, 800, 800]` (NCHW)
- `processor.image_mean = [0, 0, 0]`, `processor.image_std = [1, 1, 1]`
- `encoder_topk_indices` captured from `enc_outputs_class.max(-1).values` → `topk`

The Swift golden test already uses `encoder_topk_indices` to:

- **override** Swift top-k selection (when available), and
- **map** Python query indices to the corresponding Swift queries.

So the comparisons are not “query i vs query i” accidentally; they are meant to be like-for-like at the two-stage selection boundary.

## DType experiments performed (and what they imply)

### A) Confirm the Swift dtype regime during the golden run

`LAYOUT_DEBUG_DTYPE=1` prints:

- `processed.pixelValues` dtype (post-preprocessing),
- the dtype actually fed into `forwardRawOutputs`,
- `raw.logits` / `raw.predBoxes` dtypes.

Observed:

- Default golden run uses **float16** for `pixelValues`, and produces **float16** outputs.
- Forcing `pixelValues` to float32 results in **float32** outputs, but the mismatch remains large.

This argues against the failure being caused by something simple like “Swift accidentally ran pixel_values in float32 while Python ran float16”.

### B) Force `pixel_values` to float32

Diagnostic toggle:

```bash
LAYOUT_FORCE_PIXEL_FLOAT32=1
```

Observed:

- `forward.pixelValues=float32`, `raw.logits=float32`, `raw.predBoxes=float32`
- Golden mismatch remains (same general magnitude/pattern).

Implication: the drift is not a delicate fp16 rounding edge-case that disappears when you upcast the inputs.

### C) Force weights dtype to float32

Diagnostic toggle:

```bash
LAYOUT_WEIGHTS_DTYPE=float32
```

Observed:

- `raw.logits`/`raw.predBoxes` become float32 (as expected).
- The golden mismatch remains.

Implication: the drift is not fixed by “do everything in fp32”, which is a strong hint that the port is not computing the same function as the reference.

## Conclusion on the dtype suspicion

The suspicion “MLX vs PyTorch MPS dtype behavior differences are the cause” is **unlikely to be the primary root cause**.

Reasons:

- The Swift run matches the fixture’s declared dtype (`float16`) for inputs and weights.
- Upcasting inputs and/or weights does not converge to the Python fixture.
- The mismatch magnitude (multiple logit units across many classes/queries) is too large to attribute to normal fp16 accumulation differences alone.

DType differences can still **amplify** drift, but the current evidence suggests the port is missing **semantic parity** somewhere.

## New evidence: fixture v3 “intermediate parity” localizes drift past the encoder

As of **2026-02-12**, we have an opt-in fixture that stores intermediate tensor scalar samples:
- `Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v3.json`

And an opt-in integration test that compares those samples against the Swift port:
- `Tests/DocLayoutAdapterTests/PPDocLayoutV3IntermediateParityIntegrationTests.swift`

Run:

```bash
LAYOUT_RUN_GOLDEN=1 LAYOUT_SNAPSHOT_PATH=<snapshot_path> \
  swift test --filter PPDocLayoutV3IntermediateParityIntegrationTests
```

Result:

- The parity test passes for the **pre-decoder intermediates currently captured** (up through `reference_points_unact`) with `atol=1e-3`.
- The v1 CPU/float32 golden still fails with large output drift (`PPDocLayoutV3GoldenFloat32IntegrationTests`).

Interpretation: drift is very likely inside the **decoder** (multi-scale deformable cross-attention and/or bbox refinement).

For the full “how to run + gotchas (Python in-place list mutation)”, see:
- `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`

## Most likely next place to debug: decoder deformable attention / `grid_sample`

PP-DocLayout-V3 relies heavily on:

- multi-scale deformable cross-attention, and
- `grid_sample(align_corners=false, padding_mode=zeros, mode=bilinear)`

These are notoriously boundary-sensitive; a small mismatch in:

- sampling-location math,
- flatten/reshape ordering between (H,W) and sequence,
- or the exact `grid_sample` coordinate mapping

can produce large downstream divergence.

In the HF reference, deformable attention is implemented using `torch.nn.functional.grid_sample` (even when a kernel hook exists), so parity should be achievable—but the Swift implementation must match PyTorch semantics precisely.

## Recommended next debugging steps (actionable)

1. Extend fixture v3 + Swift probes into the decoder:
   - capture `sampling_offsets`, `attention_weights`, `sampling_locations` for the first decoder layer (very small index set)
   - capture one `grid_sample` output vector slice for the same indices
2. Add a tiny standalone micro-test for `grid_sample`:
   - generate a small tensor + grid in Python and store expected output
   - compare to Swift `gridSampleBilinearNHWC`
3. Once the first decoder mismatch is found, fix that stage and re-run:
   - `PPDocLayoutV3IntermediateParityIntegrationTests`
   - `PPDocLayoutV3GoldenFloat32IntegrationTests`

## Related knobs and docs

- Parity workflow: `docs/golden_checks.md`
- DType diagnostics:
  - `LAYOUT_DEBUG_DTYPE=1`
  - `LAYOUT_FORCE_PIXEL_FLOAT32=1`
  - `LAYOUT_WEIGHTS_DTYPE=float16|float32|bfloat16`
- DType background: `docs/context/`
