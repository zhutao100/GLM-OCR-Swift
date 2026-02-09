# Phase 02 Implementation Plan — GLM-OCR model port (MLX Swift) + weights mapping + forward-pass harness

## Summary
Implement the **GLM-OCR model core in MLX Swift** (vision encoder + fusion + GLM decoder) and load the official HF snapshot weights (`model.safetensors`) so we can run a **single deterministic forward pass** that produces logits (no decode loop yet). This phase also validates tokenizer special tokens and adds opt-in golden checks against Python.

## Success criteria (must hit)
- `GLMOCRModel.load(from:)` loads `config.json`, constructs modules, and **updates all required parameters** from `model.safetensors` without shape mismatches.
- A **forward pass runs end-to-end** and returns logits with correct shape and stable numeric behavior for a fixed seed.
- Tokenizer + special-token IDs (including image tokens and `[gMASK]<sop>`) are validated against the snapshot’s `tokenizer.json` / `tokenizer_config.json`.

---

## 0) Ground truth inputs (use these as the source of truth)
Use the HF snapshot folder structure already supported by `ModelStore` (same as the downloaded snapshot on disk):
- `config.json`
- `tokenizer.json`, `tokenizer_config.json`
- `chat_template.jinja`
- `preprocessor_config.json`
- `model.safetensors` (single-file BF16 weights)

### Key constants from the current snapshot (must be validated in code)
- Text config: `hidden_size=1536`, `num_hidden_layers=16`, `num_attention_heads=16`, `num_key_value_heads=8`, `head_dim=128`, `intermediate_size=4608`, `vocab_size=59392`, `rope_theta=10000`.
- Image tokens (from `config.json` and `tokenizer.json` added tokens):
  - `<|begin_of_image|>` id `59256`
  - `<|end_of_image|>` id `59257`
  - `<|image|>` id `59280`
- ChatGLM prefix tokens (from `tokenizer.json` added tokens):
  - `[gMASK]` id `59248`
  - `<sop>` id `59250`
  - `<|system|>` id `59252`, `<|user|>` id `59253`, `<|assistant|>` id `59254`
- Vision patch embed weight shape indicates **Conv3d kernel temporal=2**: `model.visual.patch_embed.proj.weight` has shape `[1024, 3, 2, 14, 14]`.

---

## 1) Expand config + tokenizer loading (GLMOCRAdapter)
### 1.1 `GLMOCRConfig` (replace the current “few fields only” model)
Update `Sources/ModelAdapters/GLMOCR/GLMOCRConfig.swift` to decode the actual structure of `config.json`:
- `GLMOCRConfig`
  - `modelType`, `architectures`
  - `imageStartTokenId`, `imageTokenId`, `imageEndTokenId` (+ video ids stored but not used)
  - `textConfig: TextConfig`
  - `visionConfig: VisionConfig`
- `TextConfig`
  - `hiddenSize`, `numHiddenLayers`, `numAttentionHeads`, `numKeyValueHeads`, `headDim`, `intermediateSize`, `rmsNormEps`, `vocabSize`, `maxPositionEmbeddings`, `ropeParameters`
- `RopeParameters`
  - `ropeTheta` (and store the rest even if unused: `ropeType`, `partialRotaryFactor`, `mropeSection`)
- `VisionConfig`
  - `hiddenSize=1024`, `depth=24`, `numHeads=16`, `intermediateSize=4096`, `patchSize=14`, `imageSize=336`, `spatialMergeSize=2`, `temporalPatchSize=2`, `outHiddenSize=1536`, `rmsNormEps`

### 1.2 Tokenizer loader wrapper (adapter-local)
Add `Sources/ModelAdapters/GLMOCR/GLMOCRTokenizer.swift`:
- Loads tokenizer from local snapshot using `swift-transformers` tokenizer APIs (add `Tokenizers` product dependency to `GLMOCRAdapter` target).
- Provides a `SpecialTokenIDs` struct resolved from tokenizer + config:
  - `gMaskId`, `sopId`, role ids, `beginImageId`, `imageId`, `endImageId`, `eosId`, `padId`.
