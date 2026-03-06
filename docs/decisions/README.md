# Decisions (ADRs)

**Status (2026-03-06):** active. Current ADRs live in `docs/decisions/`; superseded ADRs live in `docs/decisions/obsolete_archive/`.

Use this folder for decisions that should outlive the current task, especially when they affect module boundaries, public interfaces, cache/export contracts, or prompt/generation policy. For current behavior, start with `README.md`, `docs/overview.md`, and `docs/architecture.md`; ADRs explain why the repo is shaped that way.

## Current ADRs

- ADR 0001
  - `docs/decisions/0001-core-adapter.md`
  - why the repo is split into model-agnostic core plus adapters

- ADR 0002
  - `docs/decisions/0002-multimodal-generation-chat-template-kvcache.md`
  - why multimodal generation, chat-template handling, and KV-cache ownership are split the way they are

## Obsolete / Superseded ADRs

- ADR 0003
  - `docs/decisions/obsolete_archive/0003-ppdoclayoutv3-encoder-only-inference.md`

## ADR Conventions

- Include `Status`, `Context`, `Decision`, and `Consequences`.
- Add one when the change is architectural or contractual, not for routine local fixes.
- Link the ADR from `docs/architecture.md` or the relevant tracker when it becomes part of the maintained workflow.
