# Phase 04.5 Implementation Plan — PP-DocLayout-V3 detector: processor + load-only validation

> Status: Complete (2026-02-12) — implemented; kept in archive for reference.

## Goal
Implement everything needed to **download/cache** the PP-DocLayout-V3 snapshot, **parse config**, and **validate weights presence** in a “load-only” path.

This session should end with a reliable “it loads / keys are present” signal, without requiring inference correctness yet.

## Prerequisites
- Phase 04.2 (`DocLayoutAdapter` target, defaults, config parsing).
- Existing `WeightsLoader` / weights utilities in `VLMRuntimeKit` (if missing, implement minimal pieces here).

## Scope
### 1) Processor (image preprocessing)
Add `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Processor.swift`:
- Convert `CIImage` → `[1, H, W, 3]` tensor via existing `ImageTensorConverter`.
- Resize policy:
  - Default: keep aspect ratio.
  - If model config requires a fixed size, implement that exactly (read from config).
- Normalization:
  - Load mean/std from the layout model’s preprocessor config if present; otherwise fallback `(0.5, 0.5, 0.5)` (matching Phase 03 defaults).

### 2) Snapshot download + “load-only” detector actor
Add `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Detector.swift` (actor):
- `ensureLoaded()`:
  - uses `ModelStore` + `PPDocLayoutV3Defaults` to download/resolve snapshot
  - loads config + (optional) preprocessor config
  - loads safetensors metadata/keys and validates required keys exist

### 3) Weights inventory
Add `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Weights.swift`:
- Load the `.safetensors` arrays and validate:
  - required keys are present (explicit list checked in code)
  - key shapes are plausible for expected model dims (lightweight checks; avoid enforcing every layer yet)

## Tests / verification
### Default-running tests
- Unit test that config + preprocessor config (fixture JSON) decode cleanly.

### Optional integration (skipped by default)
If env var `LAYOUT_SNAPSHOT_PATH` is set:
- load snapshot from that path
- run `ensureLoaded()` and assert “required keys present”

## Verification commands
- `swift test`

## Exit criteria
- Snapshot resolution + config decoding are stable.
- On a machine with a real snapshot, “load-only” validation succeeds and produces actionable errors when keys are missing.
