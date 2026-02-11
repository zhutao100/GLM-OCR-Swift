# Phase 04.8 Implementation Plan — PP-DocLayout-V3 parity (golden fixtures + full model alignment)

## Goal
Make the Swift `DocLayoutAdapter` PP-DocLayout-V3 detector produce **numerically comparable** outputs to the official Python/Transformers model, so that layout mode quality matches `examples/result/*`.

This phase is explicitly about **model parity**, not downstream formatting.

## Why
The current Swift port is an **encoder-only subset** (see `docs/decisions/0003-ppdoclayoutv3-encoder-only-inference.md`), which is sufficient for wiring but not for reference-quality detections.

## Inputs / references
- Official detector: `../GLM-OCR/glmocr/layout/layout_detector.py`
- HF reference model: `transformers.PPDocLayoutV3ForObjectDetection`
- Golden workflow: `docs/golden_checks.md`
- Fixture generator: `scripts/generate_ppdoclayoutv3_golden.py`
- Swift golden test: `Tests/DocLayoutAdapterTests/PPDocLayoutV3GoldenIntegrationTests.swift`

## Plan

### 1) Tighten the parity contract (fixture + test)
- Ensure the fixture records enough metadata to reproduce:
  - snapshot hash (HF cache)
  - device + dtype
  - processor config summary (resize/rescale/normalize, `pixel_values` shape/layout)
- Keep the fixture small:
  - store a deterministic image input
  - store slices of `logits` and `pred_boxes` at deterministic `(query_idx, class_idx)` coordinates
- Optional (only if debugging requires it): add a `v2` fixture that also stores *intermediate* tensor stats (means/stds) to localize drift (backbone → encoder → decoder).

### 2) Port the missing PP-DocLayout-V3 blocks in MLX Swift
Incrementally evolve `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift` from encoder-only to parity:
- Implement the model’s **encoder** stack as in HF (including any downsample convs + transformer layers).
- Implement the **decoder** stack, including:
  - self-attention
  - multi-scale cross-attention (deformable attention)
  - iterative bbox refinement (if present)
- Verify weight mapping (key names, shape/layout conversions, LN/BN eps).

Notes:
- Preserve module boundaries: only `DocLayoutAdapter` owns PP-DocLayout-V3 specifics.
- Prefer deterministic, testable helpers for any geometry math (sampling grids, bbox conversions).

### 3) Align output conventions to HF
- Match `PPDocLayoutV3ForObjectDetection` forward outputs:
  - `logits`: `[B, num_queries, num_labels]`
  - `pred_boxes`: `[B, num_queries, 4]` in normalized `cxcywh` (0..1)
- Match any additional heads required for downstream ordering:
  - `order_seq` (or the logits used to compute it)
  - polygon/mask-related outputs only if needed by the reference pipeline

### 4) Make the golden test pass (opt-in)
- Generate fixture:
  - `PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py --model-folder "$LAYOUT_SNAPSHOT_PATH" --device mps`
- Run:
  - `LAYOUT_SNAPSHOT_PATH=<snapshot> LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenIntegrationTests`
- Iterate until `logits` and `pred_boxes` slices match within an agreed tolerance.

## Exit criteria
- `PPDocLayoutV3GoldenIntegrationTests` passes on Apple Silicon (opt-in: `LAYOUT_RUN_GOLDEN=1`).
- `PPDocLayoutV3Detector.detect(ciImage:)` emits stable, non-degenerate regions on a real page (manual check on `examples/source/*`).
