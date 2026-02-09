# Phase 03 — Model port: GLM-OCR architecture + weights mapping

**Objective:** implement the actual GLM-OCR model in MLX Swift.

## Tasks
- [ ] Mirror the official MLX Python model architecture:
  - CogViT visual encoder
  - connector
  - GLM decoder
- [ ] Implement weight name mapping + shard loading
- [ ] Validate tokenizer + special tokens
- [ ] Add golden tests (small prompts) and compare to Python reference outputs

## Exit criteria
- Parity within acceptable tolerance vs the official MLX Python example on 3-5 test images
