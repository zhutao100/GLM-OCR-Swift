# Quality parity program index

**Objective:** keep the repo's parity contract reproducible and keep incremental quality work focused on the examples that still benefit from it.

**Status (2026-03-11):** maintenance mode. The five-phase parity program is complete. This folder now serves as a maintenance index plus a record of how the contract was established.

## What Is Still Active

- Improve the hard examples that still trail the desired contract, especially `code`, `page`, and dense mixed-layout/formula pages.
- Keep `examples/result/*` and `examples/eval_records/latest/*` refreshed together when the accepted baseline changes.
- Preserve the pinned parity contract from `scripts/lib/_parity_defaults.sh`.
- Keep the stable subset protected by opt-in tests while the broader corpus stays on the report-only evaluation lane.
- Use the focused hard-example tracker for the current preprocessing/runtime investigation:
  - `hard_examples_code_page/README.md`
  - `hard_examples_code_page/tracker.md`

## Where Current Behavior Lives

- `tracker.md`
  - live baseline score snapshot, maintenance backlog, and reproducibility policy
- `hard_examples_code_page/tracker.md`
  - current ranked hypotheses, workstreams, and acceptance criteria for the `code` / `page` gap
- `docs/golden_checks.md`
  - opt-in test lanes, snapshot overrides, and fixture-generation workflow
- `examples/README.md`
  - output contract and artifact ownership
- `examples/eval_records/README.md`
  - scored-eval record refresh policy
- `README.md` and `docs/architecture.md`
  - current user-facing behavior and runtime shape

## Folder Map

- `tracker.md`
  - live status, ordered maintenance backlog, and baseline scores
- `hard_examples_code_page/README.md`
  - investigation summary for the `code` / `page` gap and the current evidence-based hypothesis ranking
- `hard_examples_code_page/tracker.md`
  - implementation tracker for the focused hard-example work
- `implementation_plan.md`
  - completed-program summary and why the phase order mattered
- `phase_00_reference_contract.md`
  - reference target, pinned revisions, and reproducibility rules
- `phase_01_crop_order_alignment.md`
  - bbox math, crop rounding, filtering, ordering, and page/crop reuse
- `phase_02_polygon_mask_support.md`
  - mask plumbing, contour extraction, polygon export, and crop policy
- `phase_03_generation_alignment.md`
  - generation presets and explicit parity-run decode policy
- `phase_04_thresholds_coverage_ci.md`
  - formatting/export contract, example regeneration policy, and low-flake CI posture

## How To Use This Folder

- Start with `tracker.md` when touching parity-sensitive code or example artifacts.
- Move to `hard_examples_code_page/tracker.md` when the change is specifically about the `code` or `page` quality gap.
- Use the phase docs only when you need historical reasoning, acceptance criteria, or implementation detail for a completed phase.
- Do not treat the phase docs as a forward roadmap; the current roadmap is incremental maintenance, not another multi-phase reset.

## Maintenance Rules

1. Preserve reproducibility.
   - Checked-in example runs should always record the GLM snapshot, layout snapshot, and generation preset.

2. Treat export-format changes as contract changes.
   - Markdown, block-list JSON, and `OCRDocument` changes affect both user-visible behavior and parity evidence.

3. Prefer narrow fixes over new infrastructure.
   - The current gaps are mostly hard-example quality, not missing architecture.

4. Keep the protected subset small and stable.
   - Use `GLMOCR_RUN_EXAMPLES=1 swift test --filter LayoutExamplesParityIntegrationTests` for the stable lane.
   - Use `scripts/verify_example_eval.sh` for broader report-only evaluation.
