# Implementation plan - faithful parity program (completed)

**Status (2026-03-11):** completed. This file is retained as a summary of the finished five-phase parity program. For current priorities, use `tracker.md`.

## Program Outcome

The repo finished the structural parity work that was previously open:

- the parity target is written down and reproducible
- layout crop/order behavior is regression-tested
- mask-derived polygons flow through layout export with explicit fallback rules
- generation presets are explicit and recorded in example artifacts
- markdown/JSON/example artifact refresh rules are documented and tied to scored evaluation

## Completed Phase Summary

- Phase 00 - reference contract + reproducibility
  - pinned the parity contract and recorded it in scripts and eval artifacts
- Phase 01 - layout/crop/order alignment
  - stabilized bbox math, filtering, ordering, and page-image reuse
- Phase 02 - polygon/mask geometry parity
  - added mask-derived polygon plumbing plus the current table-vs-formula crop policy
- Phase 03 - generation/runtime parity
  - made `default-greedy-v1` and `parity-greedy-v1` explicit runtime inputs
- Phase 04 - formatting/export parity + golden policy + CI
  - documented output semantics, artifact ownership, and the low-flake protected subset

## Why The Phase Order Still Matters

- Geometry work had to land before decode-policy tuning, otherwise generation changes would hide crop/order defects.
- Formatting and export behavior had to be treated as part of the parity contract, not as cleanup.
- Reproducibility metadata had to be recorded before rebaselining example artifacts.

## What Remains Open

- incremental score improvements on the hard examples tracked in `tracker.md`
- continued artifact hygiene through `examples/README.md` and `examples/eval_records/README.md`
- app/export/distribution work, tracked separately in `docs/dev_plans/gui_polish_distribution/tracker.md`

## Use This Doc For

- a concise summary of why the parity program was sequenced the way it was
- linking to the completed phase notes when you need historical implementation context

Use `tracker.md`, `README.md`, and `docs/architecture.md` for the live repo state.
