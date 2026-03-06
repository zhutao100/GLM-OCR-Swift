# Tracker - faithful quality parity

**Objective:** track the live status of the refreshed faithful-parity plan after the major structural blockers were removed.

**Status (2026-03-06):** maintenance mode. All five phases are complete; follow-up work should be incremental parity improvements within the documented contract, not a new roadmap reset.

---

## 0. Current baseline and reference signal

### Checked-in score snapshot (current repo)

Use the current checked-in reports as the baseline until intentionally rebaselined.

| Example | Current final overall |
|---|---:|
| `GLM-4.5V_Page_1` | 0.8730 |
| `GLM-4.5V_Pages_1_2_3` | 0.8758 |
| `code` | 0.7744 |
| `handwritten` | 0.9777 |
| `page` | 0.7438 |
| `paper` | 0.9651 |
| `seal` | 0.9804 |
| `table` | 0.9944 |
| **mean** | **0.8981** |

### Comparative priority signal

The peer Swift port's checked-in reports are ahead overall, especially on `code` and `page`. Treat that as a priority signal, not as a reason to copy its architecture wholesale.

Biggest current deficits to close first:

1. `code`
2. `page`
3. dense mixed-layout/formula pages

---

## 1. Source-of-truth matrix

| Behavior class | Primary source | Secondary source | Current repo rule |
|---|---|---|---|
| GLM-OCR model config / image preprocessing | selected `transformers` GLM-OCR files | fixtures + integration tests | Swift path should match semantics, not Python library choice |
| PP-DocLayout-V3 postprocess / masks / polygons | selected `transformers` PP-DocLayout-V3 files | repo golden fixtures/tests | fallback behavior must be explicit |
| page loading / page selection | official Python repo behavior | repo scripts/tests | local-native implementation allowed |
| markdown and block-list output shape | checked-in reference examples + integration tests | official repo intent | checked-in examples define practical parity |
| parity-run decode preset | repo-owned explicit preset | upstream defaults as input only | preset must be recorded in reports |

---

## 2. Reproducibility policy

The default CLI revisions may continue to follow `main`, but parity work should use pinned revisions recorded in docs and score artifacts.

**Checked-in parity contract (2026-03-06)**

| Input | Value |
|---|---|
| GLM-OCR snapshot | `zai-org/GLM-OCR@677c6baa60442a451f8a8c7eabdfab32d9801a0b` |
| PP-DocLayout-V3 snapshot | `PaddlePaddle/PP-DocLayoutV3_safetensors@a0abee1e2bb505e5662993235af873a5d89851e3` |
| generation preset | `parity-greedy-v1` |
| contract source | `scripts/_parity_defaults.sh` |

**Required recorded inputs for parity runs**

- GLM-OCR revision/hash
- PP-DocLayout-V3 revision/hash
- parity preset name
- example set / corpus
- generation date

The repo now records these values in `examples/result/.run_examples_meta.json` and surfaces them in `examples/eval_records/latest/agent_report.md`.

---

## 3. Completed work that remains valid

- [x] Formula label aliasing was fixed so formula regions are no longer silently dropped due to snapshot label-name differences.
- [x] Block-list JSON export preserves `table` and `formula` labels instead of collapsing them to `text`.
- [x] The repo has a real parity integration lane for GLM-4.5V PDF examples.
- [x] The repo has enough evidence to say the next gaps are mainly crop/order, masks/polygons, generation policy, and formatting/export.

---

## 4. Ordered backlog

### Phase 00 - reference contract + reproducibility

**Goal:** make "faithful parity" explicit and reproducible.

**Tasks**

- [x] write the parity-target matrix into the maintained docs
- [x] define the supported parity preset names
- [x] record pinned revision policy for parity runs
- [x] thread parity metadata into score artifacts and/or eval records
- [x] write one short rebaseline policy for checked-in example artifacts

**Exit criteria**

- one written parity contract exists
- reports can name the preset and revisions that produced them
- contributors no longer need to infer the target from scattered files

**Rebaseline policy**

- `examples/result/*` may change when a code or contract change is intentional and `scripts/verify_example_eval.sh` shows no significant unexplained regression.
- `examples/eval_records/latest/*` should be refreshed in the same commit as the accepted `examples/result/*` update so the before/after evidence stays attached.
- `examples/reference_result/*` changes only when the upstream reference contract itself changes.
- `examples/golden_result/*` changes only for human-verified adjudication updates, not to hide parity regressions.

---

### Phase 01 - layout/crop/order alignment

**Goal:** close the remaining layout-path drift with the highest expected leverage on `page` and `code`.

**Tasks**

- [x] audit bbox normalization and de-normalization contracts end-to-end
- [x] regression-test crop rounding/clamping near boundaries
- [x] confirm min-size and large-image filtering behavior against the intended upstream contract
- [x] record and stabilize region order/tie-breaking on representative dense examples
- [x] reuse page rasters/crops between layout detection and OCR cropping where safe and deterministic
- [x] rerun parity reports for `page`, `code`, `paper`, and the GLM-4.5V PDFs
- [x] document any remaining ordering differences that are intentional or not yet solved

