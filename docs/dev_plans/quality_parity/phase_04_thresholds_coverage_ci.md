# Phase 04 - formatting/export parity, golden policy, thresholds, and CI

**Goal:** turn improved runtime parity into stable, user-visible checked-in artifacts and protect the stable subset with low-flake automation.

**Status (2026-03-05):** planned. This phase now explicitly includes formatting/export parity and golden-result policy, not only threshold enforcement.

---

## 1. Why this phase is broader than CI

The comparison work showed that parity is not only about OCR content. It is also about the exported structure the user sees:

- markdown block ordering
- image placeholder replacement
- fenced code language tags
- block-list JSON labels and shape
- example result directory semantics and regeneration rules

A repo can have good OCR content and still fail practical parity if its final artifacts drift.

---

## 2. Scope

### In scope

- markdown/export semantics
- block-list JSON stability
- example regeneration policy
- golden/reference/result artifact ownership
- thresholded example coverage
- low-flake CI posture

### Out of scope

- new model/runtime behavior that belongs to Phases 01-03

---

## 3. Workstreams

## Workstream A - output-format parity audit

Audit and document the output-sensitive behaviors that affect checked-in examples:

1. region ordering in markdown
2. image placeholder replacement and crop filename policy
3. fenced-code formatting and language labeling
4. JSON export ordering and stable serialization
5. preservation of table/formula/image-specific semantics

The first deliverable is a short matrix naming which behaviors are guaranteed, best-effort, or intentionally repo-owned.

## Workstream B - golden/reference/result policy

Write down the purpose of each artifact family:

- `reference_result/*`
- `golden_result/*`
- `result/*`
- `eval_records/*`

Then define:

- who may update them
- when an update is a bug fix vs a rebaseline
- which metadata must accompany an update

## Workstream C - threshold policy

Start small and explicit.

1. choose one PDF and one PNG example for early enforcement
2. document the threshold rationale per example
3. keep report-only coverage for the rest of the corpus
4. expand only when the examples are demonstrably stable

## Workstream D - CI posture

Recommended posture:

1. cheap local diagnostics by default
2. opt-in or subset-gated parity enforcement in CI
3. broader report generation available but not required for every change

This phase should protect parity work without making normal development hostile.

---

## 4. Suggested first protected examples

### PDF

- `GLM-4.5V_Page_1`

Reasoning:

- already exercised by parity integration tests
- narrower scope than the 3-page PDF
- good signal for image placeholder and markdown/export behavior

### PNG

- `table` or `seal`

Reasoning:

- relatively stable structure
- lower ambiguity than `page` while the geometry work is still settling

Only promote `code` and `page` after Phases 01-03 are stable enough that failures are actionable rather than noisy.

---

## 5. Acceptance criteria

This phase is complete when:

- output-format semantics that affect checked-in examples are documented
- example artifact ownership and rebaseline rules are written down
- at least one PDF and one PNG example are protected by thresholds and/or parity integration checks
- report-only exploratory coverage still exists for the rest of the corpus
- CI posture is documented and low-flake
