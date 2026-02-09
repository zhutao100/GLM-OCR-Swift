# Phase 00 — Scaffold (this repo)

**Objective:** establish project boundaries + buildable targets + docs.

Borrowing references: `docs/reference_projects.md` (survey + borrowing map) to keep later phases grounded.

**Status (2026-02-09):** complete.

## Done in this starter
- [x] SwiftPM package with `VLMRuntimeKit`, `GLMOCRAdapter`, `GLMOCRApp`, `GLMOCRCLI`
- [x] AGENTS.md
- [x] docs layout + initial plans

## Exit criteria
- [x] `swift build` succeeds on macOS 14+ with Xcode/Swift 6
- [x] `swift test` succeeds
- [x] CLI launches and prints usage (`swift run GLMOCRCLI --help`)
- [x] App launches (UI scaffold; OCR inference is stubbed)

Quick verification script: `scripts/bootstrap.sh`.
