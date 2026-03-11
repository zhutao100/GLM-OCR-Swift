# Tracker - hard examples `code` / `page`

**Objective:** close the remaining `code` / `page` quality gap with the smallest truthful set of runtime and formatting changes.

**Status (2026-03-11):** executed and landed. Workstreams A-C are complete. The accepted first-pass result is `code` `0.9016` (`+0.1272`), `page` `0.7438` (stable), and `table` `0.9944` (stable).

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
**Confidence:** resolved for the current parity snapshot

Current maintained behavior:
- runtime image tensors now align to `model.visionInputDType` by default
- `GLMOCR_ALIGN_VISION_DTYPE=0` and `GLMOCR_VISION_INPUT_DTYPE=...` remain available as explicit debug overrides

Execution note:
- on the pinned parity snapshot, `model.visionInputDType == .bfloat16`
- this change fixes a silent correctness hazard for non-BF16 snapshots, but it did not move the checked-in hard examples by itself

### H2 — the default Core Image resize path is too soft for these hard crops
**Priority:** high
**Confidence:** confirmed, but only for a narrow crop class

Current maintained behavior:
- Core Image bicubic remains the general default
- layout OCR now switches short, wide text-line crops to deterministic CPU bicubic
- `GLMOCR_PREPROCESS_BACKEND=coreimage|deterministic` still forces a backend globally for debugging

Execution note:
- full deterministic switching improved `code` to `0.8988` but regressed `page` to `0.7046`
- the accepted adaptive policy recovered `code` to `0.9016` while keeping `page` and `table` stable
- crop manifests under `.build/hard_example_probes/*` showed the improvement concentrated in very wide, short line crops from `code`

### H3 — `algorithm` blocks need explicit formatting normalization
**Priority:** medium
**Confidence:** high

Current maintained behavior:
- algorithm-specific code-fence normalization is now present in the maintained formatter

Execution note:
- XML-like algorithm blocks now normalize from ` ```html ` to ` ```xml `
- real HTML content is preserved

### H4 — some residual crop/layout issues still contribute
**Priority:** medium-low for first pass
**Confidence:** medium

Treat this as a follow-up branch, not the starting point.

---

## 2. Recommended execution order

## Workstream A — make vision-input dtype alignment the default runtime behavior

### Tasks
- [x] Change the normal GLM-OCR runtime path so image tensors align to `model.visionInputDType` by default, not only in env-gated parity lanes.
- [x] Preserve an explicit override for debugging alternate dtypes when needed.
- [x] Add a focused regression test covering the default alignment behavior.
- [x] Record the runtime decision in `README.md` and/or `docs/architecture.md` if the default user-facing behavior changes.

### Acceptance
- [x] Default runtime no longer silently feeds BF16 image tensors into a non-BF16 vision path.
- [x] `swift test` remains green.
- [x] Hard-example eval can be rerun without special env flags for dtype parity.

## Workstream B — run a resize-backend A/B investigation with artifact capture

### Tasks
- [x] Add a narrow debug harness that can dump, for selected regions/examples:
  - crop bbox metadata
  - crop pixel size
  - target resize size
  - resized RGB artifact
  - image tensor dtype / min / max / mean summary
- [x] Compare `coreImageBicubic` vs `deterministicBicubicCPU` on:
  - `code`
  - `page`
  - at least one stable counterexample such as `table`
- [x] Decide whether the deterministic backend should become:
  - the global default,
  - the parity/example default only,
  - or an adaptive default for small-text hard cases.

**Accepted backend decision (2026-03-11):** use an adaptive default for short, wide layout text-line crops; do not flip the entire OCR path to deterministic CPU bicubic.

### Acceptance
- [x] One written backend decision exists.
- [x] The decision is supported by recorded artifacts, not just by intuition.
- [x] Any default change is documented and covered by a regression test.

## Workstream C — close the algorithm/code formatting gap

### Tasks
- [x] Port the peer repo's `algorithm` code-block normalization into the maintained formatter, adapted to local naming/layout types.
- [x] Add focused tests for:
  - XML-like code block fence normalization
  - no accidental rewrite of real HTML content
- [x] Re-evaluate the `code` example after the runtime changes, so formatting-only improvements are not mistaken for OCR fixes.

### Acceptance
- [x] `algorithm` blocks preserve code structure more faithfully.
- [x] Formatter changes are isolated and regression-tested.

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

- [x] `code` improves materially from the current baseline without a compensating regression on the protected subset.
- [x] The repo has a documented default policy for vision-input dtype alignment.
- [x] The repo has a documented default policy for the resize backend used in parity-sensitive OCR.
- [x] Any accepted example rebaseline refreshes `examples/result/*` and `examples/eval_records/latest/*` together.

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

1. Default-on vision-input dtype alignment landed, with explicit debug overrides.
2. `GLMOCRPreprocessDebugCLI` now captures crop metadata, resized artifacts, timings, and tensor summaries.
3. Algorithm/code fence normalization landed with focused formatter tests.
4. `scripts/verify_example_eval.sh` refreshed `examples/result/*` and `examples/eval_records/latest/*`.
5. The accepted resize policy is adaptive, not a global deterministic flip.
