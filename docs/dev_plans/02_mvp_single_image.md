# Phase 02 — MVP: single image / single PDF page -> text

**Objective:** one GLM-OCR inference end-to-end for a single image.

## Tasks
- [ ] Implement `VisionIO` decode:
  - image file -> `CIImage`
  - PDF page render (PDFKit) -> `CIImage`
- [ ] Implement `VisionIO` conversion to MLX tensor with normalization
- [ ] Implement `TokenizerKit`:
  - `<image>` placeholder splitting
  - task presets -> prompt text
- [ ] Stub-then-port `GLMOCRModel`:
  - start with “load config + load weights + single forward pass” harness
- [ ] Implement a minimal `Generation` loop for greedy decode connecting to the model
- [ ] Hook `GLMOCRApp` to run a single job

## Exit criteria
- `swift run GLMOCRCLI --image <path>` produces output for one image
- App runs OCR for one dropped image and shows output
