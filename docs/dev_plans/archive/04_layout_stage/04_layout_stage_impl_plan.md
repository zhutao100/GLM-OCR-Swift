# Phase 04 Implementation Plan — Layout + region OCR orchestration (Index)

> Status: Complete (2026-02-12) — examples parity implemented; PP-DocLayout-V3 opt-in golden baselines pass.

## Summary
Implement the “full pipeline” path for documents: **PP-DocLayout-V3 layout detection → region cropping → per-region GLM-OCR → merge into ordered Markdown**, with **structured outputs (pages/regions/bboxes)** exposed via the public runtime types, plus **auto-tuned parallelism + cancellation**.

Primary reference behavior:
- `../GLM-OCR/glmocr/pipeline/pipeline.py`
- `../GLM-OCR/glmocr/layout/layout_detector.py`
- `../GLM-OCR/glmocr/utils/layout_postprocess_utils.py`
- `../GLM-OCR/glmocr/postprocess/result_formatter.py`

---

## Decisions (locked for implementer)
1. **Layout detector**: implement **PP-DocLayout-V3** locally (no network services), using HF snapshot download via existing `ModelStore`.
2. **Structured output**: extend the public runtime result types so callers can access **pages/regions/bboxes** (not just Markdown).
3. **Parallelism**: implement **auto-tuned region OCR concurrency** with a hard safety cap; default is “auto”, overridable from CLI/App.
4. **Coordinate system**: preserve official **normalized bbox space 0–1000** in structured results; convert carefully for Core Image cropping (top-left → CoreImage bottom-left).
5. **Markdown merge**: follow the official `ResultFormatter` rules (label mapping + title/formula formatting + block merges + image placeholders).

---

## Session-sized implementation plans (recommended order)
Each file below is intended to be completable + verifiable in a single implementation session.

1. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_01_runtime_types_and_crop.md`
2. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_02_doclayout_adapter_scaffold_config.md`
3. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_03_layout_postprocess.md`
4. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_04_layout_result_formatter.md`
5. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_05_ppdoclayoutv3_detector_load_only.md`
6. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_06_ppdoclayoutv3_detector_inference.md`
7. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_07_glmocr_layout_pipeline_cli_app.md`
8. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_08_ppdoclayoutv3_parity_golden.md`
9. `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_09_layout_output_parity_examples.md`

---

## Overall exit criteria (Phase 04)
- Running `swift run GLMOCRCLI --input <A4_scanned.pdf> --page 1 --layout --emit-json out.json` produces:
  - `stdout`: Markdown with **sane reading order**; when image placeholders exist, the CLI crops them into `imgs/` next to `out.json` and replaces the tags.
  - `out.json`: canonical block-list JSON (`[[{index,label,content,bbox_2d}, ...], ...]`), matching `examples/result/*/*.json`.
  - Use `--emit-ocrdocument-json` for the structured `OCRDocument` schema (pages/regions/bboxes).
- Cancellation works:
  - canceling the task stops region processing quickly (no long hang).
- Conventions respected:
  - `VLMRuntimeKit` remains model-agnostic; PP-DocLayout-V3 code lives outside `GLMOCRAdapter`.

---

## Assumptions / constraints
- PP-DocLayout-V3 model outputs include an `order_seq` (or equivalent) used for reading order; if absent in the chosen snapshot, we fall back to stable `(y1,x1)` sorting and record a diagnostic note.
- Default max layout batch size is 1 (matches official config) to minimize memory spikes on Apple Silicon.

## Parity extension (2026-02-11)
The initial Phase 04 implementation intentionally shipped with an **encoder-only** PP-DocLayout-V3 detector (see `docs/decisions/obsolete_archive/0003-ppdoclayoutv3-encoder-only-inference.md`).

The `examples/` regression indicates this is insufficient for reference-quality layout outputs.
The extension plan adds:
- golden forward-pass parity checks for PP-DocLayout-V3, and
- end-to-end output parity validation vs `examples/result/*`.

Update (2026-02-12): `PPDocLayoutV3Model` now includes a hybrid encoder + deformable decoder implementation, and the opt-in golden tests pass for the tracked baseline snapshot. If drift reappears, start at `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`.
