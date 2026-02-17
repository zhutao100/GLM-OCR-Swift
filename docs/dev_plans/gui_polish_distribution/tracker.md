# GUI polish + distribution

**Objective:** shippable macOS app.

**Status (2026-02-17):** deferred — core OCR pipelines exist; prioritize quality/parity validation first, then return here for export/UX + packaging.

Borrowing references: `docs/reference_projects.md` (mlx-swift-examples / mlx-swift-chat UI patterns, DeepSeek OCR distribution/CLI patterns).

## Tasks
- [ ] Model manager (download / delete / storage)
- [ ] Job queue UX: progress, retries, export Markdown/JSON
  - borrow: SwiftUI streaming/cancellation patterns from `mlx-swift-examples` and `mlx-swift-chat`
- [ ] Performance tuning: cache limits, tiling strategy, batching
- [ ] Packaging: Developer ID signing + notarization script
- [ ] Optional: Sparkle updates

## Exit criteria
- Notarized DMG that runs cleanly on a fresh machine
