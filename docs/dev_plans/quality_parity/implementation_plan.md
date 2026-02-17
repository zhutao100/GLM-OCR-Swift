# Implementation plan — quality + parity with `examples/golden_result`

This doc is a self-contained engineering plan for turning the repo’s examples corpus into a **repeatable validation system** with two distinct targets:

- **Parity target:** upstream published outputs (`examples/reference_result/*`)
- **Quality target:** curated, human-verified outputs (`examples/golden_result/*`)

The point is to make changes safer and more intentional:

- parity lane answers: “did we accidentally break functional equivalence?”
- quality lane answers: “did we make the output better or worse for real users?”

---

## Why `golden_result` exists

Some upstream example outputs contain issues that are undesirable to preserve long-term (OCR mistakes, formatting glitches, inconsistent code fences, etc.). The curated `examples/golden_result/*` outputs are the **best-known** results after human review and light cleanup.

Treat `golden_result` as:

- a **calibration target** for formatter/postprocessing work,
- a **regression oracle** once outputs converge,
- and a **decision record** when we intentionally diverge from upstream examples.

---

## Scope and non-goals

### In scope

- A local workflow that produces `examples/result/*` deterministically from `examples/source/*`.
- A comparison system that can evaluate **both** lanes (reference parity and golden quality).
- Clear, per-example status reporting and “known diffs” documentation.
- Opt-in CI-friendly checks that do not slow down default `swift test`.

### Non-goals (for now)

- Full-model benchmarking (latency/throughput); keep this plan focused on correctness/quality.
- Training-time evaluation metrics; we only validate inference outputs.
- Perfect semantic equivalence scoring; start with pragmatic string/block diffs.

---

## Current state (starting point)

- `scripts/run_examples.sh` regenerates `examples/result/*` from `examples/source/*` in layout mode.
- `LayoutExamplesParityIntegrationTests.swift` runs opt-in parity tests for a small PDF set against `examples/reference_result/*`.
- `examples/golden_result/*` mirrors the example set but currently emphasizes Markdown (and, for PDFs, cropped images).

---

## Target deliverables

### A) Comparison tooling (local + CI)

1) **Golden quality report**
- Input: `examples/result/<name>` + `examples/golden_result/<name>`
- Output: a concise summary + a readable diff (per example)
- Supports:
  - Markdown comparison
  - image asset checks (for `imgs/*`)

2) **Reference parity report**
- Input: `examples/result/<name>` + `examples/reference_result/<name>`
- Output: same style of summary + diff
- Supports:
  - Markdown comparison
  - JSON comparison (schema + bbox tolerance)
  - image asset checks

3) **Per-example status table**
- A single markdown table showing:
  - parity status (pass / expected diffs / fail)
  - quality status (gap size / pass / target not met yet)
  - next action and owner (optional)

### B) Opt-in automated checks

- `swift test --filter …` suites for:
  - upstream parity checks
  - golden quality checks

or a script-driven harness that exits non-zero only when thresholds are exceeded.

---

## Design: what “match” means

### 1) Markdown comparison

Use a layered approach so we can tighten over time:

**Level 0 — Normalization (always-on)**
- normalize line endings (`\r\n` → `\n`)
- trim trailing whitespace per line
- normalize repeated blank lines (optional; apply only if it reduces noise)
- normalize Markdown image paths if we intentionally relocate/rename assets (avoid this unless necessary)

**Level 1 — Block structure**
- headings: count + text
- code fences: opening/closing balance, language tag (if present), and code body
- lists/tables: preserve rows and bullet nesting where feasible

**Level 2 — Text similarity (quality lane only)**
- compute a simple distance score (e.g., normalized Levenshtein/WER) for non-code prose blocks
- allow thresholds per example as we converge

Pragmatic guidance:
- For **parity lane**, prefer **exact match after normalization**. If that’s too strict, allow only narrowly-scoped fuzzing (e.g., whitespace).
- For **quality lane**, start with **report-only**, then enforce thresholds once an example reaches a stable “good” state.

### 2) JSON comparison (parity lane)

Use JSON exports as the canonical structure checker:

- schema compatibility (types/keys)
- page count / block count per page
- bbox tolerance (in pixels) for location drift
- stable IDs are optional; prefer structural equivalence over byte-for-byte equality

If `golden_result` does not have JSON today:
- keep JSON parity checks bound to `reference_result` initially
- add golden JSON later as an explicit milestone (see phases)

### 3) Image assets (`imgs/*`)

