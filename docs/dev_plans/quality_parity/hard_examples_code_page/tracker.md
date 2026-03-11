# Tracker - hard examples `code` / `page`

**Objective:** close the remaining `code` / `page` quality gap with the smallest truthful set of runtime and formatting changes.

**Status (2026-03-11):** ready to execute. The investigation has enough evidence to prioritize runtime/preprocessing parity before any new layout-geometry work.

---

## 0. Problem statement

The current checked-in quality gap is concentrated in hard examples:

- `code`: main `0.7744` vs peer `0.9457`
- `page`: still materially behind the desired contract and likely affected by similar dense-layout sensitivity

The repo already completed the broader parity program, so this tracker is intentionally narrow.

---

## 1. Ranked hypotheses

### H1 — default vision-input dtype is wrong for normal runtime use
**Priority:** highest
**Confidence:** medium-high

Current maintained behavior:
- image preprocessing defaults to `.bfloat16`
- dtype alignment to the loaded vision weights is env-gated instead of default runtime behavior

Expected risk:
- blurry/small-text crops lose more signal than cleaner examples
- `code` and `page` are more sensitive than `table` or `seal`

### H2 — the default Core Image resize path is too soft for these hard crops
**Priority:** high
**Confidence:** medium-high

Current maintained behavior:
- default resize backend is `CoreImage` bicubic
- deterministic CPU bicubic exists but is not the default

Expected risk:
- thin glyph strokes get softened before normalization
- short-height line regions are especially exposed

### H3 — `algorithm` blocks need explicit formatting normalization
**Priority:** medium
**Confidence:** high

Current maintained behavior:
- missing algorithm-specific code-fence normalization compared with the peer port

Expected risk:
- user-visible structure remains worse than necessary even after OCR improves
- evaluator structure/style dimensions stay artificially suppressed

### H4 — some residual crop/layout issues still contribute
**Priority:** medium-low for first pass
**Confidence:** medium

Treat this as a follow-up branch, not the starting point.

---

## 2. Recommended execution order

## Workstream A — make vision-input dtype alignment the default runtime behavior

### Tasks
- [ ] Change the normal GLM-OCR runtime path so image tensors align to `model.visionInputDType` by default, not only in env-gated parity lanes.
- [ ] Preserve an explicit override for debugging alternate dtypes when needed.
- [ ] Add a focused regression test covering the default alignment behavior.
- [ ] Record the runtime decision in `README.md` and/or `docs/architecture.md` if the default user-facing behavior changes.

### Acceptance
- [ ] Default runtime no longer silently feeds BF16 image tensors into a non-BF16 vision path.
- [ ] `swift test` remains green.
- [ ] Hard-example eval can be rerun without special env flags for dtype parity.

## Workstream B — run a resize-backend A/B investigation with artifact capture

### Tasks
- [ ] Add a narrow debug harness that can dump, for selected regions/examples:
  - crop bbox metadata
  - crop pixel size
  - target resize size
  - resized RGB artifact
  - image tensor dtype / min / max / mean summary
- [ ] Compare `coreImageBicubic` vs `deterministicBicubicCPU` on:
  - `code`
  - `page`
  - at least one stable counterexample such as `table`
- [ ] Decide whether the deterministic backend should become:
  - the global default,
  - the parity/example default only,
  - or an adaptive default for small-text hard cases.

### Acceptance
- [ ] One written backend decision exists.
- [ ] The decision is supported by recorded artifacts, not just by intuition.
- [ ] Any default change is documented and covered by a regression test.

## Workstream C — close the algorithm/code formatting gap

### Tasks
- [ ] Port the peer repo's `algorithm` code-block normalization into the maintained formatter, adapted to local naming/layout types.
- [ ] Add focused tests for:
  - XML-like code block fence normalization
  - no accidental rewrite of real HTML content
- [ ] Re-evaluate the `code` example after the runtime changes, so formatting-only improvements are not mistaken for OCR fixes.

### Acceptance
- [ ] `algorithm` blocks preserve code structure more faithfully.
- [ ] Formatter changes are isolated and regression-tested.

## Workstream D — only if still needed, revisit crop/layout contributors

### Tasks
- [ ] Recheck the `code` / `page` region boxes after Workstreams A-C land.
- [ ] If the residual gap remains large, inspect:
  - bbox drift near tiny line crops
  - class-to-task mapping for algorithm-like regions
  - crop masking / bbox-only policy for relevant labels
- [ ] Avoid reopening broad layout phases unless new evidence requires it.

### Acceptance
- [ ] Any remaining layout work is justified by post-A/B evidence, not by first-suspicion bias.

---

## 3. Delivery options

### Option M — minimal, lowest-risk correction
- default-on vision dtype alignment
- algorithm/code formatting normalization
- keep Core Image as default for now

**Use when:** the goal is fast correction with minimal runtime policy change.

### Option B — balanced, recommended
- default-on vision dtype alignment
- resize-backend A/B harness
- switch to deterministic CPU bicubic where the evidence justifies it
- algorithm/code formatting normalization

**Use when:** the goal is to close most of the `code` gap without reopening architecture or building a large fixture system.

### Option F — full parity instrumentation
- everything in Option B
- plus crop-level golden/reference fixture capture for the hard examples
- plus deeper post-A/B layout/crop probes

**Use when:** Option B materially improves the scores but still leaves an unexplained residual gap.

**Recommended current path:** Option B.

---

## 4. Acceptance criteria for this tracker

This focused tracker can be considered successful when all of the following are true:

- [ ] `code` improves materially from the current baseline without a compensating regression on the protected subset.
- [ ] The repo has a documented default policy for vision-input dtype alignment.
- [ ] The repo has a documented default policy for the resize backend used in parity-sensitive OCR.
- [ ] Any accepted example rebaseline refreshes `examples/result/*` and `examples/eval_records/latest/*` together.

A reasonable first-pass target is:

- recover at least **0.10** on `code` final overall
- keep `table` and the protected subset effectively stable
- avoid unexplained regressions on `page`

---

## 5. Risks

- **Performance-risk tradeoff:** deterministic CPU resize may improve hard-example quality while costing throughput.
- **False win risk:** formatting fixes can raise some dimensions without fixing OCR content.
- **Overfitting risk:** tuning specifically for `code` must be checked against `page`, `paper`, and `table`.
- **Premature rebaseline risk:** do not refresh checked-in artifacts until the default-policy decision is explicit.

---

## 6. Immediate next patch set

1. Make vision-input dtype alignment default-on in the normal runtime path.
2. Add the hard-example preprocess artifact dump harness.
3. Port algorithm/code fence normalization.
4. Rerun `scripts/verify_example_eval.sh`.
5. Decide whether the deterministic resize backend should become the default for this repo's GLM-OCR path.
