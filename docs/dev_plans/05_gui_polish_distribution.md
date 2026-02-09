# Phase 05 — GUI polish + distribution

**Objective:** shippable macOS app.

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
