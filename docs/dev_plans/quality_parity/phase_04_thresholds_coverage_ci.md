# Phase 04 - thresholds, coverage, and CI policy

**Objective:** convert the current report-only quality/parity tooling into a stable enforcement layer for the subset of examples that has become trustworthy.

**Status (2026-02-27):** planned.

---

## 1. Why this phase matters

The repo already has strong ingredients:

- reproducible example generation
- a dual-lane diff harness (`parity` and `quality`)
- opt-in end-to-end PDF parity tests

What it lacks is a low-friction way to say:

- these examples are now stable enough to fail on regression
- these other examples are still exploratory and should remain report-only

This phase supplies that policy layer.

---

## 2. Recommended gating model

Do not gate everything at once.

Use three buckets:

### Bucket A - enforced

Examples with stable parity/quality behavior.

For these, the harness may fail on configured conditions such as:

- missing artifacts
- markdown diff
- JSON structural diff
- image mismatch policy

### Bucket B - monitored

Examples that still produce useful reports but are not stable enough to fail CI.

### Bucket C - exploratory

Examples under active debugging where only manual review is expected.

This bucketed approach avoids penalizing ongoing parity work.

---

## 3. Concrete tasks

### Workstream A - coverage gaps

1. add `examples/golden_result/GLM-4.5V_Page_1/`
2. add or extend `examples/reference_result_notes/*` where upstream artifacts are known to be noisy
3. choose one representative PNG example and one representative PDF example as the first enforced set

### Workstream B - threshold expression

1. extend `scripts/compare_examples.py` so per-example policy can be configured cleanly
2. keep report generation intact even when some examples are enforced
3. record threshold rationale in docs, not only in code

### Workstream C - test-suite expansion

1. keep the current PDF parity integration tests
2. add representative PNG parity integration tests once Phase 01 and Phase 02 settle
3. avoid making default `swift test` expensive; stay env-gated or filter-based

### Workstream D - CI posture

Recommended order:

1. local report-only by default
2. opt-in enforced subset in CI
3. expand the enforced set gradually as examples stabilize

---

## 4. Suggested first enforced examples

Use examples with strong signal and low ambiguity.

### Candidate PDF

- `GLM-4.5V_Page_1`

Why:

- already has reference artifacts
- single-page scope is easier to reason about than the 3-page PDF

### Candidate PNG

- `table` or `seal`

Why:

- structurally simple
- easier to detect whether a regression is caused by layout logic or OCR content noise

Do not start with `paper` as the first enforced PNG if Phase 02 is still in motion.

---

## 5. Acceptance criteria

This phase is done when:

- at least one PDF and one PNG example are enforced by documented policy
- the rest of the corpus can still be compared in report-only mode
- CI guidance is written down and does not require guessing which examples are expected to fail
