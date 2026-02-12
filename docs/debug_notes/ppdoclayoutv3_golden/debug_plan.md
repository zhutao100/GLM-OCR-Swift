## PP-DocLayout-V3 Golden Drift Debug Effort Plan (toward parity)

> Status (2026-02-12): ✅ fixed. CPU/float32 + MPS/float16 golden tests pass. Root cause was an in-place mutation (`+=`) of decoder hidden states in cross-attn position embedding addition; fixture v4 was added to cover decoder layer-0 intermediates.

### Summary / Goal
Fix the Swift port so the opt-in golden tests match the Python/Transformers reference **without loosening tolerances**:
- `PPDocLayoutV3GoldenFloat32IntegrationTests` (CPU/float32 fixture) passes first (your chosen priority).
- Then `PPDocLayoutV3GoldenIntegrationTests` (MPS/float16 fixture) passes.

Primary strategy: **localize the first divergence** by extending the golden fixture to include **small, deterministic intermediate slices**, then fix the earliest mismatching stage.

For current “how to run + what we learned”, see:
- `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`

### Outcome (2026-02-12)

- Fixed golden drift by removing an accidental in-place op in `PPDocLayoutV3MultiscaleDeformableAttentionCore.forward(...)`:
  - `hiddenStates += positionEmbeddings` → `hiddenStates = hiddenStates + positionEmbeddings`
- Added a decoder-focused parity fixture (`ppdoclayoutv3_forward_golden_cpu_float32_v4.json`) + probes to localize future drift inside decoder layer 0.

---

## 0) Reconcile the two “misalignment audit” notes with the actual snapshot + fixture
Before changing code, record what’s *actually true* for the snapshot used by the fixture:
- Fixture `ppdoclayoutv3_forward_golden_v1.json` uses `transformers_version=5.1.0` and `snapshot_hash=a0abee1e2bb505e...`.
- For that snapshot, verify (and write down in a short note/log):
  - `config.json: eval_size == null` (so the “disable pos embed in eval when eval_size is set” gate exists in Transformers, but is **inactive** for this snapshot).
  - `model.safetensors`: **no** `model.encoder.transformer_layers.*` keys; AIFI weights are under `model.encoder.encoder.*`.

Outcome: treat `misalignment_audit_effort_1.md` and `misalignment_audit_effort_2.md` as **hypotheses to validate per-snapshot**, not as guaranteed current root causes. Keep their checks in mind (gating + keypaths), but do not assume they explain the current drift.

As of 2026-02-12 those snapshot facts were verified and recorded in:
- `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`

---

## 1) Establish a clean baseline (CPU/float32 first)
Run and capture failures using the same snapshot hash the fixture was generated from:
- `LAYOUT_SNAPSHOT_PATH=~/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors/snapshots/a0abee1e2bb505e5662993235af873a5d89851e3`
- `LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenFloat32IntegrationTests`

Record:
- Which `(pythonQueryIndex, classIndex)` and box component fails first.
- The observed absolute diffs magnitude for logits/boxes (rough “how bad”).

This is your “before” checkpoint.

---

## 2) Add a new “fixture v3” with intermediate slices (Python generator)
You chose “Add fixture v3 slices”, so implement this as the primary localization tool.

### 2.1 Extend `scripts/generate_ppdoclayoutv3_golden.py`
Add flags:
- `--include-intermediates` (bool)
- (optional) `--fixture-version v3` or auto-bump when intermediates included

When enabled, the script outputs extra JSON under a new top-level key:
- `intermediates: { ... }`

#### Canonical sampling strategy (decision-complete)
Use a small, stable set of sample points everywhere (avoid borders where possible):
- Spatial points (y, x): `[(0,0), (0,1), (1,0), (h//2,w//2), (h-2,w-2)]` (only include those that are valid for a given tensor’s H/W).
- Channel indices: `[0, 1, 2, 7, 15, 31]` (filter to `<C`).
- Sequence indices (s): `[0, 1, 2, 10, 49, 100, 200, S-1]` (filter to valid).

For each probed tensor, store:
- `shape` (as a list)
- `dtype` (string)
- `samples`: list of `{index: [..], value: float}` using a **canonical index order**:
  - NHWC tensors: `[b, y, x, c]`
  - NCHW tensors (Python): convert to the same canonical `[b, y, x, c]` when sampling
  - Sequence tensors: `[b, s, c]`

