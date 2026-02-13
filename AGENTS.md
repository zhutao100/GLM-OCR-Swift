# Agent Operating Guide (AGENTS.md)

This repository is intended to be safely evolvable by **agentic coding tools** across many sessions.

## Mission

Build a **fully native macOS (Apple Silicon) GLM-OCR app** in Swift using:

- **MLX Swift** for inference
- **Hugging Face Swift tooling** (`HubApi.snapshot` today; tokenizer integration planned) for model download + tokenizer loading
- A maintainable architecture that supports future consolidation into a multi-model OCR workbench.

## Current reality (2026-02-12)

- The repo builds and tests cleanly (`swift test`).
- `ModelStore` snapshot download + HF cache resolution is implemented.
- End-to-end OCR runs locally (MLX Swift) for:
  - a single image or a single PDF page (CLI + App),
  - optional layout mode (PP-DocLayout-V3 → region OCR → merged Markdown + structured `OCRDocument`).
- Integration tests for downloaded models are **opt-in** via env vars; see `docs/golden_checks.md`.

## Non-negotiables

1. **Preserve module boundaries**
   - `VLMRuntimeKit` must stay model-agnostic.
   - `DocLayoutAdapter` contains *only* PP-DocLayout-V3-specific glue.
   - `GLMOCRAdapter` contains *only* GLM-OCR-specific glue (and orchestration that composes the layout adapter).
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
  - `OCRDocumentTypes.swift` — structured output types (`OCRDocument`, pages/regions/bboxes)
  - `OCRBlockListExport.swift` — examples-compatible block-list JSON export
  - `VisionIO/VisionIO.swift` — image/PDF decode + CIImage→MLX tensor conversion
  - `VisionIO/VisionCrop.swift` — normalized bbox/polygon region crop
  - `MarkdownImageCropper.swift` — crop+replace `![](page=...,bbox=[...])` refs for `--emit-json` outputs
  - `Generation/Generation.swift` — generation façade (`CausalLM`, `GreedyGenerator`)
  - `Generation/KVCache.swift` — KV cache primitives
  - `Weights/Weights.swift` — safetensors loading helpers (adapter-specific mapping lives in adapters)
- `Sources/ModelAdapters/DocLayout/` — PP-DocLayout-V3 adapter (layout detection)
  - `PPDocLayoutV3Detector.swift` — snapshot load + inference + postprocess wiring
  - `PPDocLayoutV3Model.swift` — hybrid encoder + deformable decoder forward
  - `PPDocLayoutV3Postprocess.swift` — NMS + containment merge + ordering
  - `LayoutResultFormatter.swift` — regions → merged Markdown
- `Sources/ModelAdapters/GLMOCR/` — GLM-OCR adapter
  - `GLMOCRPipeline.swift` — download → load → recognize (single image/page)
  - `GLMOCRLayoutPipeline.swift` — layout detect → per-region OCR → merge (single page)
  - `GLMOCRModel.swift` — model definition + weight-loading + forward + greedy decode
  - `GLMOCRChatTemplate.swift` — GLM-OCR chat-template tokenization (`[gMASK]<sop>` + image placeholders)
  - `GLMOCRImageProcessor.swift` — GLM-OCR resize/normalize policy
  - `GLMOCRTokenizer.swift` — tokenizer load + special token ID validation
  - `GLMOCRDefaults.swift` — default model id/revision/globs
- `Sources/GLMOCRCLI/GLMOCRCLI.swift` — CLI entrypoint
- `Sources/GLMOCRApp/` — SwiftUI app scaffold
- `Tests/VLMRuntimeKitTests/` — deterministic unit tests (no model downloads)
- `Tests/DocLayoutAdapterTests/` — layout adapter tests (golden tests are opt-in)
- `Tests/GLMOCRAdapterTests/` — GLM-OCR adapter tests (integration/golden tests are opt-in)

## Docs: what to read first (by task)

- **Triage / “what is broken?”**
  - `docs/overview.md` (status + pointers)
  - run `swift test`, then reproduce with `swift run GLMOCRCLI --help` / `swift run GLMOCRCLI --input …`
- **Feature work (runtime / pipeline)**
  - `docs/architecture.md` (boundaries + dataflow)
  - relevant phase in `docs/dev_plans/README.md`
  - add/update an ADR in `docs/decisions/` if you introduce a new interface, cache layout, or tokenization scheme
- **Bugfix (small, local)**
  - search usage with `rg` (types above are the main entry points)
  - add a unit test in `Tests/VLMRuntimeKitTests/` when the fix is deterministic
- **Parity / golden work**
  - `docs/golden_checks.md` (workflow + env vars)
  - `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md` (layout golden drift playbook)
- **Release / distribution**
  - `docs/dev_plans/gui_polish_distribution/tracker.md` (source of truth; packaging is still planned)
- **Docs-only changes**
  - keep `README.md`, `AGENTS.md`, and `docs/*` consistent; prefer linking over duplication

## Build / test commands

```bash
swift build
swift test
scripts/build_mlx_metallib.sh -c debug
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
- When working with MLX,
  - no compound assignment on tensors unless you can prove non-aliasing.
  - prefer out-of-place ops in residual paths (`x = x + y`, not `x += y`) to avoid accidental aliasing drift.

## MLX vs PyTorch (MPS) dtype quirks (parity-critical)

- **MPS defaults to FP16 often**: PyTorch/Transformers commonly runs models + `pixel_values` in `float16` on MPS; parity runs in Swift should force **both weights and inputs** to `.float16`.
- **Mixed-dtype comparisons can differ**: PyTorch MPS may effectively compare FP16 tensors against FP32 scalars (e.g. `eps`) in FP32; if a mask depends on thresholds, match the reference comparison dtype explicitly (often by casting the tensor to FP32 for the compare).
- **Sentinel magnitudes must be dtype-aware**: casting `Float.greatestFiniteMagnitude` to FP16 becomes `inf`; prefer `Float16.greatestFiniteMagnitude` (or an explicit finite FP16 max) for masking to avoid `inf`/`NaN` cascades.
- **FP16 border sensitivity is real**: operations like `grid_sample(align_corners=false)` are very sensitive near `[0, 1]`; FP16 rounding can flip in/out-of-bounds. When writing golden checks, prefer stable probe indices and record any internal selection indices (see `docs/golden_checks.md`).

## Work plan checkpoints

- Phase plans: `docs/dev_plans/README.md`

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
- when inspecting the reference implementation in Python, use the virtual env `venv313` by pretending `PYENV_VERSION=venv313 pyenv exec ` to the command.
