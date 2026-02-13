# Phase 04.1 Implementation Plan — Structured output types + region cropping

> Status: Complete (2026-02-12) — implemented; kept in archive for reference.

## Goal
Expose a structured document result (`pages/regions/bboxes`) via **public runtime types**, and provide a **model-agnostic Core Image cropping primitive** that operates on the official **normalized 0–1000** coordinate space.

This plan is intentionally self-contained and does **not** require any layout model work.

## Scope
### Public API / type changes (VLMRuntimeKit)
Update `Sources/VLMRuntimeKit/OCRTypes.swift` (or add `Sources/VLMRuntimeKit/OCRDocumentTypes.swift` and re-export) with:

- `public struct OCRNormalizedBBox: Sendable, Codable, Equatable { var x1,y1,x2,y2: Int }`
  - Invariant: values are in `[0, 1000]`, `x1 < x2`, `y1 < y2`.
- `public struct OCRNormalizedPoint: Sendable, Codable, Equatable { var x,y: Int }`
- `public enum OCRRegionKind: String, Sendable, Codable { case text, table, formula, image, unknown }`
- `public struct OCRRegion: Sendable, Codable, Equatable` with:
  - `index: Int` (reading order within page)
  - `kind: OCRRegionKind`
  - `nativeLabel: String` (e.g. `doc_title`, `table`, `image`)
  - `bbox: OCRNormalizedBBox`
  - `polygon: [OCRNormalizedPoint]?`
  - `content: String?` (nil for skipped regions like images)
- `public struct OCRPage: Sendable, Codable, Equatable { index: Int; regions: [OCRRegion] }`
- `public struct OCRDocument: Sendable, Codable, Equatable { pages: [OCRPage] }`

### Extend `OCRResult` (additive)
Update `public struct OCRResult` to include:
- `public var document: OCRDocument?`
- Update initializer with `document: OCRDocument? = nil`.

This keeps existing callers working while enabling later export/UX work.

## Core Image region cropping helper (VLMRuntimeKit)
Add `Sources/VLMRuntimeKit/VisionIO/VisionCrop.swift` (or extend `VisionIO.swift`) with:

- `public static func cropRegion(image: CIImage, bbox: OCRNormalizedBBox, polygon: [OCRNormalizedPoint]?, fillColor: CIColor = .white) throws -> CIImage`

Rules:
- Interpret normalized bbox/polygon in **top-left-origin** image coordinates (matching the official pipeline).
- Convert to pixels using the image extent:
  - `x1px = bbox.x1 * width / 1000`, `y1px = bbox.y1 * height / 1000`, etc.
  - CoreImage y-axis flip: `ciRect.origin.y = extent.maxY - y2px`, `height = y2px - y1px`.
- If `polygon` exists and has `>= 3` points:
  - Create a mask image by drawing the polygon (in cropped-local coordinates) into a bitmap context.
  - Composite via `CIBlendWithMask` (keeps inside polygon, fills outside with `fillColor`).
- If polygon missing/invalid: bbox-only crop.

## Tests (default-running)
Add `Tests/VLMRuntimeKitTests/VisionCropTests.swift`:
- bbox normalized → correct crop extent and y-axis flip.
- polygon masking keeps inside pixels and whites out outside (simple rectangle polygon case is sufficient).

## Verification
- `swift test`

## Exit criteria
- `OCRResult` is extended additively and encodes/decodes with `Codable` without breaking existing callers.
- `VisionIO.cropRegion(...)` passes unit tests for y-flip correctness and polygon masking.