Also store `mean/std/min/max` in float32 for quick triage.

#### Intermediate tensors to probe (minimum set)
Probe in this exact order (so the Swift test can fail “at first mismatch”):
1. **Preprocess**
   - `pixel_values` (sample by `[b,y,x,c]` in RGB order after rescale/normalize)
2. **Backbone (HGNetV2)**
   - The 4 feature maps returned by the backbone (sample canonical NHWC indices)
3. **Encoder input proj**
   - The 3 projected feature maps (post `encoder_input_proj` BN)
4. **Hybrid encoder**
   - Each `feature_maps[level]` returned by HybridEncoder (post AIFI + FPN/PAN)
   - `mask_feat`
5. **Flattening / anchors / memory**
   - `source_flat` sample by `[b,s,c]`
   - `anchors` sample by `[b,s,4]`
   - `valid_mask` sample by `[b,s,1]`
6. **Encoder heads pre-topk**
   - `enc_outputs_class` sample by `[b,s,cls]` for a small set of `cls` (e.g., `[0,1,2,5,10, num_labels-1]`)
   - `enc_outputs_coord_logits` sample by `[b,s,4]`
7. **Decoder (next extension)**
   - Not captured yet in v3; see `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md` for recommended “decoder probe” indices to add next.

This set is designed to tell you unambiguously whether drift starts at preprocessing, backbone, hybrid encoder, flattening/anchors, or deformable attention.

### 2.1.1 Pitfall: HybridEncoder mutates the input features list (Python)
Transformers’ `PPDocLayoutV3HybridEncoder` mutates the input `feats` list in-place (it reassigns selected feature levels for `encode_proj_layers`).

If the Python generator passes `proj_feats` directly into `model_core.encoder(...)`, then later samples from `proj_feats` are **mis-labeled** (you end up recording post-encoder tensors as `encoder_input_proj.*`).

Fix (now implemented): call the encoder with a copy:
- `model_core.encoder(list(proj_feats), x4_feat)`

### 2.2 Generate the CPU/float32 v3 fixture
Command (explicit):
- `PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py --model-folder \"$LAYOUT_SNAPSHOT_PATH\" --device cpu --include-intermediates --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v3.json`

---

## 3) Add a Swift “v3 intermediate parity” test (CPU/float32)
Create a new XCTest (keep existing v1 tests unchanged) that:
- Loads `ppdoclayoutv3_forward_golden_cpu_float32_v3.json`
- Runs the same deterministic image + preprocessing
- Runs the model in float32 (weights + pixelValues float32)
- Compares intermediates **in the same order** as the fixture, failing fast with a clear message.

### 3.1 Where to implement probes in Swift (decision-complete)
Add env-gated probe capture plumbing to the runtime (not ad-hoc prints):
- Add a small internal “probe recorder” type in `DocLayoutAdapter` (implemented as `PPDocLayoutV3IntermediateProbe`) that can be passed through:
  - `PPDocLayoutV3Model.forwardRawOutputs(...)`
  - (future) decoder deformable attention forward

Rule: when probe recorder is `nil`, overhead must be near-zero.

### 3.2 Comparison tolerances (CPU/float32)
Use stage-appropriate tolerances (tight, but realistic across frameworks).

As of 2026-02-12, the intermediate parity test uses:
- scalar probes: `atol=1e-3` (MLX vs PyTorch CPU can differ by a few 1e-4 even in float32)

(If these are too strict, loosen only *after* confirming the first mismatch stage; do not blanket-loosen.)

Outcome: the test reports the **first tensor** whose sampled values diverge, giving you the exact subsystem to fix.

---

## 4) Fix workflow once the first divergence is identified (branch plan)
When the v3 test fails, you take the *earliest failing stage* and apply the corresponding fix track.

### Track A — Preprocess mismatch (if pixel_values samples differ)
Likely causes: CoreImage color management / channel interpretation.
Actions:
1. Dump raw 8-bit RGBA bytes from Swift and compare against the Python-generated deterministic image bytes.
2. If bytes differ, make deterministic image generation identical:
   - Ensure no gamma/ICC transform is applied during `CIContext.render`.
   - Consider rendering with a device RGB space consistently (and/or disable color matching).
3. Re-run v3 test until preprocess matches.

