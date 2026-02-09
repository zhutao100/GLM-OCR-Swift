Below is a technical walkthrough of **GLM-OCR** based on:

* the **model repo** snapshot from Hugging Face
* the **reference SDK / tooling** repo snapshot from GitHub


## 1) Model at a glance

GLM-OCR is described as a **~0.9B-parameter** multimodal OCR model built on a **GLM-V encoder–decoder** design, combining:

* a **CogViT** visual encoder,
* a lightweight **cross-modal connector** with **token downsampling**, and
* a **GLM-0.5B** language model backbone,
* plus training features including **Multi-Token Prediction (MTP)**. ([Hugging Face][1])

On the inference side, the official OCR “system” is a **two-stage pipeline**:

1. optional **layout analysis** (document structure detection), then
2. **parallel OCR** on cropped regions. ([Hugging Face][1])

---

## 2) Concrete architecture from `config.json`

The model type is `glm_ocr`, with architecture `GlmOcrForConditionalGeneration` (Transformers-native class, not “trust_remote_code”).

### 2.1 Text backbone (`text_config`): GLM decoder (~0.5B class)

Key hyperparameters:

* **Decoder layers:** 16
* **Hidden size:** 1536
* **FFN intermediate:** 4608
* **Attention heads:** 16
* **KV heads:** 8  → **Grouped-Query Attention (GQA)**
* **Head dim:** 96
* **Max positions:** 131072 (128K-ish context)
* **Activation:** SiLU
* **Norm:** RMSNorm (`rms_norm_eps = 1e-5`)
* **Dropouts:** attention=0.0, general=0.0
* **Tie embeddings:** `false` (so output head is separate from input embeddings)

Special decoder features:

* `num_nextn_predict_layers = 1` → a **single MTP auxiliary prediction layer** exists in the checkpoint config (more on this below).

This is “ChatGLM-family flavored” prompting: the provided chat template prepends **`[gMASK]<sop>`**, and uses role tokens like `<|user|>`, `<|assistant|>`, etc.

### 2.2 Vision backbone (`vision_config`): CogViT-like ViT

Key hyperparameters:

* **Depth:** 24
* **Hidden size:** 1024
* **Heads:** 16
* **MLP intermediate:** 4096
* **Patch size:** 14
* **Base image size:** 336 (i.e., 24×24 patch grid at the “base” resolution)
* **Spatial merge size:** 2  → explicit **token downsampling** in the vision stream
* **Temporal patch size:** 2 (video-oriented pathway exists in the general GLM-V stack)
* **Vision output hidden:** `out_hidden_size = 1536` (matches text hidden size)

The merge/downsample concept matches the GLM-4.6V processor design (same processor family), where images are patchified with `patch_size=14` and then merged with `merge_size=2`. ([Hugging Face][2])

### 2.3 Multimodal glue: connector + placeholder token expansion

The config defines explicit special tokens:

* `<|begin_of_image|>` id **59279**
* `<|image|>` id **59280**
* `<|end_of_image|>` id **59281**

The prompting convention is:

```
... <|begin_of_image|><|image|><|end_of_image|> ...
```

In practice, `<|image|>` is a **placeholder** in the token stream: at runtime the processor emits both `input_ids` *and* `pixel_values`, and the model fuses them by injecting the (downsampled) vision embeddings into the language context around that placeholder.

The processor class in the model repo is explicitly **`Glm46VProcessor`** / **`Glm46VImageProcessor`** (same family as GLM-4.6V), which is where the patch/merge + pixel-budget resizing policy comes from. ([Hugging Face][2])

---

## 3) Tokenization + chat template mechanics (important for “runtime correctness”)

The shipped `chat_template.jinja` (from the HF snapshot) enforces a few nonstandard-but-critical behaviors:

### 3.1 Prefix: `[gMASK]<sop>`

Every prompt starts with:

* `[gMASK]<sop>\n`

This is a **ChatGLM-style** decoding setup where the model is trained to generate starting at a sentinel mask position. This affects how you must build prompts if you are implementing your own runtime.

### 3.2 Roles and thinking toggles

The template uses `<|system|>`, `<|user|>`, `<|assistant|>` and includes optional toggles:

* user message may end with `/think` or `/nothink`
* the assistant side can inject `<think>...</think>` blocks depending on `enable_thinking`

For OCR workloads you typically want deterministic, “no hidden reasoning” formatted outputs, so `/nothink` + constrained decoding (low temperature) is consistent with the provided defaults.

### 3.3 Image placeholders are *structural markers*, not “literal tokens to be OCR’d”

You should treat the `<|begin_of_image|> … <|end_of_image|>` sequence as a **modal boundary**. A correct runtime must:

