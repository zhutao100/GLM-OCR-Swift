# Phase 04.2 Implementation Plan — DocLayoutAdapter scaffolding + config/mappings

> Status: Complete (2026-02-12) — implemented; kept in archive for reference.

## Goal
Introduce a dedicated **layout-only model adapter target** (`DocLayoutAdapter`) and load/own all PP-DocLayout-V3 configuration + label/task mappings, without implementing inference yet.

This creates a stable place for later work (postprocess, formatter, detector) while keeping `VLMRuntimeKit` model-agnostic.

## Prerequisites
- Phase 04.1 for the public structured types (`OCRRegionKind`, bbox/point types).
- Existing HF snapshot download and cache resolution in `Sources/VLMRuntimeKit/ModelStore/ModelStore.swift`.

## Scope
### 1) Add a new SwiftPM target
In `Package.swift`:
- Add library target `DocLayoutAdapter` at `Sources/ModelAdapters/DocLayout`.
- `DocLayoutAdapter` depends on `VLMRuntimeKit`, `MLX`, `MLXNN` (add `Transformers` only if needed for config/helpers).
- Update dependencies so `GLMOCRAdapter` can import `DocLayoutAdapter` later (no behavior change required in this session).

Update `docs/architecture.md` to list `DocLayoutAdapter` as a model adapter (layout-only).

### 2) Snapshot download + defaults
Add `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Defaults.swift`:
- `modelID = "PaddlePaddle/PP-DocLayoutV3_safetensors"`
- `revision = "main"`
- `downloadGlobs = ["*.safetensors", "*.json"]` (start minimal; add extra files only if snapshot requires them)

### 3) Config + label/task mapping (mirror official `glmocr/config.yaml`)
Add `PPDocLayoutV3Config` parsing:
- Load `config.json` from snapshot folder (store only what later stages need).

Embed official mappings (from `../GLM-OCR/glmocr/config.yaml`) as Swift constants:
- `labelTaskMapping: [String: LayoutTaskType]` where `LayoutTaskType` is `.text | .table | .formula | .skip | .abandon`.
- `labelToVisualizationKind: [String: OCRRegionKind]` used by the Markdown formatter.

Add adapter-local types:
- `enum LayoutTaskType: Sendable { case text, table, formula, skip, abandon }`
- (Optional, but recommended for clarity) an internal `LayoutLabel` or `LayoutRegionKind` wrapper to keep “native label” vs “task type” distinct.

## Tests (default-running)
Add `Tests/DocLayoutAdapterTests/*` with small JSON fixtures:
- `PPDocLayoutV3ConfigTests`: loads a minimal `config.json` fixture and asserts required fields decode.
- `PPDocLayoutV3MappingsTests`: asserts known labels exist in both maps and map to expected task/kind.

## Verification
- `swift build`
- `swift test`

## Exit criteria
- `DocLayoutAdapter` target builds and is the single owner of layout-label-specific policy.
- Config decoding + mapping constants are validated by unit tests.
