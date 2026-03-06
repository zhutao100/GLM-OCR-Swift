# Implementation plan - phased faithful parity improvement

**Objective:** turn the current parity work from a generic quality-improvement lane into a specific, faithful parity program with named upstream contracts, bounded phases, and reproducible output regeneration.

**Status (2026-03-05):** active. Structural layout recovery is already in place. The next work is about finishing parity where it still matters most: dense-page layout, crop geometry, generation policy, and output formatting.

---

## 1. What the comparative analysis changed

The direct comparison against the official Python repo, the selected `transformers` files, and the peer Swift port changed the framing of the work in four ways.

### 1.1 The repo is already beyond "gross structural mismatch"

The previously documented fixes around formula labels and block-list JSON export were the high-order structural blockers. Those are no longer the main reason the outputs differ.

### 1.2 The remaining highest-value gaps are now known

The most important remaining drift buckets are:

1. layout/crop/order contract drift
2. polygon/mask geometry drift
3. generation-policy drift
4. markdown/JSON/export drift

### 1.3 The parity target must be split carefully

`GLM-OCR-Swift` should not try to mimic the official Python repo's orchestration architecture. It **should** mimic the user-visible and output-visible semantics of:

- the HF/local model path for model/runtime behavior
- the official repo's formatting and page-level behavior where that affects checked-in example outputs

### 1.4 The peer Swift port gives a practical priority signal

Based on the checked-in reports, `glm-ocr.swift` is materially ahead on the current example mean and especially on the harder `code` and `page` examples. That indicates the next work should prioritize parity-sensitive execution details over new architecture work.

---

## 2. Working parity contract

### 2.1 Contract statement

For this repo, **faithful parity** means:

- the local GLM-OCR and PP-DocLayout-V3 inference path matches the intended upstream config and postprocess behavior closely enough that the checked-in example outputs are explainable against a named reference contract
- the markdown and JSON outputs preserve the same user-visible structure that the reference examples intend to represent
- example regeneration is reproducible from pinned revisions and a documented decode preset

### 2.2 What is out of scope

The following are out of scope for this plan unless later required by product goals:

- reproducing the official repo's MaaS/client architecture
- reproducing parallel request orchestration mechanics that do not change local output semantics
- introducing heavy cross-platform dependencies into the shipping path merely to imitate upstream tooling choices

---

## 3. Phase strategy

## Phase 00 - reference contract + reproducibility

Before more parity work lands, write the contract down once and use it everywhere.

**Deliverables**

- one parity-target matrix
- one pinned-revision policy
- one decode-preset policy for parity runs
- one score baseline table for the checked-in examples

## Phase 01 - layout/crop/order alignment

This is the highest-leverage remaining implementation phase.

It should finish all output-sensitive math and ordering work that still differs from the upstream layout contract, including any remaining page filtering, crop bounds, order sequencing, and reuse of page rasters/crops.

## Phase 02 - polygon/mask geometry parity

This phase upgrades region geometry from "rectangles only" to "use mask-derived polygons when upstream provides them." It is expected to help dense pages and formula/table crops more than easy examples.

## Phase 03 - generation/runtime parity

This phase makes the generation path explicit, reusable, and reproducible. The goal is not to make the runtime infinitely configurable; it is to support the few generation presets needed for faithful parity work and stable example regeneration.

## Phase 04 - formatting/export parity + golden policy + CI

This phase turns improved runtime behavior into stable checked-in artifacts. It should normalize markdown/JSON output semantics, define when examples are regenerated, and lock the stable subset with thresholds or integration coverage.

---

## 4. Why this order matters

### Do not do generation tuning first

If layout regions, crop math, or ordering are still drifting, generation changes create false confidence. The repo must first stabilize *what text the model is seeing* before it spends time tuning *how that text is decoded*.

### Do not delay formatting/export until the end

Even when OCR content is correct, user-visible parity can still be lost in markdown image replacement, block serialization, language/tag labeling, or result ordering. Phase 04 is therefore not optional cleanup; it is part of the parity contract.

---

## 5. Concrete repo touchpoints by phase

### Phase 00

- `docs/dev_plans/quality_parity/*`
- `scripts/run_examples.sh`
- `scripts/example_eval_record.py`
- `scripts/verify_example_eval.sh`

### Phase 01

- `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Model.swift`
- `Sources/ModelAdapters/GLMOCR/GLMOCRLayoutPipeline.swift`
- `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift`
- `Sources/VLMRuntimeKit/VisionIO/VisionIO.swift`
- relevant tests under `Tests/DocLayoutAdapterTests/` and `Tests/VLMRuntimeKitTests/`

### Phase 02

- raw detector outputs in the DocLayout adapter
- polygon plumbing through the OCR block model
- `VisionIO` polygon-aware crop path
- new unit and parity tests for mask/polygon behavior

### Phase 03

- `Sources/VLMRuntimeKit/OCRTypes.swift`
- `Sources/VLMRuntimeKit/Generation/Generation.swift`
- `Sources/ModelAdapters/GLMOCR/GLMOCRModel.swift`
- `Sources/GLMOCRCLI/GLMOCRCLI.swift`
- generation integration tests under `Tests/GLMOCRAdapterTests/`

### Phase 04

- markdown and block-list export in `VLMRuntimeKit`
- `scripts/compare_examples.py`
- `tools/example_eval/` integration points
- `examples/result/*`, `examples/reference_result/*`, and `examples/eval_records/*`

---

## 6. Acceptance conditions for the whole plan

This refreshed plan is complete when all of the following are true:

1. the repo can state, in one page, what "faithful parity" means
2. the hard examples (`code`, `page`, formula-heavy PDFs) have named remaining gaps or are closed
3. example regeneration is reproducible from pinned revisions and a named preset
4. stable examples are protected by thresholds and/or parity integration tests
5. future contributors do not need to rediscover the parity target from scratch
