# Debugging PP-DocLayout-V3 golden drift (DocLayoutAdapter)

This note is the “single place to start” for future debugging sessions around **PP-DocLayout-V3 golden check drift**.

Last updated: **2026-02-12**

See also:

- Postmortem: `docs/debug_notes/ppdoclayoutv3_golden/postmortem/swift_in_place_mutation_quirks.md`

## What’s being debugged

Swift target: `DocLayoutAdapter` (MLX Swift port of `transformers.PPDocLayoutV3ForObjectDetection`).

Opt-in tests (require `LAYOUT_RUN_GOLDEN=1`):

- `Tests/DocLayoutAdapterTests/PPDocLayoutV3GoldenIntegrationTests.swift` (fixture: MPS/float16)
- `Tests/DocLayoutAdapterTests/PPDocLayoutV3GoldenFloat32IntegrationTests.swift` (fixture: CPU/float32)
- `Tests/DocLayoutAdapterTests/PPDocLayoutV3IntermediateParityIntegrationTests.swift` (fixtures: CPU/float32 v3 + v4)

Fixtures live in `Tests/DocLayoutAdapterTests/Fixtures/`.

## Outcome (2026-02-12)

- Fixed the golden drift for snapshot `a0abee1e2bb505e5662993235af873a5d89851e3` (Transformers `5.1.0`):
  - `PPDocLayoutV3GoldenFloat32IntegrationTests` passes (CPU/float32).
  - `PPDocLayoutV3GoldenIntegrationTests` passes (MPS/float16).
- Added a decoder-focused parity fixture (`ppdoclayoutv3_forward_golden_cpu_float32_v4.json`) to localize future drift inside decoder layer 0.
- Disabled SwiftLint’s `shorthand_operator` rule and removed `MLXArray` compound assignments (`+=`, `*=`, etc.) to reduce the risk of future aliasing drift.

## Root cause (2026-02-12): in-place mutation of decoder hidden states

`MLXArray` is a reference type, and compound assignment operators like `+=` mutate the underlying array.

In `PPDocLayoutV3MultiscaleDeformableAttentionCore.forward(...)`, we did:

```swift
var hiddenStates = hiddenStates
hiddenStates += positionEmbeddings
```

That mutated the caller-owned `hiddenStates` used as the decoder layer residual, corrupting the cross-attn residual path and causing large downstream drift (decoder outputs, boxes, logits).

Fix: use out-of-place addition:

```swift
hiddenStates = hiddenStates + positionEmbeddings
```

File: `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Decoder.swift`.

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

## The intermediates workflow (v3/v4) (localize first divergence)

### Generate the fixture

```bash
export LAYOUT_SNAPSHOT_PATH="$HOME/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/snapshots/a0abee1e2bb505e5662993235af873a5d89851e3"

PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py \
  --model-folder "$LAYOUT_SNAPSHOT_PATH" \
  --device cpu \
  --include-intermediates \
  --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v3.json
```

For decoder layer-0 internal probes (fixture v4):

```bash
PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py \
  --model-folder "$LAYOUT_SNAPSHOT_PATH" \
  --device cpu \
  --include-decoder-intermediates \
  --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v4.json
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

- `PPDocLayoutV3IntermediateParityIntegrationTests` passes for:
  - fixture v3 (pre-decoder intermediates)
  - fixture v4 (decoder layer-0 intermediates)
- `PPDocLayoutV3GoldenFloat32IntegrationTests` passes.
- `PPDocLayoutV3GoldenIntegrationTests` passes.

If drift reappears, the fastest path is to re-run the v4 parity test and look for accidental in-place ops (e.g. `+=`, `*=`) on tensors that might alias caller-owned values (especially decoder residual paths).

Archived notes from the original investigation are kept under `docs/debug_notes/ppdoclayoutv3_golden/archive/2026-02-12/`.
