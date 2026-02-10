# ADR 0003 — PP-DocLayout-V3 encoder-only detector inference (interim)

## Status
Accepted (2026-02-10)

## Context
Phase 04 needs a fully local layout detector to produce ordered regions for downstream OCR.

The upstream PP-DocLayout-V3 Hugging Face model includes a deformable DETR-style decoder (deformable attention), which is a large port to implement correctly in Swift/MLX.

For Phase 04.6, the immediate requirement is to produce the raw outputs consumed by deterministic post-processing:
- `scores`, `labels`, `boxes` (normalized bbox space 0–1000)
- `order_seq` (reading order)

## Decision
Implement `PPDocLayoutV3Model` as an **encoder-only subset** that still emits the required raw detections:

- Run the HGNetV2 backbone and encoder projections.
- Use encoder heads (`enc_score_head`, `enc_bbox_head`) to produce candidate detections.
- Select top-K encoder locations as “queries” (no deformable decoder).
- Compute `order_seq` using the global-pointer order head over the selected embeddings.
- Do not emit polygons from the model; `PPDocLayoutV3Postprocess` synthesizes bbox polygons when absent.

## Consequences
- Enables end-to-end detector inference → postprocess wiring now (Phase 04.6), keeping the project moving.
- Detection quality may be below the full HF implementation (decoder is omitted).
- Future parity work can replace the encoder-only path with a full hybrid encoder + deformable decoder port while keeping the same postprocess/output invariants.
