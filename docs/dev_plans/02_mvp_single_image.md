# Phase 02 — MVP: single image / single PDF page -> text

**Objective:** one GLM-OCR inference end-to-end for a single image.

Borrowing references: `docs/reference_projects.md` (“Borrowing map”, DeepSeek OCR / DeepSeek OCR2 / PaddleOCR-VL).

## Tasks
- [ ] Implement `VisionIO` decode:
  - image file -> `CIImage`
  - PDF page render (PDFKit) -> `CIImage`
  - borrow: CoreImage decode/conversion patterns (`mzbac/deepseek-ocr.swift` `ImageProcessor.swift`)
- [ ] Implement `VisionIO` conversion to MLX tensor with normalization
  - borrow: `DeepSeekOCRImageProcessor` CoreImage→MLX conversion + normalization (`mzbac/deepseek-ocr.swift` `ImageProcessor.swift`)
  - borrow: dynamic resize strategy (`PaddleOCRVLImageProcessor` `smartResize` flow) for huge PDFs (`mlx-community/paddleocr-vl.swift` `ImageProcessor.swift`)
- [ ] Implement `TokenizerKit`:
  - `<image>` placeholder splitting
  - task presets -> prompt text
  - borrow: `<image>` prompt splitting helper (`DeepseekOCR2Generator.tokenizePromptParts(prompt:)`) (`mzbac/deepseek-ocr2.swift` `DeepseekOCR2Generator.swift`)
  - borrow: task preset modeling (`PaddleOCRTask`) (`mlx-community/paddleocr-vl.swift` `Configuration.swift`)
- [ ] Stub-then-port `GLMOCRModel`:
  - start with “load config + load weights + single forward pass” harness
- [ ] Implement a minimal `Generation` loop for greedy decode connecting to the model
  - borrow: simple greedy decode loop structure (`DeepSeekOCRGenerator.generate(...)`) (`mzbac/deepseek-ocr.swift` `Generator.swift`)
  - borrow: KV-cache utilities for long outputs / batching (`KVCache*`) (`mzbac/deepseek-ocr2.swift` `Utils/KVCache.swift`)
- [ ] Hook `GLMOCRCLI` to run a single image/page job
  - borrow: CLI command structure + “download/cache then run” flow (`DeepSeekOCRCLI` `main.swift`) (`mzbac/deepseek-ocr.swift`)
- [ ] Hook `GLMOCRApp` to run a single job

## Exit criteria
- `swift run GLMOCRCLI --image <path>` produces output for one image
- App runs OCR for one dropped image and shows output
