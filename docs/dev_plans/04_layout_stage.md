# Phase 04 — Layout + region OCR orchestration

**Objective:** quality parity with the “full pipeline” story (layout detection + parallel recognition).

Borrowing references: official GLM-OCR pipeline (`glmocr/pipeline/pipeline.py`) + notes in `docs/reference_projects.md`.

## Implementation plans
- Index: `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan.md`
- Session-sized subplans:
  - `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_01_runtime_types_and_crop.md`
  - `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_02_doclayout_adapter_scaffold_config.md`
  - `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_03_layout_postprocess.md`
  - `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_04_layout_result_formatter.md`
  - `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_05_ppdoclayoutv3_detector_load_only.md`
  - `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_06_ppdoclayoutv3_detector_inference.md`
  - `docs/dev_plans/04_layout_stage/04_layout_stage_impl_plan_07_glmocr_layout_pipeline_cli_app.md`

## Tasks
- [ ] Integrate a layout model stage (likely separate adapter)
  - borrow: region cropping + orchestration patterns from the official GLM-OCR pipeline (`glmocr/pipeline/pipeline.py`)
- [ ] Split pages into regions + run OCR per region
- [ ] Merge outputs (reading order) into Markdown
- [ ] Batch parallelism + cancellation

## Session checklist
- [ ] 04.1 Structured types + `VisionIO.cropRegion` (+ tests)
- [ ] 04.2 `DocLayoutAdapter` scaffold + config/mappings (+ tests)
- [ ] 04.3 Layout postprocess (NMS/merge/ordering) (+ tests)
- [ ] 04.4 `LayoutResultFormatter` (regions → Markdown) (+ tests)
- [ ] 04.5 Detector “load-only” validation (optional integration)
- [ ] 04.6 Detector inference outputs + postprocess wiring (optional integration)
- [ ] 04.7 Orchestration + concurrency + CLI/App wiring (Phase 04 exit criteria)

## Exit criteria
- A4 scanned PDF page produces structured output with sane ordering