* tokenize that placeholder sequence in the text stream, **and**
* supply the image tensor(s) aligned to those placeholders.

---

## 4) Parameter accounting (what we can infer without weights)

Because weights aren’t present, the best we can do is **config-based estimation** + reconcile with the stated “~0.9B”.

### 4.1 Decoder parameter estimate (text side)

Assuming a fairly standard decoder block (Q/K/V/O projections + FFN with 2 linear layers, not a gated 3-matrix SwiGLU):

* **Embeddings:** vocab(59392) × hidden(1536) ≈ **91.2M**
* **LM head (untied):** another ≈ **91.2M**
* **Per-layer attention:** ~ **7.08M**
* **Per-layer FFN (2-matrix):** 2 × 1536 × 4608 ≈ **14.16M**
* **Per-layer total:** ~ **21.24M** (plus tiny norms)
* **×16 layers:** ~ **339.8M**
* **Decoder total:** ~ **522M**

That aligns well with the “GLM-0.5B” naming.

If the FFN were gated (3 matrices), the decoder estimate rises to ~635M.

### 4.2 Vision encoder estimate

For a ViT-like block (QKV+O + 2-layer MLP):

* **Per-layer attention:** 4 × 1024 × 1024 ≈ **4.19M**
* **Per-layer MLP (2-matrix):** 2 × 1024 × 4096 ≈ **8.39M**
* **Per-layer total:** ~ **12.58M**
* **×24 layers:** ~ **302M**
* * patch embed + positional params: low single-digit millions

So vision is on the order of **~300M** with a plain 2-matrix MLP; more if it uses a gated MLP.

### 4.3 Reconciling to “~0.9B”

A “text ~0.52B + vision ~0.30B” baseline is ~0.82B, leaving ~0.08B for:

* connector/projector(s),
* any extra embedding tables / modality adapters,
* and/or **gated MLPs** (either in vision or language),
* and MTP head parameters.

The published “~0.9B” claim suggests at least one of these subsystems is *not* the minimalist interpretation. ([Hugging Face][1])

---

## 5) The runtime stack (what actually runs end-to-end)

There are **two distinct runtimes** you should keep separate:

1. **“Model inference runtime”** (how `GlmOcrForConditionalGeneration` runs)
2. **“OCR system runtime”** (how documents become structured text)

### 5.1 Model inference runtime (Transformers-style)

Canonical steps:

1. **Build messages** with interleaved text + image placeholders.
2. **Processor** (`Glm46VProcessor`) produces:

   * `input_ids`, `attention_mask`
   * `pixel_values` (+ image grid metadata internally)
   * correct padding/alignment policies for variable-res images
3. **Model forward/generate**:

   * vision encoder runs on `pixel_values`
   * vision tokens are **downsampled** (merge size 2) and projected to hidden=1536
   * fused into the text decoding context around `<|image|>`
4. **Decode** output tokens to text (typically Markdown-like OCR output)

The processor’s “pixel-budget resizing” uses fields that look like `shortest_edge`/`longest_edge` but are effectively **min/max pixel constraints**, consistent with the GLM-4.6V family docs. ([Hugging Face][2])

### 5.2 OCR system runtime (the official pipeline in the GitHub repo)

The `glmocr` Python package is not just “call the VLM once”; it’s a **document OCR orchestrator**.

#### Stage A — Page ingestion

`PageLoader` loads:

* PDFs (page rasterization) and/or images
* normalizes orientation, converts to PIL
* **resizes** with constraints designed to preserve patch-grid alignment:

In `utils/image_utils.py`, resizing enforces divisibility by:

* `factor = patch_size * t_patch_size * patch_expand_factor`

With defaults in `config.yaml`:

* `patch_size = 14`
* `t_patch_size = 2`
* `patch_expand_factor = 1`

So `factor = 28`. This is exactly what you’d expect if the model patchifies at 14 and then merges 2×2: you want dimensions divisible by **28** so the post-merge grid is integral.

This is one of the most important “gotchas” if you write your own client: **send images at arbitrary sizes and you can silently pay for padding, or worse, hit incompatibilities in some backends.**

#### Stage B — Optional layout analysis

If enabled (`enable_layout: true`), the pipeline runs **PP-DocLayout-V3** via Transformers:

* `PPDocLayoutV3Processor`
* `PPDocLayoutV3ForObjectDetection`

That yields bounding boxes / classes for document elements; then the OCR step runs **per region**.

This matches the public description of the system pipeline (“layout analysis” → “parallel recognition”). ([Hugging Face][1])

#### Stage C — Parallel region OCR via an inference backend

This repo’s **default mode** is *not* local in-process inference; it’s a **client** that calls an external backend:

