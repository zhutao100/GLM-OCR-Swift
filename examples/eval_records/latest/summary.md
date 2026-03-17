# Example evaluation summary

- fail_under: disabled
- inflation_warn_threshold: 0.15

## How to interpret the scores

- `parity_overall`: `result` vs `reference_result` (upstream parity/regression signal).
- `quality_overall`: `result_to_golden.overall` when available; otherwise `parity_overall` (absolute usefulness proxy).
- `final_overall`: parity-first score with a small golden correction (see `config/policy.yaml`).
- `final_minus_quality`: diagnostic for parity-first inflation; large values usually mean the upstream baseline is also far from golden.

| Example | Parity | Quality | Result→Golden | Ref→Golden | Final | Final-Quality | Rules | Warnings |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `GLM-4.5V_Page_1` | 0.96 | 0.9115 | 0.9115 | 0.9308 | 0.9569 | 0.0454 | 0/0 fail |  |
| `GLM-4.5V_Pages_1_2_3` | 0.9494 | 0.8454 | 0.8454 | 0.8743 | 0.944 | 0.0986 | 0/7 fail |  |
| `code` | 0.8985 | 0.8153 | 0.8153 | 0.8406 | 0.8708 | 0.0554 | 1/3 fail |  |
| `handwritten` | 0.9109 | 0.7842 | 0.7842 | 0.7967 | 0.9609 | 0.1768 | 0/1 fail | inflation |
| `page` | 0.7829 | 0.4486 | 0.4486 | 0.5148 | 0.716 | 0.2674 | 1/1 fail | inflation |
| `paper` | 0.9629 | 0.7316 | 0.7316 | 0.7343 | 0.9329 | 0.2013 | 1/2 fail | inflation |
| `seal` | 0.9804 | 0.9875 | 0.9875 | 0.9875 | 0.9804 | -0.0071 | 0/0 fail |  |
| `table` | 0.9944 | 1.0 | 1.0 | 1.0 | 0.9944 | -0.0056 | 0/0 fail |  |

## Per-example notes

### `GLM-4.5V_Page_1`

- parity.text_fidelity: 0.9821
- parity.critical_structure: 0.952
- parity.decorative_style: 0.75
- quality_overall: 0.9115
- final_overall: 0.9569
- final_minus_quality: 0.0454

### `GLM-4.5V_Pages_1_2_3`

- parity.text_fidelity: 0.9701
- parity.critical_structure: 0.9423
- parity.decorative_style: 0.75
- quality_overall: 0.8454
- final_overall: 0.944
- final_minus_quality: 0.0986
- rules:
  - [pass] page1_start: Page 1 start matched expected content.
  - [pass] page1_end: Page 1 end matched expected content.
  - [pass] page2_start: Page 2 start matched expected content.
  - [pass] page2_end: Page 2 end matched expected content.
  - [pass] page3_start: Page 3 start matched expected content.
  - [pass] page3_end: Page 3 end matched expected content.
  - [pass] page2_page3_continuation: Continuation across pages 2 -> 3 matched.

### `code`

- parity.text_fidelity: 0.8716
- parity.critical_structure: 0.9471
- parity.decorative_style: 0.8804
- quality_overall: 0.8153
- final_overall: 0.8708
- final_minus_quality: 0.0554
- rules:
  - [fail] local_jndi_name_tag: Missing required phrase: '<local-jndi-name>AddressHomeLocal</local-jndi-name>'.
  - [pass] weblogic_rdbms_bean_tag: Found required phrase for weblogic_rdbms_bean_tag.
  - [pass] key_cache_size_value: Found required phrase for key_cache_size_value.

### `handwritten`

- parity.text_fidelity: 0.8865
- parity.critical_structure: 0.9401
- parity.decorative_style: 1.0
- quality_overall: 0.7842
- final_overall: 0.9609
- final_minus_quality: 0.1768
- warning: final_overall significantly exceeds quality_overall (parity-first inflation). (value=0.1768, threshold=0.15)
- rules:
  - [pass] corrected_phrase: Found required phrase for corrected_phrase.

### `page`

- parity.text_fidelity: 0.6993
- parity.critical_structure: 0.8951
- parity.decorative_style: 1.0
- quality_overall: 0.4486
- final_overall: 0.716
- final_minus_quality: 0.2674
- warning: final_overall significantly exceeds quality_overall (parity-first inflation). (value=0.2674, threshold=0.15)
- rules:
  - [fail] glue_strength_constant: Missing required phrase: '0.2\\mathrm{N} / \\mathrm{mm}^{2}'.

### `paper`

- parity.text_fidelity: 0.9698
- parity.critical_structure: 0.9459
- parity.decorative_style: 1.0
- quality_overall: 0.7316
- final_overall: 0.9329
- final_minus_quality: 0.2013
- warning: final_overall significantly exceeds quality_overall (parity-first inflation). (value=0.2013, threshold=0.15)
- rules:
  - [fail] not_divisible_by_Q: Missing required phrase: 'not divisible by Q'.
  - [pass] laplacian_operator: Found required phrase for laplacian_operator.

### `seal`

- parity.text_fidelity: 1.0
- parity.critical_structure: 0.944
- parity.decorative_style: 1.0
- quality_overall: 0.9875
- final_overall: 0.9804
- final_minus_quality: -0.0071

### `table`

- parity.text_fidelity: 1.0
- parity.critical_structure: 0.9841
- parity.decorative_style: 1.0
- quality_overall: 1.0
- final_overall: 0.9944
- final_minus_quality: -0.0056
