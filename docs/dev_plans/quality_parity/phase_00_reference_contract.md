# Phase 00 - reference contract and reproducibility

**Goal:** define the parity target precisely enough that future work can say whether a behavior is intentionally different, still drifting, or already faithful.

**Status (2026-03-05):** not started as a formal deliverable. The repo contains the needed ingredients, but the contract is still spread across code, scripts, debug notes, and example artifacts.

---

## 1. Problem statement

The project currently has enough parity machinery to find differences, but not yet one canonical document that answers:

- what upstream behavior is the repo trying to match?
- which upstream source wins if two sources disagree?
- what settings generated the checked-in examples?
- when is a changed example a regression vs an intentional rebaseline?

Without Phase 00, later phases can land useful fixes while still leaving the project ambiguous.

---

## 2. Required decisions

### Decision A - source-of-truth matrix

Write and check in a matrix covering these behavior classes:

| Behavior class | Primary source | Secondary source | Repo-owned rule |
|---|---|---|---|
| GLM-OCR model config and preprocessing | `transformers` selected files | model card / checked-in fixtures | Swift implementation must name any deliberate deviation |
| PP-DocLayout-V3 postprocess and masks/polygons | `transformers` selected files | official Paddle snapshot behavior where needed | Swift implementation must document fallback semantics |
| page loading / page selection behavior | official Python repo | repo scripts/tests | local-native implementation may differ internally |
| markdown / block-list output shape | reference examples + official repo intent | repo integration tests | reference examples win for checked-in parity |
| parity-run decode preset | repo-owned explicit preset | upstream defaults used as inputs | repo preset must be named in all score artifacts |

### Decision B - reproducibility inputs

Check in and document:

- pinned GLM-OCR revision/hash used for parity runs
- pinned PP-DocLayout-V3 revision/hash used for parity runs
- default parity decode preset name
- any required environment variables or script flags

### Decision C - current baseline table

Record the checked-in baseline scores for:

- `GLM-4.5V_Page_1`
- `GLM-4.5V_Pages_1_2_3`
- `code`
- `handwritten`
- `page`
- `paper`
- `seal`
- `table`

The table does not need to imply satisfaction with the current scores. It exists so future improvements or regressions have a stable starting point.

---

## 3. Deliverables

1. update `tracker.md` with the source-of-truth matrix and current baseline
2. add a small parity metadata block to example-eval recording or report generation
3. document the parity preset in the CLI help and/or scripts used for example generation
4. write one short note describing when a golden/result rebaseline is allowed

---

## 4. Recommended implementation notes

### Do not overfit to one upstream file

The upstream surfaces are not perfectly unified. Treat them as inputs to a repo-owned contract, not as magical truth objects.

### Prefer explicit preset names over loose flags

Examples:

- `parity-hf-greedy`
- `parity-sdk-sampled`
- `parity-repo-default-v1`

A named preset is easier to record, compare, and discuss than a long list of ad hoc flags.

---

## 5. Acceptance criteria

This phase is complete when:

- the repo contains a written parity contract with no unresolved source-of-truth ambiguity
- score reports can name the revision pair and decode preset that produced them
- future phase work can cite one parity target instead of rediscovering it
