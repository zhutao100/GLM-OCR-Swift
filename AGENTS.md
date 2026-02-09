# Agent Operating Guide (AGENTS.md)

This repository is intended to be safely evolvable by **agentic coding tools** across many sessions.

## Mission

Build a **fully native macOS (Apple Silicon) GLM-OCR app** in Swift using:

- **MLX Swift** for inference
- **Hugging Face Swift tooling** (Hub / Tokenizers) for model download + tokenizer loading
- A maintainable architecture that supports future consolidation into a multi-model OCR workbench.

## Non-negotiables

1. **Preserve module boundaries**
   - `VLMRuntimeKit` must stay model-agnostic.
   - `GLMOCRAdapter` contains *only* GLM-OCR-specific glue.
   - UI code lives only in `GLMOCRApp`.

2. **Docs must stay in sync**
   - Update `docs/architecture.md` whenever public types or module boundaries change.
   - Update `docs/dev_plans/*` checklists as milestones complete.
   - Add ADRs in `docs/decisions/` for decisions that affect future work (interfaces, caching layout, tokenization scheme, etc.).

3. **Prefer deterministic, testable primitives**
   - Keep pure functions for preprocessing and prompt/template logic.
   - Add unit tests for: prompt splitting, cache path rules, JSON schema task formatting, and any token budgeting logic.

## Build / test commands

```bash
swift build
swift test
swift run GLMOCRCLI --help
swift run GLMOCRApp
```

## Coding conventions

- Swift 6 strict concurrency is enabled for all targets.
- Default to `Sendable` value types; use `actor` for mutable shared state.
- Avoid global singletons (except lightweight statics for constants).
- Fail with typed errors (`enum: Error`) rather than `fatalError`, unless the failure is truly unrecoverable.

## Work plan checkpoints

- Phase plans: `docs/dev_plans/`
- Start with Phase 01 (ModelStore) then Phase 02 (MVP single image/page).

## References

- Reference projects notes: `docs/reference_projects.md`
- `GLM-OCR` model insights: `docs/GLM-OCR_model.md`

## Useful Tools / Resources

- Inspect `.safetensors` structure:
  - `~/bin/stls.py --format toon <file.safetensors>`
  - If missing: `curl https://gist.githubusercontent.com/zhutao100/cc481d2cd248aa8769e1abb3887facc8/raw/89d644c490bcf5386cb81ebcc36c92471f578c60/stls.py > ~/bin/stls.py`
- Default model snapshot cache (common location):
  - `~/.cache/huggingface/hub/models--zai-org--GLM-OCR/snapshots`
- Reference Swift OCR Model projects
  - [deepseek-ocr2.swift](https://github.com/mzbac/deepseek-ocr2.swift) for model `DeepSeek-OCR2`: accessible at `../deepseek-ocr2.swift`
  - [deepseek-ocr.swift](https://github.com/mzbac/deepseek-ocr.swift) for model `DeepSeek-OCR`: accessible at `../deepseek-ocr.swift`
  - [paddleocr-vl.swift](https://github.com/mlx-community/paddleocr-vl.swift) for model `PaddleOCR-VL`: accessible at `../paddleocr-vl.swift`
- The official github repo [GLM-OCR](https://github.com/zai-org/GLM-OCR/): accessible at `../GLM-OCR`
