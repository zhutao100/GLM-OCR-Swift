# Phase 04.8 — PP-DocLayout-V3 parity (golden fixtures + regression guard)

## Status
Complete (2026-02-12).

Baseline snapshot (tracked by fixtures and debug notes):
- `a0abee1e2bb505e5662993235af873a5d89851e3`

## Purpose
Keep the Swift `DocLayoutAdapter` PP-DocLayout-V3 port numerically aligned with the Python/Transformers reference for a pinned snapshot, and prevent regressions.

## Source of truth
- Golden workflow + env vars: `docs/golden_checks.md`
- Fixture generation commands: `Tests/DocLayoutAdapterTests/Fixtures/README.md`
- Drift debugging playbook + postmortems: `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`

## Exit criteria (parity-maintenance)
- `PPDocLayoutV3GoldenIntegrationTests` and `PPDocLayoutV3GoldenFloat32IntegrationTests` pass when `LAYOUT_RUN_GOLDEN=1` and `LAYOUT_SNAPSHOT_PATH` points at the baseline snapshot.
- `PPDocLayoutV3IntermediateParityIntegrationTests` passes for the v3/v4 intermediate fixtures.
