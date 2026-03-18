# Development Plans

**Status (2026-03-11):** maintained. The repo no longer has a large open implementation program; current roadmap work is intentionally narrow and tracked through focused documents.

## Priority Order

1. Hard-example quality triage for `code`, `page`, and related dense mixed-layout cases
2. Incremental quality/parity maintenance on the accepted artifact contract
3. App polish, export UX, and distribution when product focus returns

## Maintained Trackers

- Quality/parity maintenance
  - `docs/dev_plans/quality_parity/tracker.md`
  - `docs/dev_plans/quality_parity/README.md`
  - use these for the live backlog, baseline score snapshot, and parity-contract rules

- Focused hard-example investigation
  - `docs/dev_plans/quality_parity/hard_examples_code_page/README.md`
  - `docs/dev_plans/quality_parity/hard_examples_code_page/tracker.md`
  - use these when touching GLM-OCR preprocessing/runtime parity for the current `code` and `page` deficits

- Gateway preprocessing experiments for degraded inputs
  - `docs/dev_plans/quality_parity/gateway_preprocessing/README.md`
  - `docs/dev_plans/quality_parity/gateway_preprocessing/tracker.md`
  - use these when evaluating deterministic page/crop cleanup before GLM-OCR / PP-DocLayout-V3 inference

- GUI polish and distribution
  - `docs/dev_plans/gui_polish_distribution/tracker.md`
  - currently deferred, but kept current as the next product-facing backlog

## Supporting References

- `docs/golden_checks.md`
  - opt-in parity, golden, and model-backed integration workflow
- `examples/README.md`
  - output contract and artifact ownership
- `examples/eval_records/README.md`
  - scored evaluation record refresh policy
- `tools/example_eval/README.md`
  - evaluator usage and outputs

## Historical Material

- `docs/dev_plans/archive/README.md`
  - early implementation phases and archived trackers
- phase docs under `docs/dev_plans/quality_parity/`
  - completed parity-program rationale and implementation notes

## Rules For New Plan Docs

- Use a dedicated folder with a `tracker.md` for work that spans multiple sessions.
- Keep each tracker truthful: update status, completed tasks, and descoped work when reality changes.
- Put current behavior in `README.md`, `docs/overview.md`, and `docs/architecture.md`, not in historical plan docs.
- When a phase is complete but still useful for rationale, keep it clearly marked as completed or historical.
- When you touch archived material, fix dead links and obvious inaccuracies, but keep it clearly historical.
