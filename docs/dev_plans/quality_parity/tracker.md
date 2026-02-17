# Quality / parity validation

**Objective:** validate OCR output quality and implementation parity vs the official GLM-OCR reference outputs, without slowing down `swift test` by default.

**Status (2026-02-17):** active — opt-in parity harness exists for a small PDF set; expand coverage + make outcomes explicit.

## What “done” looks like

- A pinned snapshot/revision (GLM-OCR + PP-DocLayout-V3) that we consider the baseline for parity work.
- Reproducible workflows for:
  - local, fast “does it still work?” checks (no downloads),
  - opt-in “examples parity” checks (end-to-end OCR vs `examples/reference_result/*`),
  - opt-in numerical golden checks when touching preprocessing/model math (`docs/golden_checks.md`).
- A small curated set of examples with documented expectations (match vs intentional diffs) and known gaps.

## Current state (what exists today)

- Opt-in numerical golden checks for GLM-OCR forward-pass slices and PP-DocLayout-V3 (see `docs/golden_checks.md`).
- Opt-in end-to-end layout examples parity tests for:
  - `examples/source/GLM-4.5V_Page_1.pdf`
  - `examples/source/GLM-4.5V_Pages_1_2_3.pdf`
  (see `Tests/GLMOCRAdapterTests/LayoutExamplesParityIntegrationTests.swift`).
- A batch runner that regenerates `examples/result/*` from `examples/source/*` via the CLI:
  - `scripts/run_examples.sh` (always runs in layout mode so it can emit JSON).

## Existing workflows (runnable today)

### 1) Regenerate `examples/result/*` from the CLI

```bash
scripts/run_examples.sh --clean
```

Then compare `examples/result/*` against `examples/reference_result/*` (and consult `examples/reference_result_notes/*` when needed).

### 2) Run opt-in end-to-end examples parity tests (PDFs)

```bash
# For `swift test` (debug), ensure mlx.metallib exists for debug build products.
scripts/build_mlx_metallib.sh -c debug

GLMOCR_RUN_EXAMPLES=1 \
GLMOCR_SNAPSHOT_PATH=<local_glm_ocr_snapshot> \
LAYOUT_SNAPSHOT_PATH=<local_ppdoclayoutv3_snapshot> \
swift test --filter LayoutExamplesParityIntegrationTests
```

## Next tasks (prioritized)

1. **Pin and record the baseline snapshots**
   - Decide which snapshot hashes (or commits) of:
     - `zai-org/GLM-OCR`
     - `PaddlePaddle/PP-DocLayoutV3_safetensors`
     are treated as the parity baseline, and record them in the relevant docs/tests.

2. **Expand end-to-end examples parity coverage**
   - Add opt-in parity tests for the image examples in `examples/source/*.png` against `examples/reference_result/*` (Markdown + JSON).
   - Keep tolerances and intentional diffs documented (prefer linking to `examples/reference_result_notes/*`).

3. **Make the “quality” story explicit**
   - Define what “match” means per artifact (Markdown content, JSON schema, bbox tolerances, image placeholder replacement).
   - If we intentionally diverge from the reference formatter, document the rationale and update expected outputs accordingly.

4. **Operationalize the workflow**
   - Document the recommended commands for:
     - running the opt-in examples tests (env vars + `swift test --filter …`),
     - regenerating `examples/result/*` (`scripts/run_examples.sh`),
     - diffing results locally (what to compare first).

## Exit criteria

- A documented baseline snapshot + a repeatable parity workflow.
- The opt-in examples parity suite covers both PDFs and representative image cases.
- `docs/overview.md` and `README.md` describe remaining gaps accurately (no “unknown parity” phrasing once parity is tracked and measured).