- Validates that config token IDs match tokenizer added-token IDs for the known tokens above.

---

## 2) Implement model modules (GLMOCRAdapter, MLXNN `Module`s)

### 2.1 File layout (keep it contained, no cross-module leakage)
Create a folder: `Sources/ModelAdapters/GLMOCR/Model/` with:
- `GLMOCRCore.swift` (top-level module wiring + forward)
- `GLMOCRLanguageModel.swift` (decoder stack)
- `GLMOCRVisionModel.swift` (patch embed + 24 blocks + downsample + merger)
- `GLMOCRFusion.swift` (replace `<|image|>` placeholder embeddings with vision embeddings)
- `GLMOCRMath.swift` (small pure helpers: split gate/up, token counting, etc.)

### 2.2 Weight-key strategy (decision-complete)
Avoid a large manual key-mapping table by **matching parameter names to the HF safetensors keys** and using MLXNN’s update mechanism:
- Implement a root `Module` with these parameter paths:
  - `lm_head.weight` via `@ModuleInfo(key: \"lm_head\") var lmHead: Linear`
  - `model.language_model.*` via `@ModuleInfo(key: \"model\") var model: InnerModel`
  - Inside `InnerModel`: `@ModuleInfo(key: \"language_model\") var languageModel: ...` and `@ModuleInfo(key: \"visual\") var visual: ...`
- This matches the observed keys like:
  - `lm_head.weight`
  - `model.language_model.embed_tokens.weight`
  - `model.visual.blocks.0.attn.qkv.weight`
- **Explicitly filter out** the optional MTP-only layer weights (`model.language_model.layers.16.*`) in Phase 02 unless/until that sub-graph is implemented.

### 2.3 Vision model (CogViT-ish stack inferred from weights)
Implement `GLMOCRVisionModel: Module` with parameter names matching weights:
- `patch_embed.proj` as `Conv3d`:
  - inChannels=3, outChannels=1024, kernel=(2,14,14), stride=(2,14,14), bias=true
  - expected input: `pixelValues` shaped `[B, 3, T, H, W]` where `T` is divisible by 2; for static images, **use `T=2` by duplicating the single frame** in Phase 03, but the Phase 02 forward harness will directly synthesize `[1,3,2,336,336]`.
- `blocks: [VisionBlock]` length 24, keys `blocks.0...blocks.23`
  - `norm1.weight`, `norm2.weight`: implement as `RMSNorm(dimensions: 1024, eps: visionConfig.rmsNormEps)`
  - `attn.qkv.{weight,bias}` and `attn.proj.{weight,bias}`:
    - qkv is a `Linear(1024 -> 3072, bias: true)` then split into q/k/v (each 1024)
    - reshape to heads=16, headDim=64
    - apply `attn.q_norm.weight` and `attn.k_norm.weight` as per-head RMSNorm on the last dim (dimensions=64)
    - attention uses `MLXFast.scaledDotProductAttention(..., mask: .none)`
  - `mlp.gate_proj`, `mlp.up_proj`, `mlp.down_proj` with biases per weights:
    - gate/up: `Linear(1024 -> 4096, bias: true)`
    - down: `Linear(4096 -> 1024, bias: true)`
    - activation: SwiGLU: `down(silu(gate(x)) * up(x))`
- `post_layernorm.weight`: `RMSNorm(1024, eps: visionConfig.rmsNormEps)`
- `downsample.{weight,bias}` as `Conv2d(1024 -> 1536, kernel: 2, stride: 2, bias: true)` to implement `spatial_merge_size=2`
- `merger.*`:
  - `proj.weight`: `Linear(1536 -> 1536, bias: false)`
  - `gate_proj/up_proj/down_proj.weight` (no bias): SwiGLU MLP with intermediate=4608
  - `post_projection_norm.{weight,bias}`: `LayerNorm(1536, eps: visionConfig.rmsNormEps)` (must use LayerNorm because bias exists)

