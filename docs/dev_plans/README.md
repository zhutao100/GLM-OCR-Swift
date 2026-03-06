# Development Plans

**Status (2026-03-06):** active. Current work is tracked through focused topic trackers. Completed implementation plans and older trackers live under `docs/dev_plans/archive/`.

## Priority Order

1. Quality/parity validation
2. GUI polish and distribution after the quality backlog is under control

## Active Trackers

- Quality/parity validation
  - `docs/dev_plans/quality_parity/tracker.md`
  - supporting phase docs: `docs/dev_plans/quality_parity/README.md`

- GUI polish and distribution
  - `docs/dev_plans/gui_polish_distribution/tracker.md`

## Supporting References

- `docs/golden_checks.md`
  - opt-in parity, golden, and model-backed integration workflow

- `examples/eval_records/README.md`
  - how the scored evaluation record is refreshed and compared

## Archived Work

- Early implementation phases
  - `docs/dev_plans/archive/README.md`

- Multi-page PDF support
  - `docs/dev_plans/archive/multi_page_pdf/tracker.md`

- Preprocessing and fusion primitives port
  - `docs/dev_plans/archive/preprocessing_and_fusion_primitives_port/tracker.md`

## Rules For New Plan Docs

- Use a dedicated folder with a `tracker.md` for work that spans multiple sessions.
- Keep each tracker truthful: update status, completed tasks, and descoped work when reality changes.
- Put current behavior in `README.md`, `docs/overview.md`, and `docs/architecture.md`, not in archived plan docs.
- When you touch archived material, fix dead links and obvious inaccuracies, but keep it clearly historical.