* For OpenAI-compatible backends (`vLLM`, `sglang`, `mlx-vlm.server`, etc.), it calls `/v1/chat/completions` with:

  * a text prompt
  * and an `image_url` with base64 data

* For **Ollama**, it calls `/api/generate` and sets `RENDERER=glm-ocr` / `PARSER=glm-ocr` (because Ollama’s OpenAI-compat vision support isn’t always aligned). This is spelled out in the provided `examples/ollama-deploy/README.md`.

Concurrency:

* region OCR is parallelized via `ThreadPoolExecutor` (`max_threads`), while each request is independent.

#### Stage D — Postprocessing + formatting

The SDK aggregates region outputs into:

* Markdown / plain text,
* and a structured JSON with `pages` and `bboxes`,
* including bbox ID normalization for cross-page consistency (see `_normalise_markdown_bboxes` in `api.py`).

---

## 6) Self-hosting backends and what they imply about the model

### 6.1 vLLM

vLLM explicitly lists support for **`glm_ocr`** and an **MTP variant `glm_ocr_mtp`** in its model registry. ([vLLM][3])

Implication:

* The “MTP head exists” is not just a training detail; it can be used in specialized decoding paths. vLLM’s own notes on **MTP** describe it as a mechanism to predict multiple future tokens per step (commonly used to accelerate decoding / speculation-style workflows). ([vLLM][4])

### 6.2 Apple Silicon via MLX

The official repo includes an `examples/mlx-deploy` guide built around **`mlx-vlm.server`**, which provides an OpenAI-compatible server interface on top of MLX.

On the upstream side, the `mlx-vlm` project documents OpenAI-style serving (`mlx_vlm.server`). ([GitHub][5])
There are also MLX-converted checkpoints (e.g., `mlx-community/GLM-OCR-8bit`) that are explicitly produced using `mlx-vlm` tooling. ([Hugging Face][6])

---

## 7) Practical “knobs” that materially affect correctness and performance

If you’re evaluating/implementing a runtime (especially on-device), these are the high-leverage controls:

1. **Image pixel budget → visual token count → latency**

   * Larger images preserve small glyphs but blow up the vision sequence length.
   * The SDK’s `max_pixels` default (in `glmocr/config.yaml`) is conservative compared to the model processor’s upper bounds—useful for throughput, sometimes harmful for tiny text.

2. **Divisibility constraints (14×merge_size = 28)**

   * If you resize yourself, keep `H` and `W` divisible by **28** to avoid ragged grids.

3. **Layout on/off**

   * Layout improves structure and table handling but adds a full detector pass + crop bookkeeping.
   * For “simple single-block text images”, you may disable layout and do a single-shot OCR call.

4. **Decoding constraints**

   * OCR wants *format fidelity* more than “creative language”; use low temperature, bounded `max_tokens`, and stable EOS handling.

---

## 8) Mental model diagram

```
           ┌───────────────────────────────────────────────────────┐
           │                    Prompt / Messages                   │
           │  [gMASK]<sop> ... <|begin_of_image|><|image|>...        │
           └───────────────┬───────────────────────────────────────┘
                           │
                    Glm46VProcessor
                           │
         ┌─────────────────┴──────────────────┐
         │                                    │
   input_ids/attn_mask                    pixel_values
         │                                    │
         │                              CogViT Vision Encoder
         │                              (patch=14, depth=24)
         │                                    │
         │                         spatial merge (merge=2)
         │                                    │
         │                       projector/connector → 1536-d
         │                                    │
         └───────────────┬────────────────────┘
                         │  (fuse vision embeddings at <|image|>)
                 GLM Text Decoder (16L, 1536, GQA 16/8, RoPE 128K)
                         │
                   (optional MTP head)
                         │
                      OCR text (Markdown / structured)
```

[1]: https://huggingface.co/zai-org/GLM-OCR "https://huggingface.co/zai-org/GLM-OCR"
[2]: https://huggingface.co/docs/transformers/model_doc/glm46v "https://huggingface.co/docs/transformers/model_doc/glm46v"
[3]: https://docs.vllm.ai/en/latest/models/supported_models/ "https://docs.vllm.ai/en/latest/models/supported_models/"
[4]: https://docs.vllm.ai/projects/recipes/en/latest/GLM/GLM.html "https://docs.vllm.ai/projects/recipes/en/latest/GLM/GLM.html"
[5]: https://github.com/Blaizzy/mlx-vlm "https://github.com/Blaizzy/mlx-vlm"
[6]: https://huggingface.co/mlx-community/GLM-OCR-8bit "https://huggingface.co/mlx-community/GLM-OCR-8bit"
