# Debugging PP-DocLayout-V3 golden check drift (dtype-focused notes)

This note captures a dtype-focused investigation into why **PP-DocLayout-V3 golden parity fails** while **GLM-OCR golden parity passes**.

Date: **2026-02-12**

## TL;DR

- The PP-DocLayout-V3 golden mismatch is **not explained by an obvious dtype mismatch** in the Swift pipeline.
- The Swift golden run is **already float16 end-to-end** (inputs + weights), matching the Python/Transformers MPS fixture (`torch_dtype=float16`).
- Forcing alternate dtypes (pixel values to float32, or weights to float32) **does not make the MPS/float16 fixture pass**.
- The remaining evidence points to a **semantic parity gap** (most likely in **multi-scale deformable attention / `grid_sample`**) rather than “MLX vs PyTorch MPS dtype quirks” being the root cause.

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

## Most likely next place to debug: deformable attention / `grid_sample`

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

1. Add “intermediate probes” to localize drift early:
   - backbone feature maps (per-level mean/std + a tiny slice)
   - anchors + valid masks
   - encoder `enc_outputs_class` max scores and top-k indices
   - sampling locations + a few sampled values before/after `grid_sample`
2. Compare a single level/one query/one head end-to-end:
   - choose indices that are comfortably in-bounds (avoid `[0,1]` borders)
   - verify `align_corners=false` math by hand on a few coordinates
3. Use GLM-OCR’s approach as a template:
   - the passing golden check has a “print stats when env var is set” workflow; add an analogous switch for PP-DocLayout-V3 intermediate tensors.

## Related knobs and docs

- Parity workflow: `docs/golden_checks.md`
- DType diagnostics:
  - `LAYOUT_DEBUG_DTYPE=1`
  - `LAYOUT_FORCE_PIXEL_FLOAT32=1`
  - `LAYOUT_WEIGHTS_DTYPE=float16|float32|bfloat16`
- DType background: `docs/context/`
