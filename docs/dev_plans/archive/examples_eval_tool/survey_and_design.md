# Examples evaluation tool (survey + current state)

**Objective:** provide a scored evaluation loop for `examples/result/*` vs `examples/reference_result/*` (parity) and `examples/golden_result/*` (quality), without relying solely on raw diffs.

**Status (2026-03-04):** implemented as the `tools/example_eval/` sub-project. `scripts/python/compare_examples.py` remains the low-level diff tool.

For usage/configuration, start at `tools/example_eval/README.md`. The remainder of this document captures the original survey/design rationale and may include ideas not implemented verbatim.

---

The design direction was to build a **stand-alone Python scoring harness** that borrows the *evaluation shape* of modern document-parsing benchmarks rather than trying to adopt one wholesale.

The web survey points to a few strong ideas:

* **READoc** has the most relevant evaluation pattern for your use case: **Standardization → Segmentation → Scoring**. It explicitly standardizes Markdown to suppress superficial formatting noise, segments the document into semantic units like headings, formulas, tables, and plain text, and then scores those units with different metrics instead of one monolithic diff. ([arXiv][1])
* **OmniDocBench** and **docling-eval** confirm that serious document-eval stacks are multi-metric and multi-task, covering text OCR, layout, reading order, and table structure rather than just edit distance. ([GitHub][2])
* **KITAB-Bench**’s **MARS** metric is a useful simplification: it combines **chrF3** for text fidelity with **TEDS** for table structure, which is very close to your “text first, critical table formatting first-class, decorative markdown second-class” requirement. ([arXiv][3])
* **olmOCR-Bench** adds another useful idea: keep some **deterministic rule checks** as unit-test-like verifiers for critical facts or structure, instead of relying only on one continuous score. ([GitHub][4])
* For implementation, keep the dependency set small: **markdown-it-py** (parser), **beautifulsoup4** (HTML table parsing), and **PyYAML** (policy/rules). Richer text/table metrics (e.g. chrF/TEDS-style) can be added later if needed. ([GitHub][5])

So the recommendation is:

## Use a hybrid evaluator

**Do not** use raw unified diffs or `SequenceMatcher` as the final quality score.

Keep the current `scripts/python/compare_examples.py` as a **diagnostic diff tool**, but add a new scorer that produces:

* a **continuous parity score**
* a **golden-adjudicated final score**
* per-dimension breakdowns
* deterministic high-value rule checks

That fits the repo much better than dropping in a full external benchmark framework.

---

## What the current repo setup implies

From this repo:

* `examples/README.md` defines the intended contract clearly:

  * `reference_result/` is the upstream mirrored parity target
  * `golden_result/` is the human-verified baseline
  * `reference_result_notes/` already contains adjudication hints
* `scripts/python/compare_examples.py` is useful, but it is still mostly **match/diff/missing** logic with some JSON tolerance checks, not a real scorer.
* `golden_result/GLM-4.5V_Page_1/` is currently missing, so the quality lane is incomplete for one PDF sample.

That means the right design is **not** “replace everything.” It is:

1. keep the current diff harness,
2. add a new scorer beside it,
3. gradually move `reference_result_notes/` toward machine-readable checks.

---

## Proposed workflow

### Phase 1: Normalize into a canonical intermediate representation

The scorer lives at `tools/example_eval/` (Python 3.12+).

Each document becomes a `DocIR`:

* `pages`
* `blocks` in order
* block kind:

  * `heading`
  * `paragraph`
  * `list_item`
  * `code`
  * `formula`
  * `table`
  * `image`
  * `caption`
  * `page_break`
* normalized text
* optional bbox / page index
* optional style metadata

Canonicalization rules should intentionally ignore second-class noise:

* normalize line endings and trailing whitespace
* normalize Unicode spaces / full-width punctuation where safe
* strip or downweight decorative wrappers like:

  * `**bold**`
  * `<div align="center">`
  * harmless blank-line differences
* canonicalize code fences so:

  * ` ```html ` vs ` ```xml ` is a soft difference
* parse **HTML tables** and **Markdown tables** into the same `TableIR`
* preserve page boundaries explicitly for PDFs

This is the single biggest improvement over the current script.

---

## Scoring model

Expose **three scores** per example:

1. **Parity score**
   `result` vs `reference_result`

2. **Golden delta**
   whether `result` is better or worse than `reference_result` when judged against `golden_result`

3. **Final adjudicated score**
   parity score adjusted by the golden delta

### Dimension weights

Use a tiered rubric:

* **Text fidelity**: 60%
* **Critical structure**: 35%
* **Decorative markdown fidelity**: 5%

If a sample has no tables, redistribute the unused table weight into text + block structure.

### Text fidelity

For prose, headings, captions, and non-table text:

* use **chrF3** on canonicalized text as the primary metric
* add a block-level recall/precision component so missing or reordered blocks hurt more than a single global text concat would

Why chrF3: it is character-sensitive enough for OCR mistakes, but less brittle than raw exact-match. That is the same motivation behind MARS using chrF3 for Markdown recognition. ([arXiv][3])

For code/formula blocks:

* use stricter scoring than prose
* recommended:

  * 70% exact-line match
  * 30% chrF3

That prevents “almost right” code OCR from getting too much credit.

### Critical structure

Split into:

* **table structure + cell content**
* **block order / block types / page boundaries**

For tables:

* parse both HTML and Markdown into `TableIR`
* score with:

  * **TEDS** for topology / structure
  * cell-text chrF3 for content
* recommended table score:

  * 60% TEDS
  * 40% cell-text

This is directly aligned with the MARS idea and common table-eval practice. ([arXiv][3])

For block/page structure:

