# Preprocessing + fusion primitives port (glm-ocr.swift → GLM-OCR-Swift)

**Objective:** Port the highest-leverage “fidelity primitives” from `glm-ocr.swift` into `GLM-OCR-Swift` (deterministic preprocessing modes + vectorized fusion), and add tests that prevent regressions (fusion correctness + chat-template drift).

**Status (2026-03-05):** completed — phases 0–4 landed; run `swift test` (conformance checks run when a GLM-OCR snapshot is cached; override with `GLMOCR_SNAPSHOT_PATH`).

## Phases (source of truth)

- [x] Phase 0 — Harden plan docs (`context.md`, `patch_plan.md`) and add this tracker.
- [x] Phase 1 — `VLMRuntimeKit/VisionIO`: deterministic raster → bicubic resize (CPU) → optional JPEG round-trip; add RGB→tensor conversion + unit tests.
- [x] Phase 2 — `GLMOCRAdapter`: add preprocessing backends + parity toggles; wire dtype alignment to match the model’s vision weights (recommended for parity runs).
- [x] Phase 3 — `GLMOCRFusion`: replace per-token mutation loop with vectorized fuse; add multi-batch regression tests.
- [x] Phase 4 — Chat-template conformance harness: verify `GLMOCRChatTemplate.buildInputIDs(...)` matches tokenizer encoding for a canonical single-turn prompt (requires a local snapshot; auto-resolved from HF cache, override via `GLMOCR_SNAPSHOT_PATH`).

## Verification checklist (per phase)

- `swift test`
- If Phase 4: `swift test --filter GLMOCRChatTemplateConformanceTests` (requires a cached snapshot; override via `GLMOCR_SNAPSHOT_PATH`)
