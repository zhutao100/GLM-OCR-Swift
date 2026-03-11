# Example evaluation (agent report)

- generated_at: `2026-03-11T22:49:07+00:00`
- git: `2f8007a-dirty`
- git_head_sha: `2f8007a6e6894b8d7c4497a0fc3d504d3dfc9692`
- git_dirty: `True`
- glm_snapshot: `zai-org/GLM-OCR@677c6baa60442a451f8a8c7eabdfab32d9801a0b`
- layout_snapshot: `PaddlePaddle/PP-DocLayoutV3_safetensors@a0abee1e2bb505e5662993235af873a5d89851e3`
- generation_preset: `parity-greedy-v1`
- mean_final_overall: `0.9139`

## Scores

| Example | Final | Δ vs baseline | Parity | Result→Golden | Ref→Golden | Rules |
|---|---:|---:|---:|---:|---:|---:|
| `GLM-4.5V_Page_1` | 0.8723 | -0.0007 | 0.8723 | None | None | 0/0 |
| `GLM-4.5V_Pages_1_2_3` | 0.8757 | -0.0001 | 0.8788 | 0.8885 | 0.9230 | 0/7 |
| `code` | 0.9016 | +0.1272 | 0.9020 | 0.7194 | 0.7270 | 0/0 |
| `handwritten` | 0.9777 | +0.0000 | 0.9277 | 0.9600 | 0.9550 | 0/1 |
| `page` | 0.7438 | +0.0000 | 0.7567 | 0.5281 | 0.6078 | 0/0 |
| `paper` | 0.9651 | +0.0000 | 0.9651 | 0.7058 | 0.7090 | 0/0 |
| `seal` | 0.9804 | +0.0000 | 0.9804 | 0.9808 | 0.9808 | 0/0 |
| `table` | 0.9944 | +0.0000 | 0.9944 | 1.0000 | 1.0000 | 0/0 |

## Focus

### `page`

- final_overall: `0.7438`
- delta_vs_baseline: `+0.0000`
- result_md: `examples/result/page/page.md`
- result_json: `examples/result/page/page.json`
- reference_md: `examples/reference_result/page/page.md`
- reference_json: `examples/reference_result/page/page.json`
- eval_report_md: `examples/eval_records/latest/examples/page/report.md`
- eval_report_json: `examples/eval_records/latest/examples/page/report.json`
- golden_md: `examples/golden_result/page/page.md`
- golden_json: `examples/golden_result/page/page.json`

**Signals**
- lowest dimension: `text_fidelity` = 0.6991
- json components < 0.98: bbox=0.6488, content=0.6637
- block_shape: 0.6000
- text blocks: missing=2, paired=28
- lowest text pairs: (idx=8, status=paired, actual=paragraph, expected=paragraph, score=0.0000), (idx=11, status=paired, actual=paragraph, expected=paragraph, score=0.0000), (idx=12, status=paired, actual=paragraph, expected=paragraph, score=0.0000), (idx=14, status=paired, actual=list_item, expected=heading, score=0.0000), (idx=15, status=paired, actual=heading, expected=heading, score=0.0000)
- fix_hints: OCR JSON (block ordering, bbox rounding, content normalization), Markdown block segmentation (heading/list/paragraph splits)

### `GLM-4.5V_Page_1`

- final_overall: `0.8723`
- delta_vs_baseline: `-0.0007`
- result_md: `examples/result/GLM-4.5V_Page_1/GLM-4.5V_Page_1.md`
- result_json: `examples/result/GLM-4.5V_Page_1/GLM-4.5V_Page_1.json`
- reference_md: `examples/reference_result/GLM-4.5V_Page_1/GLM-4.5V_Page_1.md`
- reference_json: `examples/reference_result/GLM-4.5V_Page_1/GLM-4.5V_Page_1.json`
- eval_report_md: `examples/eval_records/latest/examples/GLM-4.5V_Page_1/report.md`
- eval_report_json: `examples/eval_records/latest/examples/GLM-4.5V_Page_1/report.json`
- golden: not available for this example

**Signals**
- lowest dimension: `decorative_style` = 0.7500
- style.center_wrappers: actual=0, expected=4
- json components < 0.98: bbox=0.6636
- block_shape: 0.3889
- text blocks: missing=7, paired=11
- lowest text pairs: (idx=0, status=paired, actual=heading, expected=paragraph, score=0.0000), (idx=2, status=paired, actual=paragraph, expected=paragraph, score=0.0000), (idx=3, status=paired, actual=paragraph, expected=paragraph, score=0.0000), (idx=4, status=paired, actual=heading, expected=paragraph, score=0.0000), (idx=6, status=paired, actual=paragraph, expected=heading, score=0.0000)
- fix_hints: Markdown style wrappers (centering/bold/fences), OCR JSON (block ordering, bbox rounding, content normalization), Markdown block segmentation (heading/list/paragraph splits)

### `GLM-4.5V_Pages_1_2_3`

- final_overall: `0.8757`
- delta_vs_baseline: `-0.0001`
- result_md: `examples/result/GLM-4.5V_Pages_1_2_3/GLM-4.5V_Pages_1_2_3.md`
- result_json: `examples/result/GLM-4.5V_Pages_1_2_3/GLM-4.5V_Pages_1_2_3.json`
- reference_md: `examples/reference_result/GLM-4.5V_Pages_1_2_3/GLM-4.5V_Pages_1_2_3.md`
- reference_json: `examples/reference_result/GLM-4.5V_Pages_1_2_3/GLM-4.5V_Pages_1_2_3.json`
- eval_report_md: `examples/eval_records/latest/examples/GLM-4.5V_Pages_1_2_3/report.md`
- eval_report_json: `examples/eval_records/latest/examples/GLM-4.5V_Pages_1_2_3/report.json`
- golden_md: `examples/golden_result/GLM-4.5V_Pages_1_2_3/GLM-4.5V_Pages_1_2_3.md`
- golden_json: `examples/golden_result/GLM-4.5V_Pages_1_2_3/GLM-4.5V_Pages_1_2_3.json`

**Signals**
- lowest dimension: `decorative_style` = 0.6875
- style.center_wrappers: actual=0, expected=4
- json components < 0.98: bbox=0.6661
- block_shape: 0.4500
- text blocks: missing=8, paired=32
- lowest text pairs: (idx=0, status=paired, actual=heading, expected=paragraph, score=0.0000), (idx=2, status=paired, actual=paragraph, expected=paragraph, score=0.0000), (idx=3, status=paired, actual=paragraph, expected=paragraph, score=0.0000), (idx=4, status=paired, actual=heading, expected=paragraph, score=0.0000), (idx=6, status=paired, actual=paragraph, expected=heading, score=0.0000)
- fix_hints: Markdown style wrappers (centering/bold/fences), OCR JSON (block ordering, bbox rounding, content normalization), Markdown block segmentation (heading/list/paragraph splits)
