# Phase 04 — Layout + region OCR orchestration

**Objective:** quality parity with the “full pipeline” story (layout detection + parallel recognition).

## Tasks
- [ ] Integrate a layout model stage (likely separate adapter)
- [ ] Split pages into regions + run OCR per region
- [ ] Merge outputs (reading order) into Markdown
- [ ] Batch parallelism + cancellation

## Exit criteria
- A4 scanned PDF page produces structured output with sane ordering
