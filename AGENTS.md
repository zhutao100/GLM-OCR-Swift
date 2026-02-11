# Agent Operating Guide (AGENTS.md)

This repository is intended to be safely evolvable by **agentic coding tools** across many sessions.

## Mission

Build a **fully native macOS (Apple Silicon) GLM-OCR app** in Swift using:

- **MLX Swift** for inference
- **Hugging Face Swift tooling** (`HubApi.snapshot` today; tokenizer integration planned) for model download + tokenizer loading
- A maintainable architecture that supports future consolidation into a multi-model OCR workbench.

## Current reality (2026-02-09)

- The repo builds and tests cleanly (`swift test`).
- `ModelStore` snapshot download + HF cache resolution is implemented.
- OCR inference is still stubbed (vision preprocessing, tokenizer/chat template, weights loading, model port, decode loop).

## Non-negotiables

1. **Preserve module boundaries**
   - `VLMRuntimeKit` must stay model-agnostic.
   - `GLMOCRAdapter` contains *only* GLM-OCR-specific glue.
   - UI code lives only in `GLMOCRApp`.

2. **Docs must stay in sync**
   - Update `docs/architecture.md` whenever module boundaries or public API shape changes.
   - Update `docs/dev_plans/*` checklists as milestones complete (keep them truthful).
   - Add ADRs in `docs/decisions/` for decisions that affect future work (interfaces, caching layout, tokenization/chat template scheme, etc.).

3. **Prefer deterministic, testable primitives**
   - Keep pure functions for preprocessing and prompt/template logic where possible.
   - Add unit tests for: prompt splitting, cache path rules, JSON schema task formatting, and any token budgeting logic.

## Repo map (fast navigation)

- `Sources/VLMRuntimeKit/` — model-agnostic runtime
  - `ModelStore/ModelStore.swift` — HF cache resolution + snapshot download
  - `TokenizerKit/PromptTemplate.swift` — `<image>` placeholder splitting + task→instruction mapping
  - `OCRTypes.swift` — public pipeline API (`OCRPipeline`, `OCRTask`, `GenerateOptions`, `OCRResult`)
  - `VisionIO/VisionIO.swift` — CIImage load (tensor conversion is currently a stub)
  - `Generation/Generation.swift` — generation façade (`CausalLM`, `GreedyGenerator`)
  - `Weights/Weights.swift` — weights loader placeholder
- `Sources/ModelAdapters/GLMOCR/` — GLM-OCR-specific adapter
  - `GLMOCRPipeline.swift` — orchestration actor (download → load → recognize)
  - `GLMOCRModel.swift` — model placeholder (generate is unimplemented)
  - `GLMOCRProcessor.swift` — prompt policy placeholder
  - `GLMOCRDefaults.swift` — default model id/revision/globs
- `Sources/GLMOCRCLI/GLMOCRCLI.swift` — CLI entrypoint
- `Sources/GLMOCRApp/` — SwiftUI app scaffold
- `Tests/VLMRuntimeKitTests/` — focused unit tests for deterministic helpers

## Docs: what to read first (by task)

- **Triage / “what is broken?”**
  - `docs/overview.md` (status + pointers)
  - run `swift test`, then reproduce with `swift run GLMOCRCLI --help`
- **Feature work (runtime / pipeline)**
  - `docs/architecture.md` (boundaries + dataflow)
  - relevant phase in `docs/dev_plans/`
  - add/update an ADR in `docs/decisions/` if you introduce a new interface, cache layout, or tokenization scheme
- **Bugfix (small, local)**
  - search usage with `rg` (types above are the main entry points)
  - add a unit test in `Tests/VLMRuntimeKitTests/` when the fix is deterministic
- **Docs-only changes**
  - keep `README.md`, `AGENTS.md`, and `docs/*` consistent; prefer linking over duplication

## Build / test commands

```bash
swift build
swift test
swift run GLMOCRCLI --help
swift run GLMOCRApp
```

## Formatting / linting (optional but preferred)

This repo includes configs for local tooling:

- SwiftFormat: `.swiftformat`
- SwiftLint: `.swiftlint.yml`
- pre-commit: `.pre-commit-config.yaml`

Typical commands (if installed):

```bash
swiftformat --config .swiftformat .
swiftlint --config .swiftlint.yml
pre-commit run -a
```

## Coding conventions

- Swift 6 strict concurrency is enabled for all targets.
- Default to `Sendable` value types; use `actor` for mutable shared state.
- Avoid global singletons (except lightweight statics for constants).
- Fail with typed errors (`enum: Error`) rather than `fatalError`, unless the failure is truly unrecoverable.

## MLX vs PyTorch (MPS) dtype quirks (parity-critical)

- **MPS defaults to FP16 often**: PyTorch/Transformers commonly runs models + `pixel_values` in `float16` on MPS; parity runs in Swift should force **both weights and inputs** to `.float16`.
- **Mixed-dtype comparisons can differ**: PyTorch MPS may effectively compare FP16 tensors against FP32 scalars (e.g. `eps`) in FP32; if a mask depends on thresholds, match the reference comparison dtype explicitly (often by casting the tensor to FP32 for the compare).
- **Sentinel magnitudes must be dtype-aware**: casting `Float.greatestFiniteMagnitude` to FP16 becomes `inf`; prefer `Float16.greatestFiniteMagnitude` (or an explicit finite FP16 max) for masking to avoid `inf`/`NaN` cascades.
- **FP16 border sensitivity is real**: operations like `grid_sample(align_corners=false)` are very sensitive near `[0, 1]`; FP16 rounding can flip in/out-of-bounds. When writing golden checks, prefer stable probe indices and record any internal selection indices (see `docs/golden_checks.md`).

## Work plan checkpoints

- Phase plans: `docs/dev_plans/`

## References

- Reference projects notes: `docs/reference_projects.md`
- `GLM-OCR` model insights: `docs/GLM-OCR_model.md`

## Useful Tools / Resources

- Inspect `.safetensors` structure:
  - `~/bin/stls.py --format toon <file.safetensors>`
  - If missing: `curl https://gist.githubusercontent.com/zhutao100/cc481d2cd248aa8769e1abb3887facc8/raw/89d644c490bcf5386cb81ebcc36c92471f578c60/stls.py > ~/bin/stls.py`
- Model snapshot cache (common location `~/.cache/huggingface/hub/`):
  - `zai-org--GLM-OCR`: `~/.cache/huggingface/hub/models--zai-org--GLM-OCR/snapshots`
  - `PaddlePaddle/PP-DocLayoutV3_safetensors`: `~/.cache/huggingface/hub/models--PaddlePaddle--PP-DocLayoutV3_safetensors`
  - Use shell command `hf cache ls` to list model caches, `hf cache download [model-org]/[model-id]` to download models as needed.
- Reference Swift OCR Model projects
  - [deepseek-ocr2.swift](https://github.com/mzbac/deepseek-ocr2.swift) for model `DeepSeek-OCR2`: accessible at `../deepseek-ocr2.swift`
  - [deepseek-ocr.swift](https://github.com/mzbac/deepseek-ocr.swift) for model `DeepSeek-OCR`: accessible at `../deepseek-ocr.swift`
  - [paddleocr-vl.swift](https://github.com/mlx-community/paddleocr-vl.swift) for model `PaddleOCR-VL`: accessible at `../paddleocr-vl.swift`
- The official github repo [GLM-OCR](https://github.com/zai-org/GLM-OCR/): accessible at `../GLM-OCR`