### Track B — Backbone mismatch (if first failing tensor is a backbone feature)
Likely causes (in order):
1. **MaxPool / padding semantics** in `HGNetV2EmbeddingsCore`:
   - Build a micro-check comparing the padded+pool output vs PyTorch `max_pool2d(..., ceil_mode=True)` with the same explicit right/bottom padding.
2. **Conv weight layout / grouped conv** correctness:
   - Validate that the Swift Conv2d weight transpose is correct for depthwise/grouped convs (shape-level and numeric probe).
3. **BatchNorm eval behavior**:
   - Verify running_mean/var + eps usage matches PyTorch in eval.
   - Confirm `core.train(false)` reliably puts *all* BN layers in eval mode.
Fix the first confirmed mismatch, then re-run v3.

### Track C — HybridEncoder/AIFI mismatch
Likely causes:
- Layout/reshape/flatten ordering differences (NHWC vs NCHW) during AIFI flatten and restore.
- Upsample/concat ordering in FPN/PAN stages.
Actions:
1. Add probes inside HybridEncoder:
   - Pre-AIFI level feature, post-AIFI feature, post-lateral conv, post-upsampling, post-fpn_block.
2. If the first mismatch is **nearest upsample**, replace with an implementation that matches PyTorch `interpolate(mode=\"nearest\", scale_factor=2)` exactly (including index rounding rules).
3. If mismatch is **bilinear upsample align_corners=false**, implement a reference-correct bilinear upsample (or match MLX behavior to PyTorch by explicit coordinate mapping).

### Track D — Flattening/anchors/masks mismatch
Likely causes:
- Flatten order mismatch (H/W swapped), or
- dtype/compare quirks affecting `valid_mask` and anchor masking.
Actions:
1. Probe `spatial_shapes`, `level_start_index`, and confirm they match Python exactly.
2. Verify anchor generation:
   - grid coordinate normalization
   - validity mask threshold compare dtype (you already added a dtype-aware compare; verify it matches Python by probes).
Fix whichever sub-probe diverges first.

### Track E — Deformable attention mismatch (decoder)
Likely causes:
- `grid_sample` coordinate mapping / boundary handling,
- sampling_locations math (offset normalizer axes),
- tensor transpose/reshape ordering per level/head.
Actions:
1. Add a **primitive micro-test** driven by Python-generated expected outputs:
   - Generate a small random `valueLevel` + `grid` and store expected PyTorch `grid_sample` output.
   - Compare to Swift `gridSampleBilinearNHWC`.
2. If `grid_sample` differs:
   - Adjust align_corners=false mapping
   - Validate x/y ordering
   - Validate mask application (no renormalization)
3. If `grid_sample` matches but deformable attention still diverges:
   - Probe `sampling_offsets`, `attention_weights`, `sampling_locations` for one head/query/level/point and compare.
   - Fix the first mismatch in sampling_locations broadcasting/indexing.

---

## 5) Re-validate against the existing v1 fixtures
Once v3 CPU/float32 intermediates match and the v3 test passes:
1. Run the existing v1 CPU/float32 golden test:
   - `LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenFloat32IntegrationTests`
2. Then run the MPS/float16 golden test:
   - `LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenIntegrationTests`

If CPU passes but MPS fails:
- Re-run generator for an **MPS/float16 v3** fixture (same intermediate slices) and repeat localization (expect smaller set of remaining differences).

---

## 6) Keep changes consistent + avoid over-engineering (cleanup checklist)
Before finishing:
- Consolidate duplicate probe/sampling utilities (one canonical sampler used by both test and runtime).
- Ensure probes are **env-gated** and do not affect normal inference.
- Remove any transient debug printing; keep only structured probes + tests.
- Update docs:
  - Keep `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md` updated with:
    - validated snapshot facts,
    - the earliest divergence stage found,
    - the fix applied and why it matches Transformers 5.1.0 behavior.

---

## Public API / Interface changes
None intended. All new functionality should be internal to `DocLayoutAdapter` and opt-in via tests/env flags.

---

## Acceptance criteria
- `PPDocLayoutV3GoldenFloat32IntegrationTests` passes against `ppdoclayoutv3_forward_golden_cpu_float32_v1.json`.
- `PPDocLayoutV3GoldenIntegrationTests` passes against `ppdoclayoutv3_forward_golden_v1.json`.
- New v3 intermediate parity test passes (and pinpoints drift if future regressions occur).