* use the reference JSON block list as a structural signal
* score:

  * label agreement
  * block order similarity
  * soft bbox similarity
  * page-count/page-break correctness

Important: JSON should be **supporting evidence**, not the dominant score. Your first-class contract is still rendered content.

### Decorative markdown fidelity

Low-weight checks only:

* bold / italic
* centering wrappers
* exact heading marker style
* exact fence language
* image placeholder style

This is where `seal` should score high even if the golden uses bold text and the result does not.

---

## Golden adjudication rule

This is the key piece your repo is currently missing.

For each scoring dimension `d`, compute:

* `P_d = score(result, reference)`
* `RG_d = score(result, golden)`
* `UG_d = score(reference, golden)`

Then:

* `delta_d = RG_d - UG_d`

Interpretation:

* if `delta_d > 0`, the result is **better than upstream** on that dimension
* if `delta_d < 0`, the result is **worse than upstream**
* if `delta_d ≈ 0`, treat the discrepancy as neutral

Then compute:

* `final_d = clamp(P_d + λ * delta_d, 0, 1)`

with `λ = 0.25` to start.

That keeps **parity to upstream** as the main target, while letting the golden baseline reward genuine improvements and penalize regressions.

### Why this works on your examples

It matches the examples you already have:

* **`handwritten`**: result should beat reference because golden corrects `入间` → `人间`
* **`seal`**: reference/result should remain high because boldface is decorative
* **`table`**: HTML `<table>` and pipe-table Markdown should converge to the same canonical table score
* **`code`**: bad OCR in identifiers/tags should be penalized heavily because content is wrong, not just formatting

---

## Add rule-based checks from notes

Your `reference_result_notes/` already contains human knowledge that shouldn’t live only in prose.

Add a machine-readable sidecar:

* `examples/scoring_rules/<name>.yaml`

Example shape:

```yaml
checks:
  - type: page_start
    page: 2
    must_contain: "1 Introduction"

  - type: page_end
    page: 2
    must_contain: "Therefore, we propose strategies including Reinforcement Learning with Curriculum"

  - type: continuation
    left_must_contain: "Reinforcement Learning with Curriculum"
    right_must_contain: "Sampling (RLCS) and dynamic sampling expansion"
```

This is the right place to encode the current PDF boundary notes, and it borrows the same spirit as olmOCR-Bench’s deterministic fact checks. ([GitHub][4])

These checks should not replace the continuous score; they should produce:

* `pass`
* `warn`
* `fail`

and feed into CI gating.

---

## Recommended package layout

```text
tools/example_eval/
  pyproject.toml
  config/
    policy.yaml
    rules/
      handwritten.yaml
      GLM-4.5V_Pages_1_2_3.yaml
  src/example_eval/
    cli.py
    rules.py
    report.py
  tests/
```

Use:

* `markdown-it-py`
* `beautifulsoup4`
* `pyyaml`
* `pytest`

This is intentionally a small dependency set; add heavier metrics (e.g. chrF/TEDS-style) only if they pay for themselves in signal. ([GitHub][5])

---

## CLI and outputs

Suggested CLI:

```bash
uv run --project tools/example_eval example-eval evaluate --repo-root .
```

Outputs:

* `summary.json`
* `summary.md`
* `junit.xml`
* `examples/<name>/report.md`
* `examples/<name>/report.json`

Public summary table should show:

* parity score
* golden delta
* final score
* critical failures
* note/rule status

---

## Test strategy

### Unit tests

Target the fragile semantics:

* HTML table ↔ Markdown table canonicalization
* decorative markdown stripping
* code-fence normalization
* formula normalization
* golden arbitration math
* page-boundary rule checks

### Fixture/integration tests

Use the existing example corpus as regression fixtures.

I would explicitly lock these behaviors:

* `table`: structure score near-perfect
* `seal`: decorative-only differences do not tank the score
* `handwritten`: result ranks above reference on final score
* `code`: final score clearly below threshold
* `GLM-4.5V_Pages_1_2_3`: page-boundary rules pass/fail deterministically

---

## CI posture

Use three buckets, matching the repo’s existing parity-plan thinking:

* **Enforced**

  * stable examples
  * fail PR if final score drops or critical checks fail

* **Monitored**

  * produce report but do not fail

* **Exploratory**

  * score only for manual review

Initially, enforce only a small canary set:

* `table`
* `seal`
* `handwritten`

and keep the PDFs monitored until `GLM-4.5V_Page_1` gets a golden baseline.

---

## Bottom line

The best design here is:

* **Python**
* **READoc-style pipeline**: standardize → segment → score
* **MARS-style core**: text metric + table-structure metric
* **olmOCR-style rule checks** for a few high-value invariants
* **golden arbitration** via `result↔golden` versus `reference↔golden`
* **current compare_examples.py retained as a low-level diff tool**, not the main score

[1]: https://arxiv.org/html/2409.05137v3 "READoc: A Unified Benchmark for Realistic Document Structured Extraction"
[2]: https://github.com/opendatalab/OmniDocBench "GitHub - opendatalab/OmniDocBench: [CVPR 2025] A Comprehensive Benchmark for Document Parsing and Evaluation"
[3]: https://arxiv.org/html/2502.14949v2 "KITAB-Bench: A Comprehensive Multi-Domain Benchmark for Arabic OCR and Document Understanding"
[4]: https://github.com/allenai/olmocr "GitHub - allenai/olmocr: Toolkit for linearizing PDFs for LLM datasets/training"
[5]: https://github.com/executablebooks/markdown-it-py "GitHub - executablebooks/markdown-it-py: Markdown parser, done right. 100% CommonMark support, extensions, syntax plugins & high speed. Now in Python!"
