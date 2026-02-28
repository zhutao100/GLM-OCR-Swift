# Phase 03 - generation alignment

**Objective:** make decoding policy an explicit, reusable part of the repo so parity claims are reproducible and not conflated with crop or detector defects.

**Status (2026-02-27):** planned.

---

## 1. Why this phase is third, not first

The current output drift is a mixture of geometry effects and decode-policy effects. If decoding is tuned before crops are aligned, the project risks fitting sampler behavior to compensate for bad crops.

That is why this phase starts only after Phase 01 and Phase 02 make the visual inputs more faithful.

---

## 2. The parity-contract ambiguity that must be resolved first

The upstream ecosystem exposes more than one plausible default decode policy:

- the SDK code path has page-loader defaults in Python config types
- the SDK YAML sample shows a different, more sampling-heavy profile
- the Hugging Face `generation_config.json` for the model indicates a direct-model profile

Until the repo chooses one of these as the parity target, "generation alignment" is underspecified.

---

## 3. Decision required at the start of the phase

Choose and document one of the following as the parity contract for `examples/reference_result/*` regeneration and comparison.

### Option A - direct model parity

Use the HF model's direct generation behavior as the primary contract.

**Pros**

- closest to the model snapshot itself
- simpler to reason about for local inference

**Cons**

- may not match the official SDK path that produced the published examples

### Option B - SDK pipeline parity

Use the official GLM-OCR SDK request-building path as the contract.

**Pros**

- most likely to align with published end-to-end examples
- matches the full document-parsing workflow more closely

**Cons**

- depends on clarifying which SDK defaults are actually authoritative

### Option C - repo-owned explicit parity profile

Define a named parity profile in this repo and record exactly which knobs it sets.

**Pros**

- fully reproducible
- avoids ambiguity once documented

**Cons**

- must be carefully justified if it diverges from upstream defaults

**Recommendation:** use Option B if the example provenance clearly comes from the SDK pipeline; otherwise use Option C and document the evidence for each chosen knob.

---

## 4. Implementation shape in Swift

Do not keep growing `GLMOCRModel.generate(...)` as a one-off decode loop.

### Recommended architecture

1. expand `GenerateOptions` so it can represent the required knobs
2. add a sampler abstraction in `VLMRuntimeKit/Generation`
3. keep `GLMOCRModel.generate(...)` focused on model-specific token/logit production
4. let the generation layer own:
   - greedy selection
   - temperature scaling
   - top-p filtering
   - top-k filtering
   - repetition penalty
   - deterministic seeded sampling for experiments

This follows the same general reuse direction already reflected in `docs/reference_projects.md`.

---

## 5. Concrete implementation tasks

### Workstream A - define the public generation surface

**Files**

- `Sources/VLMRuntimeKit/OCRTypes.swift`
- `Sources/VLMRuntimeKit/Generation/*`

**Tasks**

1. expand `GenerateOptions` with the knobs needed for parity work
2. define defaults explicitly rather than relying on scattered call-site literals
3. add a named decode policy/profile concept if needed

### Workstream B - sampler implementation

**Files**

- `Sources/VLMRuntimeKit/Generation/*`
- `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`

**Tasks**

1. keep greedy mode as the simplest code path
2. add sampling support with deterministic seeding
3. add repetition penalty support before sampling selection
4. ensure stop-token behavior stays identical across greedy and sampled modes

### Workstream C - CLI and app plumbing

**Files**

- `Sources/GLMOCRCLI/GLMOCRCLI.swift`
- `Sources/GLMOCRApp/ContentView.swift`

**Tasks**

1. expose parity-relevant controls without overloading the default UX
2. keep default CLI behavior obvious and reproducible
3. make it clear in output diagnostics which decode policy/profile was used

---

## 6. Tests to add

### Unit tests

- temperature 0 or greedy path remains deterministic
- top-k filtering excludes lower-ranked tokens correctly
- top-p filtering respects cumulative-probability cutoff
- repetition penalty changes logits for repeated tokens as expected
- seeded sampling is reproducible

### Integration tests

- one tiny fixture for greedy decoding
- one tiny fixture for sampled decoding with a fixed seed
- a parity-oriented example rerun once Phase 01 and Phase 02 are stable

---

## 7. Acceptance criteria

This phase is done when:

- the repo explicitly names its parity decode policy
- `examples/result/*` generation can be reproduced from documented settings
- decode policy is reusable and tested rather than embedded ad hoc in model code
- remaining example diffs can be discussed without ambiguity about the sampler path
