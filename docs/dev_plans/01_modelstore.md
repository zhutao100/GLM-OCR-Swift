# Phase 01 — ModelStore (Hub snapshot + local cache)

**Objective:** robust model download / caching for GLM-OCR.

## Tasks
- [x] Define canonical cache root:
  - default to HF cache (`~/.cache/huggingface/hub`) unless overridden
  - support custom base directory (GUI setting + CLI flag)
- [x] Implement `HuggingFaceHubModelStore.resolveSnapshot(...)` using `HubApi.snapshot`
- [x] Add glob filtering for typical LLM/VLM artifacts:
  - `*.safetensors`, `*.json`, tokenizer files, `preprocessor_config.json`, etc.
- [ ] Expose progress to UI via `AsyncStream<ModelDownloadProgress>` (currently via callback)
- [x] Unit tests for path resolution and env var precedence:
  - `HF_HUB_CACHE`, `HF_HOME`

## Exit criteria
- CLI can download a model snapshot into the configured cache root
- Progress renders in the App
