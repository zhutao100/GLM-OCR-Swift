Below are the highest-leverage misalignments I found by comparing your Swift port against the Hugging Face Transformers reference implementation for **PP-DocLayout-V3**, focusing on things that plausibly produce **large, systematic output drift** (well beyond the `atol=0.1` logits / `atol=0.01` boxes tolerances in your golden tests), and that are **not explained by FP16 vs FP32 precision** (your doc already tested that).

I’ll start with the most likely root cause, then list additional “next suspects” (still meaningful, but lower confidence).

---

## #1 (High confidence): **AIFI / “transformer_layers” mismatch (module structure + weight keys + semantics)**

### What the reference does

In Transformers, the HybridEncoder contains an **AIFI block list** stored under a module attribute named **`transformer_layers`**, created from `encode_proj_layers`. This is applied to selected feature levels before the main deformable encoder stack.

Also, the AIFI block itself is **not** the same as the deformable encoder layers; it uses a **standard `nn.MultiheadAttention`** + FFN + norms (TransformerEncoderLayer-like), and critically it feeds **Q and K with positional embedding added**, but uses **V without positional embedding** (because `value=src`).

### What your Swift implementation does

In your Swift port:

* `PPDocLayoutV3HybridEncoderCore` stores the AIFI blocks under the key **`encoder`**:

  ```swift
  @ModuleInfo(key: "encoder") var encoder: [PPDocLayoutV3AIFILayerCore]
  ```

* The AIFI block (`PPDocLayoutV3AIFILayerCore`) is **implemented as a list of `PPDocLayoutV3EncoderLayerCore`**:

  ```swift
  @ModuleInfo(key: "layers") var layers: [PPDocLayoutV3EncoderLayerCore]
  ```

  and runs:

  ```swift
  hiddenStates = layer.forward(hiddenStates, ..., spatialPositionEmbeddings: posEmbed)
  ```

This creates **three major divergences**:

---

### (A) **State dict key mismatch → AIFI weights likely not loaded**

The HF state dict will have weights under:

* `model.encoder.transformer_layers.0.*`

…but your Swift module tree expects:

* `model.encoder.encoder.0.layers.0.*`

So unless you have an explicit key-rewriter (I did not see one), **those weights simply won’t map**, meaning your AIFI layers are running with **random initialization**.

This would absolutely explain:

* encoder outputs drifting enough that top-K indices differ
* decoder logits/boxes being far off even in FP32

**Strong supporting evidence:** your weight validation list (`PPDocLayoutV3Weights.requiredKeys`) **does not include any `transformer_layers.*` keys**, so you wouldn’t notice missing AIFI weights during validation.

---

### (B) Even if you fixed the key path, the **AIFI layer architecture is not equivalent**

HF AIFI uses **`nn.MultiheadAttention`** with its own parameter layout (`in_proj_weight`, `in_proj_bias`, `out_proj.*`, etc). Your AIFI reuses `PPDocLayoutV3EncoderLayerCore`, whose attention is the **custom fused QKV projection attention** used elsewhere in the model.

So weights still won’t match without a custom implementation matching HF’s parameter names and shapes.

---

### (C) **Positional embedding is applied to V in Swift but not in HF AIFI**

HF AIFI builds:

* `q = k = src + pos_embed`
* `value = src`

Your Swift `PPDocLayoutV3EncoderLayerCore` passes `spatialPositionEmbeddings` into attention in a way that effectively adds the embedding **before** QKV projection, affecting Q, K **and V**.

That’s a semantic mismatch even if weights matched.

---

### Recommended fix (concrete)

1. **Rename / restructure HybridEncoder to match HF keys**

   * `@ModuleInfo(key: "transformer_layers") var transformerLayers: [...]`
   * keep the “main deformable encoder layers” under whatever HF uses (likely `encoder` / `encoder.layers`, etc).

2. Implement a Swift `PPDocLayoutV3AIFILayerCore` that matches HF exactly:

   * parameters: `self_attn.in_proj_weight`, `self_attn.in_proj_bias`, `self_attn.out_proj.*`
   * FFN: `linear1`, `linear2`
   * norms: `norm1`, `norm2`
   * attention call: Q/K use `src + pos`, V uses `src`.

3. Add **weight validation keys** for AIFI so this cannot regress silently.

> If you do only one thing first: **dump loaded parameter names for the AIFI subtree** and confirm whether any HF keys are landing there. I strongly expect they are not.

---

## #2 (Medium confidence): **Golden fixture “top-K override” hides earlier encoder drift**

Your golden harness overrides `encoderTopKIndices`:

```swift
encoderTopKIndicesOverride: fixture.encoderTopKIndices
```

That is useful to isolate decoder determinism, but it also means:

* if encoder features are wrong (e.g., due to missing AIFI weights),
* you are still taking those indices from a different distribution,
* then gathering from a mismatched encoder memory,
* and feeding decoder a *different semantic query set* than HF intended.

So even a perfect decoder port can fail golden if the encoder memory is already wrong.

**Practical implication:** once AIFI is fixed, you should expect encoder top-K to converge and the override may become unnecessary (or at least stop masking the real problem).

---

## #3 (Lower confidence, but worth checking): **Preprocessor resampling vs CoreImage**

Your Swift preprocessor uses:

* `CIFilter.bicubicScaleTransform()` to resize

The model’s HF `preprocessor_config.json` specifies `resample: 3`, which corresponds to **bicubic** as well (so you are aligned on *type* of interpolation). ✅

However, CoreImage bicubic kernels are **not guaranteed to match PIL/torchvision bicubic numerically**, and PP-DocLayout is far more sensitive than GLM-OCR.

This is a “secondary suspect” because:

* Your tolerance is fairly loose (`0.1` logits), so pure resize kernel differences *might* still pass.
* But the model is deep and can amplify small pixel diffs.

**How to test quickly (high signal):**

* In Python, generate the exact deterministic RGBA image pattern used by `makeDeterministicCIImage()`, then resize with PIL bicubic and compare against the tensor Swift produces (export Swift pixelValues).
* If the mean absolute diff per pixel is > ~1e-3, it’s worth addressing.

---

## #4 (Lower confidence): Deformable attention `grid_sample` correctness is probably *not* the root cause

Your doc focuses on `grid_sample`, and you *did* implement:

* `align_corners=False`
* bilinear weights
* zero padding
* correct normalized coord mapping: `x = ((gx + 1) * W - 1)/2`

Your Swift deformable attention core closely matches the HF logic (shape transforms, flatten ordering, level splits, etc.). So while there can be minor numeric drift, it’s **unlikely** to create the kind of systematic mismatch that fails with `atol=0.1` unless something fundamental is wrong.

Given the AIFI situation above, I would treat deformable attention as a later step—verify after encoder alignment.

---

# Summary (What’s most likely happening)

### The most plausible failure mode is:

**HybridEncoder AIFI (“transformer_layers”) weights are not being loaded at all**, because your Swift module tree and key names do not match Transformers’ state dict structure, and your weight validation doesn’t assert these keys exist. That causes encoder memory to be wrong, leading to large downstream mismatches.

---

# Next steps checklist (fastest path to confirmation)

Here’s a concrete order that maximizes signal:

1. **Print the HF safetensors keys that start with `model.encoder.transformer_layers`** (in Swift loader or via a Python script).
2. **Print the Swift parameter tree keys under `model.encoder.*`** and see if there is anywhere those could land.
3. If they don’t align: implement the key/structure fix.
4. Only then re-evaluate:

   * encoder top-K alignment
   * decoder drift
   * `grid_sample` concerns
