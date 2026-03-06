# Phase 03 - generation and runtime parity

**Goal:** make the OCR generation path explicit, reproducible, and aligned with the repo's chosen parity contract.

**Status (2026-03-05):** planned. Current evidence suggests generation policy still matters, but it should be treated only after geometry-sensitive drift is under control.

---

## 1. Why this phase is needed

The current repo already supports OCR generation, but parity work needs a narrower and more explicit contract than generic generation support.

The project needs to answer:

- which preset generated `examples/result/*`?
- was the run greedy or sampled?
- if sampled, what seed and penalties were used?
- how should parity runs differ from day-to-day ad hoc CLI usage?

Without that, example rebaselines remain difficult to explain.

---

## 2. Scope

### In scope

- repo-owned parity presets
- reusable runtime/sampler plumbing
- support for the minimum knobs actually needed by the chosen parity contract
- reproducible seeded sampling when sampled parity is required
- CLI and script support for explicit parity runs
- integration tests covering the supported parity modes

### Out of scope

- infinite end-user configurability
- speculative generation features with no parity value

---

## 3. Decision points

### Decision A - choose the parity-run preset family

The repo should define a small, named preset family, for example:

- `parity-greedy-v1`
- `parity-sampled-sdk-v1`
- `exploratory-local`

Only the first two should be allowed to generate checked-in parity artifacts.

### Decision B - minimum parameter surface

Expand the generation/runtime surface only as needed for the chosen presets. Likely candidates include:

- `temperature`
- `topP`
- `topK`
- `repetitionPenalty`
- deterministic `seed`
- `maxNewTokens`

If a parameter is not part of a checked-in preset or a known debugging workflow, it should not be promoted casually.

---

## 4. Implementation workstreams

## Workstream A - preset definition

Tasks:

1. define the supported parity presets in one place
2. document what each preset is for
3. record the preset name in example-eval metadata

## Workstream B - runtime plumbing

Tasks:

1. extend `Sources/VLMRuntimeKit/OCRTypes.swift` to represent the needed generation knobs cleanly
2. keep policy out of individual model-adapter call sites where possible
3. make `Sources/VLMRuntimeKit/Generation/Generation.swift` host reusable behavior rather than one-off parity logic

## Workstream C - CLI and scripts

Tasks:

1. add explicit parity-preset selection to `GLMOCRCLI`
2. thread the chosen preset through `scripts/run_examples.sh` and report generation
3. keep default UX quiet for normal usage while making parity runs self-describing

## Workstream D - tests

Add tests that distinguish:

- greedy parity preset behavior
- sampled preset reproducibility with fixed seed
- serialization/recording of preset metadata in score artifacts

---

## 5. Acceptance examples

This phase should be evaluated primarily on:

- `code`
- `page`
- `paper`
- one GLM-4.5V PDF example

These examples are sensitive enough to reveal whether the chosen preset meaningfully improves parity without letting the repo hide behind easy cases.

---

## 6. Exit criteria

This phase is complete when:

- every checked-in parity artifact can name the preset that produced it
- the repo supports the minimum generation knobs needed by that preset family
- parity runs are reproducible
- generation-policy differences are no longer implicit or guessed from code history
