# AGENTS.md

This repo is a **native macOS local-inference OCR app + CLI** (Swift + MLX). Treat it as its own runtime, not as a port of the upstream Python stack.

## Durable guardrails

- **Keep module boundaries crisp**
  - `VLMRuntimeKit`: model-agnostic runtime primitives (types, IO, caching, exports, page selection).
  - `ModelAdapters/*`: model-specific code only (PP-DocLayoutV3, GLM-OCR).
  - `GLMOCRCLI` / `GLMOCRApp`: thin orchestration layers (no model logic).
- **Prefer deterministic, unit-testable helpers** for preprocessing, prompt/template policy, cache-path resolution, page selection, and export formatting.
- **Swift 6 strict concurrency**: default to `Sendable` value types; use `actor` for shared mutable state; avoid broad `@unchecked Sendable`.
- **Avoid `fatalError`** except for genuinely unrecoverable programmer errors; prefer typed errors at external boundaries.

## Fast loops (source of truth)

```bash
# Mandatory fast verifier after edits
./scripts/verify_fast.sh

# Production/release build path (xcodebuild wrapper)
./scripts/build.sh

# One-shot build + packaging of release artifacts (CLI + App zips)
./scripts/release_artifacts.sh

# Live CLI contract
./scripts/build.sh
.build/xcode/Build/Products/Release/GLMOCRCLI --help
```

Notes:

- SwiftPM executables (`swift run ...`) may need a SwiftPM metallib on a clean checkout: `./scripts/build_mlx_metallib.sh -c debug`.

## Opt-in lanes (model-backed / expensive)

- Enable only when needed:
  - `GLMOCR_RUN_GOLDEN=1`
  - `LAYOUT_RUN_GOLDEN=1`
  - `GLMOCR_RUN_EXAMPLES=1`
  - `GLMOCR_TEST_RUN_FORWARD_PASS=1`
  - `GLMOCR_TEST_RUN_GENERATE=1`
- Prefer local cached snapshots when provided:
  - `GLMOCR_SNAPSHOT_PATH`
  - `LAYOUT_SNAPSHOT_PATH`

See `docs/golden_checks.md` and `examples/README.md` for the parity/eval contracts.

## Docs + release hygiene

- If **CLI flags/defaults/outputs** change: update `docs/apis/cli.md` and (when user-visible) `README.md`.
- If **runtime flow, module boundaries, cache layout, or prompt/template policy** changes: update `docs/architecture.md` and add an ADR under `docs/decisions/`.
- Keep scripts **quiet by default**; write detailed logs under `artifacts/` (gitignored).

## Commits

- Use **Conventional Commits** and keep commits scoped (scripts/docs/CI changes separated when practical).
