# Phase 02 — Model port: GLM-OCR architecture + weights mapping

**Objective:** implement the actual GLM-OCR model in MLX Swift.

Borrowing references: `docs/reference_projects.md` (“Borrowing map”, DeepSeek OCR / DeepSeek OCR2).

**Status (2026-02-09):** GLM-OCR model architecture + safetensors weight loading + tokenizer validation are implemented; an opt-in Python/Transformers forward-pass golden check exists (skipped by default). Broader “quality parity on real documents” is still pending.

## Tasks
- [x] Stub `GLMOCRModel` load path
  - model snapshot download + `GLMOCRModel.load(from:)` harness exists
- [x] Mirror the official MLX Python model architecture:
  - CogViT visual encoder
  - connector
  - GLM decoder
- [x] Implement weight name mapping + shard loading
  - borrow: `WeightsLoader` multi-file safetensors loading + dtype selection (`mzbac/deepseek-ocr2.swift` `Weights/WeightsLoader.swift`)
  - borrow: key mapping + post-processing structure (`DeepSeekOCRModel.load(from:)` + `sanitizeWeights(_:)`) (`mzbac/deepseek-ocr.swift` `DeepSeekOCRModel.swift`)
- [x] Add a minimal “single forward pass” harness
  - load config + load weights + run one forward pass (logits only; no decoding yet)
- [x] Validate tokenizer + special tokens
- [x] Add golden tests (small prompts) and compare to Python reference outputs
  - borrow: KV-cache utilities for long outputs / batching (`KVCache*`) (`mzbac/deepseek-ocr2.swift` `Utils/KVCache.swift`)
  - note: the parity golden test is opt-in (skipped by default) and requires generating a local fixture.

## Exit criteria
- `GLMOCRModel.load(from:)` loads config + weights successfully
- One forward pass runs end-to-end in Swift (logits produced)

## Local runtime note (MLX Metal shaders)
When running via SwiftPM, MLX requires a colocated `mlx.metallib`. Build it with:

```bash
scripts/build_mlx_metallib.sh -c debug
```

## Opt-in integration tests
- Tokenizer + special token IDs (requires local snapshot):
  - `GLMOCR_SNAPSHOT_PATH=<path> swift test`
- Forward pass smoke (also requires `mlx.metallib`):
  - `GLMOCR_SNAPSHOT_PATH=<path> GLMOCR_TEST_RUN_FORWARD_PASS=1 swift test`
- Python/Transformers parity golden (also requires `mlx.metallib`):
  - `python3 scripts/generate_glmocr_golden.py --model-folder <path>`
  - `GLMOCR_SNAPSHOT_PATH=<path> GLMOCR_RUN_GOLDEN=1 swift test`

Parity notes:
- Keep device/dtype aligned between the fixture generator and Swift parity runs; see `docs/golden_checks.md`.
