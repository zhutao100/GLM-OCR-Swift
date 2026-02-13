# Phase 04.9 Implementation Plan — End-to-end layout output parity vs `examples/`

> Status: Implemented (2026-02-11) — **structural parity + image crop/replace + canonical JSON schema**.
>
> Note: Full *text content* parity vs `examples/result/*` is model-output-dependent and is **not asserted** yet.

## Goal
Make `swift run GLMOCRCLI --layout` produce outputs that **match the canonical `examples/result/*` artifacts**:
- Markdown reading order and formatting
- JSON block list semantics (labels, bboxes, content)

This phase is end-to-end: detector → crop → region OCR → formatter → emit.

## Inputs / references
- Canonical fixtures:
  - `examples/source/`
  - `examples/result/*/*.md`
  - `examples/result/*/*.json`
- Official behavior:
  - `../GLM-OCR/glmocr/pipeline/pipeline.py`
  - `../GLM-OCR/glmocr/postprocess/result_formatter.py`
  - `../GLM-OCR/glmocr/utils/markdown_utils.py` (image crop/replace)

## Plan

### 1) Define “match” precisely (avoid vague parity)
For each `examples/source/<name>.pdf`:
- JSON parity target: `examples/result/<name>/<name>.json`
  - same number of blocks per page
  - label parity (`text` / `image`)
  - bbox parity (0..1000 space, within a small integer tolerance; current regression uses `±15`)
  - content parity (current regression is **structural**: image blocks must have empty content; text blocks must be non-empty)
- Markdown parity target: `examples/result/<name>/<name>.md`
  - image references match the canonical `![Image p-i](imgs/...)` form (crop + replace)
  - no remaining placeholder tags (`![](page=...,bbox=[...])`)
  - note: the current opt-in regression checks **image refs only**, not full Markdown text content

### 2) Align formatter behavior with the official ResultFormatter
Audit `Sources/ModelAdapters/DocLayout/LayoutResultFormatter.swift` against:
`../GLM-OCR/glmocr/postprocess/result_formatter.py`.
- Ensure label mapping matches `label_visualization_mapping`.
- Ensure content cleanup + bullet/formula/heading merges match (including small formatting details like spaces).

### 3) Emit JSON in the canonical schema
Make `--emit-json` write the canonical schema:
`[[{index,label,content,bbox_2d}, ...], ...]` so it matches `examples/result/*/*.json`.

Keep the Swift-native structured schema available via an explicit flag: `--emit-ocrdocument-json`.

### 4) Add an opt-in end-to-end regression check for `examples/`
Add a new integration test (opt-in) that:
- runs the layout pipeline on `examples/source/GLM-4.5V_Page_1.pdf` (page 1)
- compares produced Markdown/JSON against `examples/result/GLM-4.5V_Page_1/*` (structural parity)

Gating:
- require `GLMOCR_RUN_EXAMPLES=1` to enable (to keep CI hermetic), similar to golden checks
- require local model snapshot availability:
  - `GLMOCR_SNAPSHOT_PATH` (GLM-OCR snapshot folder)
  - `LAYOUT_SNAPSHOT_PATH` (PP-DocLayout-V3 snapshot folder)

### 5) Re-run the original repro command
Validate:
`swift run GLMOCRCLI --input examples/source/GLM-4.5V_Page_1.pdf --layout --emit-json /tmp/GLM-4.5V_Page_1.json > /tmp/GLM-4.5V_Page_1_layout.txt`
and compare against `examples/result/GLM-4.5V_Page_1/*`.

Notes:
- When `--emit-json` is provided, the CLI writes cropped images to `<emit-json dir>/imgs/` and replaces image placeholders in the Markdown output so it matches the `![Image p-i](imgs/...)` form.

## Exit criteria
- The `examples/` opt-in regression check passes for at least `GLM-4.5V_Page_1.pdf`.
- The original repro command produces outputs that match the canonical `examples/result/*` within the defined tolerances.
