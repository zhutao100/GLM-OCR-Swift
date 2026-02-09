# ADR 0001 — Core + Adapter architecture

## Status
Accepted

## Context
We want a native Swift GLM-OCR app now, but we may later consolidate multiple OCR/VLM models into one workbench.

## Decision
Implement a model-agnostic core (`VLMRuntimeKit`) and a model-specific adapter (`GLMOCRAdapter`).

## Consequences
- Enables future consolidation by adding new adapters with minimal refactor.
- Requires discipline to keep the core free of model-specific assumptions.
