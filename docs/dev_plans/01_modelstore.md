# Phase 01 — ModelStore (Hub snapshot + local cache)

**Objective:** robust model download / caching for GLM-OCR.

Borrowing references: `docs/reference_projects.md` (“Borrowing map”, DeepSeek OCR repos’ Hub snapshot patterns).

**Status (2026-02-09):** implemented and wired to CLI/App. Remaining work is mostly API polish (progress streaming) and UX.

## Tasks
- [x] Define canonical cache root:
  - default to HF cache (`~/.cache/huggingface/hub`) unless overridden
  - support custom base directory (GUI setting + CLI flag)
  - borrow: HF cache env var precedence (`HF_HUB_CACHE`, `HF_HOME`) from the reference Swift OCR repos
- [x] Implement `HuggingFaceHubModelStore.resolveSnapshot(...)` using `HubApi.snapshot`
- [x] Add glob filtering for typical LLM/VLM artifacts:
  - `*.safetensors`, `*.json`, tokenizer files, `preprocessor_config.json`, etc.
- [ ] (Nice-to-have) Expose progress as an `AsyncStream` for UI consumption
  - current API is a `(@Sendable (Progress) -> Void)?` callback, and both CLI/App already render progress via that callback
- [x] Unit tests for path resolution and env var precedence:
  - `HF_HUB_CACHE`, `HF_HOME`

## Exit criteria
- [x] CLI can resolve/download a model snapshot into the configured cache root (`swift run GLMOCRCLI --download-only`)
- [x] Progress renders in the App (“Download/Load Model” button)
