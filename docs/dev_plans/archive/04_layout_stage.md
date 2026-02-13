# Phase 04 — Layout + region OCR orchestration

**Objective:** quality parity with the “full pipeline” story (layout detection + parallel recognition).

Borrowing references: official GLM-OCR pipeline (`glmocr/pipeline/pipeline.py`) + notes in `docs/reference_projects.md`.

**Status (2026-02-12):** complete — layout mode is implemented (single-page) and examples parity + opt-in PP-DocLayout-V3 golden baselines pass.

## Implementation plans
- Index: `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan.md`
- Session-sized subplans:
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_01_runtime_types_and_crop.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_02_doclayout_adapter_scaffold_config.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_03_layout_postprocess.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_04_layout_result_formatter.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_05_ppdoclayoutv3_detector_load_only.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_06_ppdoclayoutv3_detector_inference.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_07_glmocr_layout_pipeline_cli_app.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_08_ppdoclayoutv3_parity_golden.md`
  - `docs/dev_plans/archive/04_layout_stage/04_layout_stage_impl_plan_09_layout_output_parity_examples.md`

## Tasks
- [x] Integrate a layout model stage (likely separate adapter)
  - borrow: region cropping + orchestration patterns from the official GLM-OCR pipeline (`glmocr/pipeline/pipeline.py`)
- [x] Split pages into regions + run OCR per region
- [x] Merge outputs (reading order) into Markdown
- [x] Batch parallelism + cancellation

## Session checklist
- [x] 04.1 Structured types + `VisionIO.cropRegion` (+ tests)
- [x] 04.2 `DocLayoutAdapter` scaffold + config/mappings (+ tests)
- [x] 04.3 Layout postprocess (NMS/merge/ordering) (+ tests)
- [x] 04.4 `LayoutResultFormatter` (regions → Markdown) (+ tests)
- [x] 04.5 Detector “load-only” validation (optional integration)
- [x] 04.6 Detector inference outputs + postprocess wiring (optional integration)
- [x] 04.7 Orchestration + concurrency + CLI/App wiring (Phase 04 exit criteria)
- [x] 04.8 PP-DocLayout-V3 parity (golden fixtures + regression guard; see `docs/golden_checks.md`)
- [x] 04.9 End-to-end parity vs `examples/` (Markdown + JSON expectations)

## Exit criteria
- `--layout` on `examples/source/*` produces output that matches (or intentionally supersedes) `examples/reference_result/*`
- PP-DocLayout-V3 golden forward check passes (opt-in; see `docs/golden_checks.md` and `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`)
