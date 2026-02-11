# Phase 04.9 Implementation Plan — End-to-end layout output parity vs `examples/`

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
  - same number of blocks per page (within a small tolerance only if strictly necessary)
  - label parity (`text` / `image`)
  - bbox parity (0..1000 space, within a small integer tolerance)
  - content parity (whitespace-normalized; allow small punctuation/quote normalization only if unavoidable)
- Markdown parity target: `examples/result/<name>/<name>.md`
  - same block ordering
  - identical heading/bullet/formula formatting rules
  - image references:
    - either reproduce the final `![Image p-i](imgs/...)` form by implementing crop+replace in Swift,
    - or add an explicit CLI mode that emits placeholders only and store a placeholder-based reference set.

### 2) Align formatter behavior with the official ResultFormatter
Audit `Sources/ModelAdapters/DocLayout/LayoutResultFormatter.swift` against:
`../GLM-OCR/glmocr/postprocess/result_formatter.py`.
- Ensure label mapping matches `label_visualization_mapping`.
- Ensure content cleanup + bullet/formula/heading merges match (including small formatting details like spaces).

### 3) Emit JSON in the canonical schema
Today the CLI emits `OCRDocument` JSON (Swift-native schema). Add a canonical emitter for:
`[[{index,label,content,bbox_2d}, ...], ...]` so `--emit-json` can match `examples/result/*/*.json`.

If changing `--emit-json` is too breaking, add an explicit flag (e.g. `--emit-glmocr-json`) and update docs/tests accordingly.

### 4) Add an opt-in end-to-end regression check for `examples/`
Add a new integration test (opt-in) that:
- runs the layout pipeline on `examples/source/GLM-4.5V_Page_1.pdf` (page 1)
- compares produced Markdown/JSON against `examples/result/GLM-4.5V_Page_1/*`

Gating:
- require env var to enable (to keep CI hermetic), similar to golden checks
- require local model snapshot availability (or reuse HF cache)

### 5) Re-run the original repro command
Validate:
`swift run GLMOCRCLI --input examples/source/GLM-4.5V_Page_1.pdf --layout --emit-json /tmp/GLM-4.5V_Page_1.json > /tmp/GLM-4.5V_Page_1_layout.txt`
and compare against `examples/result/GLM-4.5V_Page_1/*`.

## Exit criteria
- The `examples/` opt-in regression check passes for at least `GLM-4.5V_Page_1.pdf`.
- The original repro command produces outputs that match the canonical `examples/result/*` within the defined tolerances.
