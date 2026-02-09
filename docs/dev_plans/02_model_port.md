# Phase 02 — Model port: GLM-OCR architecture + weights mapping

**Objective:** implement the actual GLM-OCR model in MLX Swift.

Borrowing references: `docs/reference_projects.md` (“Borrowing map”, DeepSeek OCR / DeepSeek OCR2).

**Status (2026-02-09):** adapter scaffolding exists, but the MLX Swift model + weights mapping is not implemented.

## Tasks
- [x] Stub `GLMOCRModel` load path
  - model snapshot download + `GLMOCRModel.load(from:)` harness exists
- [ ] Mirror the official MLX Python model architecture:
  - CogViT visual encoder
  - connector
  - GLM decoder
- [ ] Implement weight name mapping + shard loading
  - borrow: `WeightsLoader` multi-file safetensors loading + dtype selection (`mzbac/deepseek-ocr2.swift` `Weights/WeightsLoader.swift`)
  - borrow: key mapping + post-processing structure (`DeepSeekOCRModel.load(from:)` + `sanitizeWeights(_:)`) (`mzbac/deepseek-ocr.swift` `DeepSeekOCRModel.swift`)
- [ ] Add a minimal “single forward pass” harness
  - load config + load weights + run one forward pass (logits only; no decoding yet)
- [ ] Validate tokenizer + special tokens
- [ ] Add golden tests (small prompts) and compare to Python reference outputs
  - borrow: KV-cache utilities for long outputs / batching (`KVCache*`) (`mzbac/deepseek-ocr2.swift` `Utils/KVCache.swift`)

## Exit criteria
- `GLMOCRModel.load(from:)` loads config + weights successfully
- One forward pass runs end-to-end in Swift (logits produced)