Output of `visual(pixelValues)` must be `visionEmbeds: [B, N, 1536]`.

### 2.4 Language model (GLM decoder)
Implement `GLMOCRLanguageModel: Module` matching keys:
- `embed_tokens.weight` as `Embedding(vocabSize: 59392, dimensions: 1536)`
- `layers: [DecoderLayer]` length 16 (0–15)
  - norms (weights only): implement as `RMSNorm(1536, eps: textConfig.rmsNormEps)`:
    - `input_layernorm`
    - `post_self_attn_layernorm`
    - `post_attention_layernorm`
    - `post_mlp_layernorm`
  - self-attention:
    - `q_proj`: `Linear(1536 -> 2048, bias: false)` (16 heads × 128)
    - `k_proj`, `v_proj`: `Linear(1536 -> 1024, bias: false)` (8 kv heads × 128)
    - `o_proj`: `Linear(2048 -> 1536, bias: false)`
    - apply `RoPE(dimensions: 128, base: ropeTheta=10000, traditional: false)` to q and k
    - attention mask: `.causal`
  - MLP:
    - `gate_up_proj`: `Linear(1536 -> 9216, bias: false)` then split into gate/up (each 4608)
    - `down_proj`: `Linear(4608 -> 1536, bias: false)`
    - `down(silu(gate) * up)`
  - layer order (fixed in this plan; implement exactly):
    1) `x = x + selfAttn(input_layernorm(x))`
    2) `x = post_self_attn_layernorm(x)`
    3) `x = x + mlp(post_attention_layernorm(x))`
    4) `x = post_mlp_layernorm(x)`
- final `norm.weight` as `RMSNorm(1536, eps: textConfig.rmsNormEps)`

### 2.5 Fusion (multimodal embedding replacement)
Implement `GLMOCRFusion.replaceImagePlaceholders(...)`:
- Inputs:
  - `inputIds: [B, S]`
  - `textEmbeds: [B, S, 1536]`
  - `visionEmbeds: [B, N, 1536]`
  - `imageTokenId` (59280)
- For each batch row:
  - find indices where `inputIds == imageTokenId`
  - require `count == N`; else throw a typed error (include both counts)
  - replace `textEmbeds[b, idx[i], :] = visionEmbeds[b, i, :]`

---

## 3) Weight loading (VLMRuntimeKit + GLMOCRAdapter)

### 3.1 Implement `VLMRuntimeKit/Weights`
Update `Sources/VLMRuntimeKit/Weights/Weights.swift` to:
- Enumerate `.safetensors` under a folder OR load a specific file.
- Use `MLX.loadArrays(url:)` to load tensors.
- Support:
  - `filterKeys: (String) -> Bool` (used to drop `layers.16.*` for now)
  - optional `dtype` cast (default: keep file dtype BF16)
- Provide a helper `apply(to module: Module, weights: [String: MLXArray], verify: .none/.all)` using `ModuleParameters.unflattened` + `module.update(...)`.

### 3.2 Implement `GLMOCRModel.load(from:)`
Update `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift` to:
- Load `GLMOCRConfig`
- Build `GLMOCRCoreModule` (the `Module` graph)
- Load weights from `model.safetensors` and apply:
  - filter: exclude `model.language_model.layers.16.` (MTP) until explicitly implemented
- Call `checkedEval(module)` after update
- Store:
  - `config`
  - `tokenizer` (loaded lazily or eagerly; decide eagerly for Phase 02 validation)
  - `module`

---

## 4) Forward-pass harness (developer-facing, deterministic)
Add a “smoke forward” path to prove the port works without implementing decoding:

