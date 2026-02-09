# ADR 0002 — Multimodal generation API + GLM chat template + KV cache

## Status
Accepted (2026-02-09)

## Context
Phase 03 requires end-to-end OCR (image/PDF page → text) with:

- correct GLM-style prompting (`[gMASK]<sop>` + role tokens + image placeholders), and
- practical token-by-token decoding performance (OCR outputs can be long).

The repository’s core/adapter split also means:

- `VLMRuntimeKit` should stay model-agnostic, and
- GLM-OCR-specific prompting and preprocessing should live in `GLMOCRAdapter`.

## Decision
1. **Make generation explicitly multimodal** in the core interface:
   - `VLMRuntimeKit.Generation.CausalLM.generate(prompt:pixelValues:options:)`
   - `pixelValues` is optional to keep the protocol usable for text-only models.

2. **Implement GLM-OCR chat-template tokenization in the adapter**:
   - `GLMOCRChatTemplate` builds `input_ids` with:
     - `[gMASK]`, `<sop>`, role tokens (`<|user|>`, `<|assistant|>`),
     - `<|begin_of_image|><|image|>...<|end_of_image|>` placeholder sequence,
     - optional `/nothink` suffix for deterministic OCR outputs.

3. **Add a simple KV cache primitive in the core** and use it in the GLM decoder:
   - `VLMRuntimeKit.Generation.KVCacheSimple` stores `[B, kvHeads, T, headDim]` keys/values and grows as needed.
   - `GLMOCRSelfAttention` updates per-layer caches and applies RoPE with `offset = cache.offset`.
   - Prompt fill uses a causal mask; incremental decode (seqLen=1) uses `.none` because only past/current keys exist.

4. **Compute vision embeddings once per request**:
   - `GLMOCRModel.generate` runs the vision encoder once, fuses vision embeddings into the prompt at `<|image|>` positions, and fills the KV caches.
   - Subsequent decode steps embed a single token and reuse the caches; the vision encoder is not re-run per token.

## Consequences
- End-to-end OCR is fast enough for interactive use (KV cache avoids O(T²) re-computation).
- The core remains largely model-agnostic: it owns only a generic cache primitive and the multimodal `generate` signature.
- The GLM-OCR adapter is the single source of truth for:
  - resize/normalization policy (`GLMOCRImageProcessor`),
  - chat-template token layout (`GLMOCRChatTemplate`),
  - and decode strategy (greedy + cancellation).

## Follow-ups
- Consider streaming output (`AsyncSequence`) and sampling (temperature/top-p) in `VLMRuntimeKit.Generation`.
- Consider supporting multiple images/placeholders and richer message structures (system prompts, tools) without pulling Jinja templating into Swift.
