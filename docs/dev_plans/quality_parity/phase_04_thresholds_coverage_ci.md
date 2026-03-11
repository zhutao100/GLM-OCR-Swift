# Phase 04 - formatting/export parity, golden policy, thresholds, and CI

**Goal:** turn improved runtime parity into stable, user-visible checked-in artifacts and protect the stable subset with low-flake automation.

**Status (2026-03-06):** completed. The repo now documents the maintained output contract, artifact ownership, and rebaseline rules explicitly. The protected subset is intentionally narrow: `GLM-4.5V_Page_1` (PDF) and `table` (PNG) are covered by opt-in parity integration tests, while the rest of the corpus stays on the broader report-only `scripts/verify_example_eval.sh` lane.

---

## 1. Why this phase is broader than CI

Parity is not only about OCR text. It is also about the exported structure the user sees and the rules the repo follows when checked-in artifacts change.

The maintained contract now covers:

- markdown ordering and image placeholder semantics
- block-list JSON stability and label preservation
- ownership of `reference_result`, `golden_result`, `result`, and `eval_records`
- when a change is a bug fix versus a rebaseline
- which examples are protected directly versus left in exploratory report-only coverage

---

## 2. Delivered outputs

### Output-format parity audit

The short output contract matrix now lives in `examples/README.md`. It distinguishes:

- guaranteed behaviors (`result` JSON key order, semantic labels, markdown ordering)
- repo-owned behaviors (image placeholder replacement and crop filenames)
- best-effort behaviors (`OCRDocument` polygon recording)

### Artifact ownership and rebaseline policy

Artifact-family purpose and update policy are now documented in:

- `examples/README.md`
- `examples/eval_records/README.md`

These docs define when each artifact family may change and require `examples/result/*` updates to travel with matching `examples/eval_records/latest/*` evidence.

### Protected subset

The protected subset is intentionally small:

- PDF: `GLM-4.5V_Page_1`
- PNG: `table`

Both are covered by `GLMOCR_RUN_EXAMPLES=1 swift test --filter LayoutExamplesParityIntegrationTests`. The three-page PDF remains available in the same opt-in lane, but it is treated as broader exploratory coverage rather than the minimum enforced subset.

### Low-flake enforcement posture

The maintained parity posture is now:

1. `swift test` for cheap deterministic coverage
2. `GLMOCR_RUN_EXAMPLES=1 swift test --filter LayoutExamplesParityIntegrationTests` for the protected subset
3. `scripts/verify_example_eval.sh` for broad report-only evaluation and score deltas

The repo now also has a checked-in CI workflow for the cheap default lane: pull requests run `swift test`, and pushes to `main` additionally validate the nightly CLI packaging path. The heavier parity lanes remain opt-in/manual because they depend on cached snapshots and are intentionally not part of the default CI contract.

---

## 3. Acceptance criteria

This phase is complete when:

- output-format semantics that affect checked-in examples are documented
- example artifact ownership and rebaseline rules are written down
- at least one PDF and one PNG example are protected by parity integration checks
- report-only exploratory coverage still exists for the rest of the corpus
- the low-flake enforcement posture is documented
