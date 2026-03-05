# Tracker - quality parity

**Objective:** track the live status of parity and quality work after the structural layout blockers were removed.

**Status (2026-02-27):** active. Structural parity recovery is complete. Remaining work is ordered below by expected leverage.

---

## 0. Reproducibility (pinned revisions)

The default CLI revisions are `main`. For parity/quality work, prefer pinning both model snapshots so reports are reproducible.

Current working baselines (update here when intentionally rebasing):

- GLM-OCR: `zai-org/GLM-OCR` @ `677c6baa60442a451f8a8c7eabdfab32d9801a0b`
- PP-DocLayout-V3: `PaddlePaddle/PP-DocLayoutV3_safetensors` @ `a0abee1e2bb505e5662993235af873a5d89851e3`

Where they are used:

- CLI: `--revision <hash>` + `--layout-revision <hash>`
- Examples harness: `scripts/run_examples.sh --glm-revision <hash> --layout-revision <hash>`

## 1. Status snapshot

### Completed

- [x] Added PP-DocLayout-V3 formula aliasing for HF snapshot label strings
- [x] Fixed block-list JSON export labels for `table` and `formula`
- [x] Confirmed restored formula block counts on representative examples (`paper`, `page`, `GLM-4.5V_Pages_1_2_3`)
- [x] Established that the next diffs are primarily crop, polygon, and generation-policy issues rather than gross structural loss

### Active queue

1. **Phase 01 - crop + ordering alignment**
2. **Phase 02 - polygon + mask support**
3. **Phase 03 - generation alignment**
4. **Phase 04 - thresholded coverage + CI policy**

---

## 2. Ordered backlog

### Phase 01 - crop + ordering alignment

**Goal:** eliminate avoidable drift caused by coordinate conversion and missing layout heuristics.

**Tasks**

- [x] Switch normalized bbox conversion in `PPDocLayoutV3Model.toNormalizedBBox` from floor/ceil expansion to upstream-style truncation semantics
- [x] Switch `VisionIO.cropRegion` pixel-bound conversion from down/up rounding to upstream-style truncation semantics
- [x] Add crop-specific tests that compare pixel rectangles against the upstream contract for representative bbox values near page edges
- [x] Mirror the upstream min-size validity pre-filter before post-process selection
- [x] Mirror `filter_large_image` in the Swift postprocess path, behind a clearly documented option if needed
- [x] Re-run parity reports for `paper`, `page`, `table`, and `GLM-4.5V_Pages_1_2_3`
- [x] Record whether order-sequence tie-breaking still needs adjustment once crop math is stable

**Notes (2026-02-28)**

- parity report: `max_bbox_delta` tightened to <= 8 for `paper`, `table`, and `GLM-4.5V_Pages_1_2_3`
- `page` still shows a local ordering mismatch (three adjacent `text` blocks permuted); treat this as remaining Workstream C follow-up

**Exit criteria**

- bbox deltas stop shifting for purely arithmetic reasons
- no known missing upstream layout heuristic remains untracked in the detector path
- at least one regression test protects the chosen rounding contract

---

### Phase 02 - polygon + mask support

**Goal:** replace bbox-only crops with mask-derived polygon crops where upstream provides them.

**Tasks**

- [ ] Expose final `out_masks` in the Swift detector raw outputs
- [ ] Gather masks with the same top-query selection used for scores/labels/boxes
- [ ] Implement the same fallback rules as upstream:
  - invalid box -> rectangle polygon
  - no contour -> rectangle polygon
  - fewer than four polygon points -> rectangle polygon
- [ ] Choose contour extraction path after a short spike:
  - [ ] evaluate Apple-native contour extraction on binary masks
  - [ ] if semantics drift, implement a local external-contour + simplification path
- [ ] Preserve polygon coordinates in normalized `[0, 1000]` space and feed them into `VisionIO.cropRegion`
- [ ] Add targeted unit fixtures for contour extraction and polygon normalization
- [ ] Add end-to-end example checks for formula-heavy samples

**Exit criteria**

- `ProcessedRegion.polygon` is no longer bbox-derived by default when masks are present
- formula and table crops visibly reduce background contamination on targeted examples
- the polygon path has both unit and end-to-end coverage

---

### Phase 03 - generation alignment

**Goal:** make decoding policy explicit, testable, and aligned with the chosen parity contract.

**Tasks**

- [ ] Decide and document the parity target source of truth:
  - HF direct model path
  - official SDK pipeline path
  - repo-owned explicit parity profile
- [ ] Reconcile the current upstream default ambiguity:
  - SDK `config.py` page-loader defaults
  - SDK `config.yaml` page-loader defaults
  - HF `generation_config.json`
- [ ] Expand `GenerateOptions` to include the knobs actually needed for parity work
- [ ] Introduce reusable sampler plumbing in `VLMRuntimeKit/Generation` instead of embedding more policy in `GLMOCRModel.generate(...)`
- [ ] Support deterministic seeded sampling for parity experiments
- [ ] Add repetition penalty and top-k support if the chosen parity target requires them
- [ ] Expose CLI controls for parity runs without making the default UX noisy
- [ ] Add targeted integration tests covering greedy and sampled modes separately

**Exit criteria**

- the repo can explain exactly which decode policy generated `examples/result/*`
- parity experiments are reproducible
- sampler logic is reusable and regression-tested

---

### Phase 04 - thresholds + coverage + CI policy

**Goal:** lock in the stable subset without slowing down the default development loop.

**Tasks**

- [ ] Add `examples/golden_result/GLM-4.5V_Page_1/` so the quality lane covers both PDFs
- [ ] Promote at least one PDF and one PNG example to threshold-gated status
- [ ] Add per-example threshold policy docs to the tracker or adjacent notes
- [ ] Use `tools/example_eval/` as the primary scorer/enforcer (keep `scripts/compare_examples.py` as the diagnostic diff tool)
- [ ] Add representative PNG parity integration tests once Phase 01 and Phase 02 settle
- [ ] Document a CI mode that is opt-in or subset-gated rather than globally expensive

**Exit criteria**

- at least one PDF and one PNG example are protected by thresholds
- report-only mode still exists for exploratory work
- the repo has a documented low-flake CI posture for quality/parity checks

---

## 3. Risks to keep visible

- **Contour-semantic mismatch risk:** an Apple-native contour API may not match the OpenCV-style polygon semantics used upstream closely enough for parity work.
- **False attribution risk:** generation-policy tuning before crop/polygon alignment can hide the real source of errors.
- **Over-gating risk:** threshold enforcement added too early can create churn while the examples are still unstable.
- **Reference ambiguity risk:** upstream SDK defaults and HF model defaults are not obviously the same, so parity claims must name the exact target.

---

## 4. Completion criteria for the tracker

This tracker can move to maintenance mode when:

- all four phases are either complete or explicitly descoped
- the remaining open diffs are intentional and documented per example
- the stable examples are protected by thresholds or integration tests