For each example folder that contains `imgs/`:

- minimum check: expected files exist
- stronger check: match SHA-256 of each image file
  - only enable if the image generation path is deterministic (same encoding/metadata)

If SHA checks are too brittle (JPEG metadata differences):
- fall back to size check + pixel hash (decode → hash raw pixels), but that’s heavier.

---

## Phased rollout

### Phase 0 — Inventory + documentation (low risk)

**Goal:** make the current state explicit and remove ambiguity.

- Add a per-example inventory table:
  - examples included
  - which have reference_result and golden_result
  - which have JSON and/or imgs
- Add a “known diffs” section linking `examples/reference_result_notes/*`.

**Exit:** tracker clearly lists what’s covered and what’s missing.

---

### Phase 1 — Report-only golden evaluation

**Goal:** make golden comparisons easy without breaking anyone’s workflow.

- Add a script (or Swift tool) that:
  - runs the examples (or assumes `examples/result/*` already exists)
  - compares result vs golden
  - prints a summary report (top offenders, biggest diffs)
- No failing thresholds yet; this is visibility-first.

**Exit:** developers can quickly answer: “did my change move us toward or away from golden?”

---

### Phase 2 — Opt-in golden checks with thresholds (incremental)

**Goal:** start locking in improvements where we’re confident.

- For each example that reaches a stable golden match (or tight delta):
  - encode a threshold policy:
    - exact match after normalization, **or**
    - max distance score, **or**
    - “block structure must match, prose distance <= X”
- Add an opt-in test suite (env-gated) that fails when thresholds are exceeded.

**Exit:** at least one image example and one PDF example are gated by golden thresholds.

---

### Phase 3 — Expand coverage + enrich golden artifacts

**Goal:** reduce reliance on noisy upstream artifacts and improve debuggability.

- Expand parity tests to cover `examples/source/*.png`.
- Consider adding:
  - `examples/golden_result/<name>/<name>.json` for layout structure
  - `examples/golden_result/<name>/meta.json` (snapshot hashes + notes)
- Where golden intentionally diverges from upstream:
  - record the rationale (small note file next to the example, or a section in the tracker).

**Exit:** golden lane covers the full example set (at least Markdown; JSON optionally).

---

### Phase 4 — CI integration policy

**Goal:** make the checks useful in PRs without making CI fragile.

Options:

- CI runs **report-only** golden evaluation on every PR; failing is opt-in via label.
- CI gates only the subset of examples that are already stable.
- CI uses cached snapshots (or pre-bundled tiny snapshots) to keep runtime predictable.

**Exit:** quality/parity regressions are visible in PRs with minimal flakiness.

---

## Snapshot pinning (critical)

Every comparison is only meaningful if the model snapshots are pinned.

Record (at minimum):

- GLM-OCR snapshot hash + model config summary
- PP-DocLayout-V3 snapshot hash + model config summary
- dtype/device assumptions for parity runs (FP16/BF16/FP32; CPU/GPU)

Where to record:
- `docs/dev_plans/quality_parity/tracker.md` (human-facing)
- the harness scripts/tests (machine-facing)

---

## Update policy for `golden_result`

Golden outputs are curated. Updating them should be deliberate and reviewable.

Rules:

1) Never auto-regenerate golden in scripts.
2) Every golden update must include:
   - a short justification (“fixed code fence language”, “corrected OCR error due to tokenizer bug”, etc.)
   - the snapshot hashes used
3) Prefer small, scoped updates (one example at a time) so diffs are reviewable.

Suggested workflow:
- run `scripts/run_examples.sh --clean`
- diff `examples/result/<name>` vs `examples/golden_result/<name>`
- if the new output is better:
  - copy result → golden (manual)
  - add/update a note explaining why

---

## Risks and mitigations

- **Non-determinism across hardware/backends**
  Mitigation: keep opt-in checks pinned to a known device/dtype regime; consider CPU-only for golden gating if needed.

- **Upstream output drift**
  Mitigation: treat upstream as the parity baseline only; golden provides stability for quality.

- **Overfitting to small examples**
  Mitigation: expand the examples set only after the harness is stable; keep a “representative” checklist (code, table, handwriting, seals, dense paper text, PDFs).

---

## Concrete next actions (recommended)

1) Update the tracker to explicitly define the dual-lane model (parity vs quality).
2) Add a per-example status table with both lane statuses.
3) Implement a report-only golden diff script and document it in the tracker.
4) Promote at least 2 examples to threshold-gated golden checks once the report is stable.
