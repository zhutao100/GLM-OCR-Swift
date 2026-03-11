# GUI polish + distribution

**Objective:** turn the current single-document SwiftUI runner into a shippable macOS app.

**Status (2026-03-11):** deferred but current. Core OCR pipelines exist and the app is useful for local manual runs, but packaging and richer UX are not the current top priority.

## Current Starting Point

- The app supports one dropped image or PDF at a time.
- Users can choose task, layout mode, PDF page spec, and max tokens.
- The app downloads/loads models and shows Markdown output.
- Structured `OCRDocument` JSON is kept in memory but has no export UI yet.
- There is no queue, batch run UX, model manager, or packaged distribution flow.

## Prioritized Backlog

- Export UX
  - save Markdown and `OCRDocument` JSON directly from the app
- Job lifecycle UX
  - clearer progress, cancellation, retries, and error presentation
- Model management
  - download location, disk usage, cache cleanup, and revision visibility
- Packaging
  - Developer ID signing, notarization, and repeatable DMG build script
- Performance tuning
  - cache limits, tiling strategy, and layout-region scheduling for large documents
- Optional update channel
  - Sparkle or another lightweight update story after signing/notarization exists

## References

- `docs/architecture.md`
  - current app/runtime boundary and output behavior
- `docs/reference_projects.md`
  - UI and distribution patterns worth borrowing when this work resumes

## Exit Criteria

- Notarized macOS app artifact that runs cleanly on a fresh machine
- Exportable Markdown and structured JSON from the app UI
- Multi-run UX that is clearly better than the current single-drop scaffold