**Exit criteria**

- crop/order math is regression-tested and stable
- no unexplained filter or clamp behavior remains
- the remaining drift on hard examples is no longer mainly attributable to crop/order defects

Phase 01 is complete. The maintained Swift path now uses one page-image load per layout request, and the remaining hard-example score gap is tracked under later geometry and generation phases rather than unexplained crop/order behavior.

---

### Phase 02 - polygon/mask geometry parity

**Goal:** use mask-derived polygons when upstream provides them, with explicit fallback behavior.

**Tasks**

- [x] expose final masks from the DocLayout path
- [x] preserve mask-to-region alignment through selection and export
- [x] implement contour extraction and simplification with explicit fallback rules
- [x] support polygon-aware cropping in `VisionIO`
- [x] preserve polygons through OCR result models and JSON export
- [x] add unit tests for contour/polygon normalization
- [x] add end-to-end checks on formula/table-heavy examples

**Exit criteria**

- valid masks produce usable polygons by default, with OCR crop usage gated by parity-validated class policy
- fallback behavior is documented and tested
- target examples show reduced contamination-driven errors

Phase 02 is complete. Mask-derived polygons now flow through layout postprocess with explicit bbox fallback when the mask geometry is missing or invalid. `OCRDocument` preserves the derived polygons, and the OCR path applies polygon crops for table regions while keeping formula OCR on bbox crops after broader polygon-crop trials regressed `page`, `paper`, and `GLM-4.5V_Pages_1_2_3`. The accepted Phase 02 run finishes with 0 regressions and improvements on `page`, `code`, and `GLM-4.5V_Pages_1_2_3`.

---

### Phase 03 - generation/runtime parity

**Goal:** make decode policy explicit, minimal, and reproducible for checked-in parity artifacts.

**Tasks**

- [x] define the supported preset family (`default-greedy-v1`, `parity-greedy-v1`)
- [x] expand generation/runtime types only as needed by those presets
- [x] explicitly defer sampled preset plumbing until a checked-in parity contract requires it
- [x] add CLI/script support for explicit preset selection
- [x] record preset metadata in example-eval artifacts
- [x] add regression tests for supported preset resolution

**Exit criteria**

- every checked-in parity artifact can name its preset
- generation policy is no longer implicit
- current parity runs are reproducible

Phase 03 is complete. Generation presets are now first-class runtime input instead of an implicit `temperature = 0` / `topP = 1` convention. `GLMOCRCLI` and `scripts/run_examples.sh` both thread the chosen preset explicitly, the checked-in parity contract continues to use `parity-greedy-v1`, and the default user-facing preset is the quieter `default-greedy-v1`. Sampled presets remain intentionally out of scope until the repo adopts one for checked-in artifacts.

---

### Phase 04 - formatting/export parity + golden policy + CI

**Goal:** protect the user-visible artifact layer and lock the stable subset.

**Tasks**

- [x] audit markdown and JSON output semantics that affect checked-in examples
- [x] document `reference_result`, `golden_result`, `result`, and `eval_records` ownership
- [x] define the rebaseline policy for example artifacts
- [x] protect at least one PDF and one PNG example with parity integration tests
- [x] keep broad report-only coverage available for exploratory work
- [x] document a low-flake CI posture for parity/quality checks

**Exit criteria**

- output-format semantics are documented
- example rebaselines follow an explicit policy
- the stable subset is protected without slowing normal development excessively

Phase 04 is complete. The maintained output contract now lives in `examples/README.md`, artifact ownership and refresh rules are documented across `examples/README.md` and `examples/eval_records/README.md`, and the low-flake protected subset is enforced through `LayoutExamplesParityIntegrationTests` for `GLM-4.5V_Page_1` and `table`. The broader corpus remains available through `scripts/verify_example_eval.sh` without turning every change into a high-latency parity gate.

---

## 5. Risks to keep visible

- **Reference ambiguity risk:** upstream sources do not automatically resolve all policy questions; the repo must own a written contract.
- **False attribution risk:** generation tuning before geometry parity can hide the real root cause of errors.
- **Contour-semantic mismatch risk:** a contour API can look correct while still drifting from the upstream polygon semantics that matter for crops.
- **Artifact drift risk:** OCR content improvements can still appear as regressions if markdown/JSON/export rules are not stabilized.
- **Over-gating risk:** thresholding unstable examples too early creates churn instead of confidence.

---

## 6. Maintenance-mode criteria

This tracker can move to maintenance mode when:

- all five phases are complete or explicitly descoped
- current example artifacts carry enough metadata to reproduce them
- hard examples either meet the chosen parity target or have their remaining intentional gaps documented
- the stable subset is protected by automated checks
