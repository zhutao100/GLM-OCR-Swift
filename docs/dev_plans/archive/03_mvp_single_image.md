# Phase 03 — MVP: single image / single PDF page -> text

**Objective:** one GLM-OCR inference end-to-end for a single image.

Borrowing references: `docs/reference_projects.md` (“Borrowing map”, DeepSeek OCR / DeepSeek OCR2 / PaddleOCR-VL).

**Status (2026-02-09):** end-to-end single-image/single-page OCR is now implemented (PDF render + CIImage→MLX tensor conversion + GLM chat-template tokenization + greedy decode with KV-cache). Parity vs the official MLX Python example still needs to be validated on real images.

## Tasks
- [x] Implement `VisionIO` image decode:
  - image file -> `CIImage` (`VisionIO.loadCIImage(from:)`)
- [x] Implement `VisionIO` PDF page rendering:
  - PDF page render (PDFKit) -> `CIImage`
  - borrow: CoreImage/PDFKit patterns (`mzbac/deepseek-ocr.swift` `ImageProcessor.swift`)
- [x] Implement `VisionIO` conversion to an MLX tensor with normalization
  - borrow: `DeepSeekOCRImageProcessor` CoreImage→MLX conversion + normalization (`mzbac/deepseek-ocr.swift` `ImageProcessor.swift`)
  - borrow: dynamic resize strategy (`PaddleOCRVLImageProcessor` `smartResize` flow) for huge PDFs (`mlx-community/paddleocr-vl.swift` `ImageProcessor.swift`)
- [x] Implement baseline prompt helpers in `TokenizerKit`
  - `<image>` placeholder splitting (`PromptTemplate.splitByImagePlaceholder`)
  - task presets → instruction string (`PromptTemplate.instruction(for:)`)
- [x] Implement real tokenization + chat-template correctness for GLM-OCR
  - align with `docs/GLM-OCR_model.md` (special tokens + `[gMASK]<sop>` prefix + image placeholders)
  - ensure the text token stream and image tensor(s) are aligned
- [x] Provide a minimal model-agnostic generation façade
  - `CausalLM` + `GreedyGenerator` exist in `VLMRuntimeKit/Generation`
- [x] Implement a minimal greedy decode loop (token-by-token) + optional cancellation
  - borrow: simple greedy decode loop structure (`DeepSeekOCRGenerator.generate(...)`) (`mzbac/deepseek-ocr.swift` `Generator.swift`)
  - borrow: KV-cache utilities for long outputs / batching (`KVCache*`) (`mzbac/deepseek-ocr2.swift` `Utils/KVCache.swift`)
- [x] Hook `GLMOCRCLI` to run a single image/page job (wiring)
  - borrow: CLI command structure + “download/cache then run” flow (`DeepSeekOCRCLI` `main.swift`) (`mzbac/deepseek-ocr.swift`)
- [x] Hook `GLMOCRApp` to run a single job (wiring)

## Exit criteria
- `swift run GLMOCRCLI --input <path>` produces OCR output for one image or one PDF page
- App runs OCR for one dropped image/PDF and shows output (not just an error)
- Parity within acceptable tolerance vs the official MLX Python example on 3-5 test images
