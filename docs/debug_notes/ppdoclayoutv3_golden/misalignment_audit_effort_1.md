# PP-DocLayout-V3 misalignment audit (effort 1)

This note is a **hypothesis list** produced by comparing the Swift port against the Hugging Face Transformers reference.

Important: many items are **snapshot-dependent**. Validate against the actual HF snapshot used by the golden fixtures before implementing a fix.

For the current verified snapshot facts + reproduction commands, see:
- `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`

---

Below are the **PP-DocLayout-V3 pipeline misalignments** worth checking, focusing on differences that can plausibly produce **large** output drift (far beyond the tolerances used by your golden test).

---

## 1) Hypothesis: AIFI positional embeddings should be **disabled** in eval when `eval_size` is set

### What the reference does (Transformers)

In the reference **AIFI layer** (the “attention in image features” transformer encoder applied inside the HybridEncoder), **spatial positional embeddings are *disabled* during eval when `eval_size` is set**:

* If `self.training` **OR** `self.eval_size is None` → compute `pos_embed`
* Else (eval mode **and** `eval_size != None`) → `pos_embed = None`

This is in `modeling_pp_doclayout_v3.py` around:

```py
if self.training or self.eval_size is None:
    pos_embed = self.position_embedding(...)
else:
    pos_embed = None
```

### What your Swift does

Your Swift AIFI layer **always computes and injects** spatial positional embeddings:

* `Sources/ModelAdapters/DocLayout/PPDocLayoutV3HybridEncoder.swift`
* `PPDocLayoutV3AIFILayerCore.callAsFunction` (lines ~207–212 in your repo view)

```swift
let posEmbed = positionEmbedding(width: width, height: height, dtype: hiddenStates.dtype)
for layer in layers {
  x = layer(x, attentionMask: nil, positionEmbeddings: posEmbed)
}
```

### Why this can blow up the golden check

If a snapshot’s `config.json` has `eval_size != null`, then in the reference **positional embeddings are omitted in eval**, but a Swift port that always injects them will drift.

Because AIFI is applied to `encode_proj_layers = [2]` (so it *does* run), this single mismatch can cascade through:

1. encoder-transformed feature map (level 2)
2. FPN top-down fusion
3. decoder cross-attn and bbox head

Result: **logits/boxes can drift a lot**, not just minor interpolation noise.

### Fix direction

Implement the same gating:

* If you can access a module training flag (some frameworks expose it), do the exact condition:

  * `if isTraining || modelConfig.evalSize == nil { compute pos } else { nil }`

* If Swift/MLX doesn’t expose training state cleanly in custom modules, the pragmatic inference-aligned option is:

  * **If `evalSize != nil`, pass `nil` positional embeddings** (matching reference inference behavior)

This is the single highest-leverage change I see for getting the golden test to pass.

### Snapshot note (2026-02-12)

For the snapshot hash used by the checked-in golden fixtures (`a0abee…`), `config.json` has:
- `eval_size: null`

So the reference **does compute** positional embeddings in eval for that snapshot, and this hypothesis is **not expected to explain** the current golden drift.

---

## 2) Confirmed: “use_lab” is **Learnable Affine Block**, not color LAB conversion

You had a good instinct to suspect “LAB”, but in Transformers HGNetV2, `use_lab` refers to a **learnable affine block** applied after activation, not RGB→Lab colorspace conversion. The official `HGNetV2ConvLayer` uses a `HGNetV2LearnableAffineBlock` when enabled. ([GitHub][1])

This is mostly good news: your Swift HGNetV2 path *does* implement the affine block conceptually (your `HGNetV2LearnableAffineBlockCore`).

---

## 3) Medium-confidence secondary issues worth auditing (after #1)

These are “could cause drift” items. If #1 applies for your snapshot (i.e. `eval_size != null`), fix it first; otherwise skip to the items below.

### 3.1 HGNetV2 MaxPool `ceil_mode=True` vs MLX default

Transformers HGNetV2 embeddings uses:

```py
nn.MaxPool2d(kernel_size=2, stride=1, ceil_mode=True)
```

and performs explicit right/bottom padding before pooling. ([GitHub][1])

Your Swift uses `MaxPool2d(kernelSize: 2, stride: 1)` without an explicit ceil_mode control.

* For **k=2, s=1**, ceil_mode usually doesn’t change output size (often still `H-1`), so this may be benign.
* But if MLX’s pooling boundary handling differs slightly, it can introduce small feature drift early.

**Audit suggestion:** add a micro-test that compares a single pooling op on a known tensor vs PyTorch CPU (or a precomputed fixture), to confirm exact boundary semantics.

### 3.2 Interpolation semantics: MLX Upsample vs PyTorch `F.interpolate`

Your HybridEncoder uses:

* nearest upsample for top-down FPN fusion
* bilinear upsample (align_corners=false) in the mask feature head

That matches the *mode* choices in reference, but subtle numeric differences can exist between implementations.

This usually yields **small** drift, not huge. Still worth checking if #1 doesn’t fully resolve it.

### 3.3 Deformable attention grid_sample alignment

Your custom `gridSampleBilinearNHWC` is clearly intended to mimic `torch.nn.functional.grid_sample(..., align_corners=False, padding_mode="zeros")`.

The common “gotchas” to double-check (you mostly look correct already):

* coordinate mapping for `align_corners=False` (half-pixel offset)
* x/y ordering (grid[...,0] is x, grid[...,1] is y)
* out-of-bound weighting (border samples at exactly -1 or +1 should contribute ~0.5 in align_corners=False cases)

This tends to produce moderate drift if wrong, but your implementation looks directionally consistent.

---

## Recommended next step (fastest path to isolate)

1. Use the fixture v3 intermediate parity workflow to localize the first real divergence:
   - `PPDocLayoutV3IntermediateParityIntegrationTests` (pre-decoder intermediates)
2. If encoder-side intermediates match but logits/boxes drift:
   - move the probes into the decoder (`sampling_locations` / `grid_sample`), then fix the first mismatch.
3. If intermediates diverge earlier:

   - fix the earliest failing stage (preprocess → backbone → hybrid encoder → flatten/anchors).

[1]: https://raw.githubusercontent.com/huggingface/transformers/v5.1.0/src/transformers/models/hgnet_v2/modeling_hgnet_v2.py "raw.githubusercontent.com"