### 4.1 API
In `GLMOCRModel`, add:
- `func forward(inputIds: MLXArray, pixelValues: MLXArray?) throws -> MLXArray`
  - returns logits as `[B, S, vocab]` (or `[B, vocab]` for last token; pick `[B, S, vocab]` for correctness and slice in the harness)

### 4.2 CLI entry (minimal surface)
Update `Sources/GLMOCRCLI/GLMOCRCLI.swift`:
- Add flag `--dev-forward-pass` (documented as developer-only).
- When set:
  - ensure model is loaded
  - build deterministic synthetic inputs:
    - `pixelValues`: random BF16 with shape `[1, 3, 2, 336, 336]` using a fixed seed
    - `visionTokenCount`: compute from vision grid after patch+downsample (for 336: `24x24` patches → downsample → `12x12=144`; temporal after stride 2 is `1`, so `N=144`)
    - `inputIds`: `[gMASK, sop, user, begin_image] + [imageId] * 144 + [end_image] + tokenizer.encode(\" OCR:\", addSpecialTokens:false)`
  - run `forward`, print:
    - logits shape
    - top-5 token IDs for last position (no decode correctness requirement yet)

---

## 5) Tests (must keep `swift test` clean by default)

### 5.1 Add `GLMOCRAdapterTests` target
Update `Package.swift` to add a new test target:
- `GLMOCRAdapterTests` depends on `GLMOCRAdapter` (+ `VLMRuntimeKit` as needed).

### 5.2 Default-running unit tests (no giant weights)
Add tests that do not require a downloaded model:
- `GLMOCRConfigDecodingTests`: decode a small embedded JSON fixture (checked into the repo) that matches the fields we use.
- `GLMOCRTokenIDTests`: parse a small embedded tokenizer fixture OR test logic that compares config IDs to tokenizer IDs when tokenizer fixture is present.

### 5.3 Opt-in golden checks (skipped unless explicitly enabled)
Add an opt-in integration test:
- If env var `GLMOCR_RUN_GOLDEN=1` and the snapshot folder exists:
  - load the local snapshot (no download)
  - run the deterministic forward pass
  - assert logits shape and a small numeric slice against golden data.

Add `scripts/generate_glmocr_golden.py` (manual workflow, not run by CI):
- Uses Python + `transformers` to:
  - load the same snapshot weights
  - run the same `input_ids` and `pixel_values` (with saved seed / explicit arrays)
  - write out a compact golden artifact (e.g., `tests/fixtures/glmocr_forward_logits_slice.json` with float32 values)

---

## 6) Documentation/consistency updates (in-phase hygiene)
- Update `docs/GLM-OCR_model.md` to match the snapshot truth (token IDs and `head_dim=128`), so Phase 03 work doesn’t build on incorrect numbers.
- Add a short note to `docs/dev_plans/02_model_port.md` describing:
  - MTP weights (`layers.16.*`) are present and filtered in Phase 02 unless implemented.

---

## Explicit assumptions / defaults (locked for implementation)
- Use **zai-org/GLM-OCR** snapshot weights (`model.safetensors`, BF16) as the baseline.
- Implement image path only; video tokens exist but are ignored.
- Skip MTP auxiliary layer (`model.language_model.layers.16.*`) in Phase 02 by filtering weights unless/until explicitly implemented.
- Standardize vision tensor shape for the model core as **NCDHW** (`[B, 3, T, H, W]`) because patch embedding is Conv3d with temporal kernel 2. Phase 03 can adapt VisionIO output into this shape.
- Keep all new model code inside `Sources/ModelAdapters/GLMOCR/` to preserve module boundaries.

---

## Acceptance runbook (what an implementer runs to verify)
1. `swift test` (must pass; golden test is skipped by default)
2. `swift run GLMOCRCLI --download-only` (ensures snapshot exists)
3. `swift run GLMOCRCLI --dev-forward-pass` (prints logits shape + top-k ids)
4. (Optional) `GLMOCR_RUN_GOLDEN=1 swift test` after generating fixtures via `scripts/generate_glmocr_golden.py`
