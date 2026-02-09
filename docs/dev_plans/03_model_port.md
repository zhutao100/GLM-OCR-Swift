# Phase 03 — Model port: GLM-OCR architecture + weights mapping

**Objective:** implement the actual GLM-OCR model in MLX Swift.

Borrowing references: `docs/reference_projects.md` (“Borrowing map”, DeepSeek OCR / DeepSeek OCR2).

## Tasks
- [ ] Mirror the official MLX Python model architecture:
  - CogViT visual encoder
  - connector
  - GLM decoder
- [ ] Implement weight name mapping + shard loading
  - borrow: `WeightsLoader` multi-file safetensors loading + dtype selection (`mzbac/deepseek-ocr2.swift` `Weights/WeightsLoader.swift`)
  - borrow: key mapping + post-processing structure (`DeepSeekOCRModel.load(from:)` + `sanitizeWeights(_:)`) (`mzbac/deepseek-ocr.swift` `DeepSeekOCRModel.swift`)
- [ ] Validate tokenizer + special tokens
- [ ] Add golden tests (small prompts) and compare to Python reference outputs
  - borrow: KV-cache utilities for long outputs / batching (`KVCache*`) (`mzbac/deepseek-ocr2.swift` `Utils/KVCache.swift`)

## Exit criteria
- Parity within acceptable tolerance vs the official MLX Python example on 3-5 test images
