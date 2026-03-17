# Example evaluation (agent report)

- generated_at: `2026-03-17T18:51:12+00:00`
- git: `2375d65`
- git_head_sha: `2375d654e2f6158a2d97367c2158e2d25b4a4cdb`
- git_dirty: `False`
- glm_snapshot: `zai-org/GLM-OCR@677c6baa60442a451f8a8c7eabdfab32d9801a0b`
- layout_snapshot: `PaddlePaddle/PP-DocLayoutV3_safetensors@a0abee1e2bb505e5662993235af873a5d89851e3`
- generation_preset: `parity-greedy-v1`
- mean_final_overall: `0.9195`

## Scores

| Example | Final | Δ vs baseline | Parity | Result→Golden | Ref→Golden | Rules |
|---|---:|---:|---:|---:|---:|---:|
| `GLM-4.5V_Page_1` | 0.9569 | +0.0846 | 0.9600 | 0.9115 | 0.9308 | 0/0 |
| `GLM-4.5V_Pages_1_2_3` | 0.9440 | +0.0683 | 0.9494 | 0.8454 | 0.8743 | 0/7 |
| `code` | 0.8708 | -0.0308 | 0.8985 | 0.8153 | 0.8406 | 1/3 |
| `handwritten` | 0.9609 | -0.0168 | 0.9109 | 0.7842 | 0.7967 | 0/1 |
| `page` | 0.7160 | -0.0278 | 0.7829 | 0.4486 | 0.5148 | 1/1 |
| `paper` | 0.9329 | -0.0322 | 0.9629 | 0.7316 | 0.7343 | 1/2 |
| `seal` | 0.9804 | +0.0000 | 0.9804 | 0.9875 | 0.9875 | 0/0 |
| `table` | 0.9944 | +0.0000 | 0.9944 | 1.0000 | 1.0000 | 0/0 |

## Focus

### `page`

- final_overall: `0.7160`
- delta_vs_baseline: `-0.0278`
- result_md: `examples/result/page/page.md`
- result_json: `examples/result/page/page.json`
- reference_md: `examples/reference_result/page/page.md`
- reference_json: `examples/reference_result/page/page.json`
- eval_report_md: `examples/eval_records/latest/examples/page/report.md`
- eval_report_json: `examples/eval_records/latest/examples/page/report.json`
- golden_md: `examples/golden_result/page/page.md`
- golden_json: `examples/golden_result/page/page.json`

**Signals**
- lowest dimension: `text_fidelity` = 0.6712
- json components < 0.98: bbox=0.6488, content=0.6637
- text blocks: extra_actual=3, missing_expected=1, paired=27
- lowest text pairs: (idx=None, status=extra_actual, actual=None, expected=None, score=0.0000), (idx=None, status=extra_actual, actual=None, expected=None, score=0.0000), (idx=None, status=extra_actual, actual=None, expected=None, score=0.0000), (idx=None, status=missing_expected, actual=None, expected=None, score=0.0000), (idx=None, status=paired, actual=list_item, expected=list_item, score=0.2021)
- rules failed: 1 (first: glue_strength_constant / contains / Missing required phrase: '0.2\\mathrm{N} / \\mathrm{mm}^{2}'.)
- fix_hints: OCR JSON (block ordering, bbox rounding, content normalization), Markdown block segmentation (heading/list/paragraph splits), Example-specific rules/regression

### `code`

- final_overall: `0.8708`
- delta_vs_baseline: `-0.0308`
- result_md: `examples/result/code/code.md`
- result_json: `examples/result/code/code.json`
- reference_md: `examples/reference_result/code/code.md`
- reference_json: `examples/reference_result/code/code.json`
- eval_report_md: `examples/eval_records/latest/examples/code/report.md`
- eval_report_json: `examples/eval_records/latest/examples/code/report.json`
- golden_md: `examples/golden_result/code/code.md`
- golden_json: `examples/golden_result/code/code.json`

**Signals**
- lowest dimension: `text_fidelity` = 0.8618
- style.code_languages: actual=['xml'], expected=['html', 'html']
- json components < 0.98: bbox=0.7528, content=0.9292
- text blocks: paired=6
- lowest text pairs: (idx=None, status=paired, actual=paragraph, expected=code, score=0.2395), (idx=None, status=paired, actual=code, expected=code, score=0.4403)
- rules failed: 1 (first: local_jndi_name_tag / contains / Missing required phrase: '<local-jndi-name>AddressHomeLocal</local-jndi-name>'.)
- fix_hints: Markdown style wrappers (centering/bold/fences), OCR JSON (block ordering, bbox rounding, content normalization), Markdown block segmentation (heading/list/paragraph splits), Example-specific rules/regression

### `paper`

- final_overall: `0.9329`
- delta_vs_baseline: `-0.0322`
- result_md: `examples/result/paper/paper.md`
- result_json: `examples/result/paper/paper.json`
- reference_md: `examples/reference_result/paper/paper.md`
- reference_json: `examples/reference_result/paper/paper.json`
- eval_report_md: `examples/eval_records/latest/examples/paper/report.md`
- eval_report_json: `examples/eval_records/latest/examples/paper/report.json`
- golden_md: `examples/golden_result/paper/paper.md`
- golden_json: `examples/golden_result/paper/paper.json`

**Signals**
- lowest dimension: `critical_structure` = 0.9459
- json components < 0.98: bbox=0.6561, content=0.9572
- text blocks: paired=30
- rules failed: 1 (first: not_divisible_by_Q / contains / Missing required phrase: 'not divisible by Q'.)
- fix_hints: OCR JSON (block ordering, bbox rounding, content normalization), Example-specific rules/regression

### `handwritten`

- final_overall: `0.9609`
- delta_vs_baseline: `-0.0168`
- result_md: `examples/result/handwritten/handwritten.md`
- result_json: `examples/result/handwritten/handwritten.json`
- reference_md: `examples/reference_result/handwritten/handwritten.md`
- reference_json: `examples/reference_result/handwritten/handwritten.json`
- eval_report_md: `examples/eval_records/latest/examples/handwritten/report.md`
- eval_report_json: `examples/eval_records/latest/examples/handwritten/report.json`
- golden_md: `examples/golden_result/handwritten/handwritten.md`
- golden_json: `examples/golden_result/handwritten/handwritten.json`

**Signals**
- lowest dimension: `text_fidelity` = 0.8865
- json components < 0.98: bbox=0.7000, content=0.9116
- text blocks: extra_actual=1, paired=4
- lowest text pairs: (idx=None, status=extra_actual, actual=None, expected=None, score=0.0000)
- fix_hints: OCR JSON (block ordering, bbox rounding, content normalization), Markdown block segmentation (heading/list/paragraph splits)
