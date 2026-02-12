# PP-DocLayout-V3 misalignment audit (effort 2)

This note started as an architectural/keypath audit of the Swift port vs Hugging Face Transformers.

Some hypotheses have since been **validated/disproven** for the specific snapshot used by the checked-in fixtures.

For the canonical “how to run + what we learned”, see:
- `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`

Last updated: **2026-02-12**

## Verified snapshot facts (checked-in fixtures baseline)

Snapshot:
- `a0abee1e2bb505e5662993235af873a5d89851e3`
- Transformers: `5.1.0`

Facts:
- `config.json` has `eval_size: null` (so AIFI positional embeddings are **enabled** in eval in the reference).
- `model.safetensors` has **0** keys under `model.encoder.transformer_layers.*`.
- AIFI weights live under `model.encoder.encoder.*` and include `self_attn.{q,k,v,out}_proj.*` + FFN + norms.
- The fixture v3 intermediate parity test passes for the **pre-decoder intermediates** currently captured.

## Disproven hypothesis: “transformer_layers” key mismatch → AIFI weights not loaded

Earlier versions of this audit assumed the reference stored AIFI blocks under `model.encoder.transformer_layers.*`.

For the current fixture snapshot, that keypath simply does not exist (0 keys), so:
- there is no missing-weights issue under `transformer_layers`, and
- the Swift module keypath `model.encoder.encoder.*` is the one that matches the snapshot.

If you ever switch snapshots / Transformers versions, re-check the keypaths (do not assume).

## Remaining high-leverage suspects (current)

Given that encoder-side intermediates match at sampled points but final logits/boxes drift, the most likely mismatch is in the **decoder**, especially:

1. **Multi-scale deformable cross-attention**
   - `sampling_offsets` / `attention_weights` projection math
   - `sampling_locations` normalization (width/height order, level shapes)
   - per-level reshape/transpose order (NHWC vs BSC vs head split)
2. **`grid_sample` semantics**
   - `align_corners=false` coordinate mapping (half-pixel behavior)
   - x/y ordering
   - out-of-bounds handling (zero padding)
3. **BBox refinement / reference point updates**
   - `inverse_sigmoid` behavior and eps
   - iterative update ordering and dtype casts

Secondary suspects (still worth validating if decoder probes unexpectedly match):
- preprocess kernel differences (CoreImage vs PIL bicubic)
- pooling boundary semantics in the backbone

## Recommended next steps

1. Extend fixture v3 + Swift probes into the decoder:
   - first decoder layer only
   - a tiny index set (e.g. queries {0,1,2}, head 0, levels {0,1}, points {0,1})
   - capture: `sampling_locations`, `attention_weights`, and one `grid_sample` output vector slice
2. Add a standalone micro-test for `grid_sample` parity against PyTorch CPU.
3. Fix the *first* decoder mismatch, then re-run:
   - `PPDocLayoutV3IntermediateParityIntegrationTests`
   - `PPDocLayoutV3GoldenFloat32IntegrationTests`
