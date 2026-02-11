This folder contains **opt-in** golden fixtures for integration tests.

By default, `swift test` **does not** require these fixtures.

To generate the GLM-OCR forward-pass golden fixture:

```bash
python3 scripts/generate_glmocr_golden.py --model-folder "$GLMOCR_TEST_MODEL_FOLDER"
```

Then run the golden check:

```bash
GLMOCR_TEST_MODEL_FOLDER=<path-to-snapshot> GLMOCR_RUN_GOLDEN=1 swift test
```

To run the **examples parity** end-to-end layout test:

```bash
GLMOCR_TEST_MODEL_FOLDER=<path-to-glm-ocr-snapshot> \
LAYOUT_SNAPSHOT_PATH=<path-to-ppdoclayoutv3-snapshot> \
GLMOCR_RUN_EXAMPLES=1 \
swift test --filter LayoutExamplesParityIntegrationTests
```
