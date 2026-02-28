# Quality parity plan index

**Objective:** turn the current structural parity recovery into a complete, repeatable path to layout-mode parity and then lock that behavior into the repo's validation workflow.

**Status (2026-02-27):** active. Structural parity blockers have been fixed. The remaining work is concentrated in crop semantics, polygon/mask parity, decoding-policy alignment, and then thresholded enforcement.

---

## What changed the status of this work

The layout parity investigation in `docs/debug_notes/layout_parity/layout_parity_analysis.md` identified and validated two primary structural fixes:

- formula regions were previously dropped because the HF layout snapshot emits `"formula"`, while the Swift mapping only recognized `display_formula` / `inline_formula`
- block-list JSON export collapsed `table` and `formula` back to `text`

Those are now treated as complete. The remaining work is smaller in scope but higher in implementation detail.

---

## Phase map

| Phase | Focus | Primary outcome |
|---|---|---|
| Phase 01 | Crop + ordering alignment | Match upstream bbox normalization, crop pixel bounds, and missing layout heuristics closely enough that structural parity is stable without hand-waving |
| Phase 02 | Polygon + mask support | Use `out_masks` to generate polygon crops instead of bbox-only crops, reducing contamination in formulas/tables |
| Phase 03 | Generation alignment | Make decoding policy explicit and reproducible, then align the parity profile to the intended upstream reference path |
| Phase 04 | Thresholds + coverage + CI policy | Convert report-only diffs into stable, opt-in checks for representative PDFs and PNG examples |

---

## Documents in this folder

- `tracker.md`
  - live status, ordered backlog, and exit criteria
- `implementation_plan.md`
  - master plan tying parity and quality lanes together
- `phase_01_crop_order_alignment.md`
  - detailed plan for bbox, crop rounding, and missing layout heuristics
- `phase_02_polygon_mask_support.md`
  - detailed plan for `out_masks` plumbing and polygon extraction strategy
- `phase_03_generation_alignment.md`
  - detailed plan for decoding policy, sampler plumbing, and parity target selection
- `phase_04_thresholds_coverage_ci.md`
  - detailed plan for turning the diff harness into enforced, low-flake checks

---

## Recommended execution order

1. Complete Phase 01 first.
   - It is the cheapest remaining work.
   - It also gives a cleaner signal when evaluating whether Phase 02 is truly needed for a given example.

2. Start Phase 02 immediately after Phase 01 lands.
   - Formula-heavy examples are likely still paying a contamination penalty from bbox-only crops.
   - This is the highest-value remaining parity investment.

3. Resolve Phase 03 only after Phase 01 and Phase 02 produce stable crops.
   - Otherwise token-level drift mixes crop defects with decoder-policy defects.

4. Use Phase 04 to lock in the subset that becomes stable.
   - Do not wait for the entire corpus to become perfect before adding gating.

---

## Design rule for Python-infrastructure gaps

When the upstream Python path depends on framework behavior that is not already mirrored in Swift, do not immediately assume a from-scratch port.

Use this preference order:

1. existing Apple-native primitives already present in the repo or platform SDKs
2. established Swift/MLX patterns already surveyed in `docs/reference_projects.md`
3. a small local implementation only when the first two do not preserve the needed semantics
4. external heavy dependencies only as a validation aid or last resort, not as the default shipping path

That rule is applied explicitly in the Phase 02 and Phase 03 plans.
