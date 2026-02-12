# Debugging PP-DocLayout-V3 golden drift (DocLayoutAdapter)

This note is the “single place to start” for future debugging sessions around **PP-DocLayout-V3 golden check drift**.

Last updated: **2026-02-12**

## What’s being debugged

Swift target: `DocLayoutAdapter` (MLX Swift port of `transformers.PPDocLayoutV3ForObjectDetection`).

Opt-in tests (require `LAYOUT_RUN_GOLDEN=1`):

- `Tests/DocLayoutAdapterTests/PPDocLayoutV3GoldenIntegrationTests.swift` (fixture: MPS/float16)
- `Tests/DocLayoutAdapterTests/PPDocLayoutV3GoldenFloat32IntegrationTests.swift` (fixture: CPU/float32)
- `Tests/DocLayoutAdapterTests/PPDocLayoutV3IntermediateParityIntegrationTests.swift` (fixture v3 with intermediates; CPU/float32)

Fixtures live in `Tests/DocLayoutAdapterTests/Fixtures/`.

## Snapshot + fixture facts (current baseline)

For the fixtures checked in today:

- Snapshot hash: `a0abee1e2bb505e5662993235af873a5d89851e3`
- Transformers: `5.1.0`
- `config.json`:
  - `eval_size: null`
  - `encode_proj_layers: [2]`
- `model.safetensors`:
  - `model.encoder.transformer_layers.*`: **0 keys**
  - AIFI/encode-proj weights are under `model.encoder.encoder.*` (this matches the Swift module keypath)

Quick verification commands:

```bash
jq '.eval_size, .encode_proj_layers' \
  ~/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/snapshots/a0abee1e2bb505e5662993235af873a5d89851e3/config.json
```

```bash
PYENV_VERSION=venv313 pyenv exec python3 - <<'PY'
from pathlib import Path
from safetensors.torch import safe_open

weights = Path.home() / ".cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/snapshots/a0abee1e2bb505e5662993235af873a5d89851e3/model.safetensors"
with safe_open(str(weights), framework="pt", device="cpu") as f:
    keys = list(f.keys())
print("transformer_layers:", sum(k.startswith("model.encoder.transformer_layers") for k in keys))
print("encoder:", sum(k.startswith("model.encoder.encoder") for k in keys))
PY
```

## The “fixture v3 intermediates” workflow (localize first divergence)

### Generate the fixture

```bash
export LAYOUT_SNAPSHOT_PATH="$HOME/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/snapshots/a0abee1e2bb505e5662993235af873a5d89851e3"

PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py \
  --model-folder "$LAYOUT_SNAPSHOT_PATH" \
  --device cpu \
  --include-intermediates \
  --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v3.json
```

### Run the intermediate parity test

```bash
LAYOUT_RUN_GOLDEN=1 LAYOUT_SNAPSHOT_PATH="$LAYOUT_SNAPSHOT_PATH" \
  swift test --filter PPDocLayoutV3IntermediateParityIntegrationTests
```

Notes:

- The v3 fixture stores **scalar samples** only (not full tensors) under `intermediates`.
- Feature maps are sampled in **NHWC** index order: `[b, y, x, c]` (even though PyTorch internally uses NCHW for many ops).
- The parity test currently uses `atol=1e-3` for these scalars (MLX vs PyTorch CPU can differ slightly even in float32).

## Key finding (2026-02-12): the Python generator had a “false divergence” bug

The initial v3 fixture showed large mismatches at `encoder_input_proj.2`. That was **not a Swift bug**.

Root cause:

- In Transformers, `PPDocLayoutV3HybridEncoder.forward(...)` **mutates the input `feats` list in-place** by reassigning selected feature levels (notably `encode_proj_layers=[2]`).
- In the Python golden generator, we passed the `proj_feats` list directly into `model_core.encoder(...)`.
- That mutated `proj_feats`, so later we accidentally recorded **post-encoder** tensors under names like `encoder_input_proj.2`.

Fix (now implemented in `scripts/generate_ppdoclayoutv3_golden.py`):

- Call the encoder with a copy: `model_core.encoder(list(proj_feats), x4_feat)`
- Keep `proj_feats` as the stable “pre-encoder input projection outputs” for intermediate sampling.

If you add new intermediate captures around the encoder in Python, assume list mutation can happen and protect accordingly.

## Current state (what matches, what doesn’t)

As of **2026-02-12**:

- `PPDocLayoutV3IntermediateParityIntegrationTests` passes for the pre-decoder intermediates currently captured:
  - `pixel_values`
  - `backbone.feature_maps.*`
  - `encoder_input_proj_conv.*` / `encoder_input_proj.*`
  - `hybrid_encoder.feature_maps.*` / `hybrid_encoder.mask_feat`
  - `source_flatten`, `anchors`, `valid_mask`, `memory`, `output_memory`
  - `enc_outputs_class`, `enc_outputs_coord_logits`, `reference_points_unact`
- `PPDocLayoutV3GoldenFloat32IntegrationTests` still fails with large output drift (logits and boxes).

Interpretation: drift is very likely **inside the decoder** (multi-scale deformable cross-attention and/or bbox refinement), since the encoder-side inputs to the decoder now match at sampled points.

## Next recommended debug steps (decoder focus)

1. Extend fixture v3 + Swift probe to capture a handful of **decoder internals** for a tiny set of indices:
   - `sampling_offsets`, `attention_weights`, `sampling_locations` (first decoder layer; 1–3 queries; head 0; a couple levels/points)
   - one `grid_sample` result vector slice for the same `(query, head, level, point)`
2. Add a micro-test that compares `grid_sample(align_corners=false, padding_mode=zeros, mode=bilinear)` on a tiny tensor against PyTorch CPU.
3. Once the first decoder mismatch is found, fix the earliest mismatch and re-run:
   - `PPDocLayoutV3IntermediateParityIntegrationTests`
   - `PPDocLayoutV3GoldenFloat32IntegrationTests`
