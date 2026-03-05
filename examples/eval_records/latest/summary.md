# Example evaluation summary

- fail_under: disabled

| Example | Parity | Result→Golden | Ref→Golden | Final | Rules |
|---|---:|---:|---:|---:|---:|
| `GLM-4.5V_Page_1` | 0.873 | None | None | 0.873 | 0/0 fail |
| `GLM-4.5V_Pages_1_2_3` | 0.8763 | 0.8886 | 0.923 | 0.8732 | 0/7 fail |
| `code` | 0.7675 | 0.7185 | 0.727 | 0.7671 | 0/0 fail |
| `handwritten` | 0.9277 | 0.96 | 0.955 | 0.9777 | 0/1 fail |
| `page` | 0.728 | 0.5223 | 0.6078 | 0.7141 | 0/0 fail |
| `paper` | 0.965 | 0.706 | 0.709 | 0.965 | 0/0 fail |
| `seal` | 0.9804 | 0.9808 | 0.9808 | 0.9804 | 0/0 fail |
| `table` | 0.9944 | 1.0 | 1.0 | 0.9944 | 0/0 fail |

## Per-example notes

### `GLM-4.5V_Page_1`

- parity.text_fidelity: 0.944
- parity.critical_structure: 0.7688
- parity.decorative_style: 0.75
- final_overall: 0.873

### `GLM-4.5V_Pages_1_2_3`

- parity.text_fidelity: 0.9434
- parity.critical_structure: 0.7793
- parity.decorative_style: 0.75
- final_overall: 0.8732
- rules:
  - [pass] page1_start: Page 1 start matched expected content.
  - [pass] page1_end: Page 1 end matched expected content.
  - [pass] page2_start: Page 2 start matched expected content.
  - [pass] page2_end: Page 2 end matched expected content.
  - [pass] page3_start: Page 3 start matched expected content.
  - [pass] page3_end: Page 3 end matched expected content.
  - [pass] page2_page3_continuation: Continuation across pages 2 -> 3 matched.

### `code`

- parity.text_fidelity: 0.7681
- parity.critical_structure: 0.7502
- parity.decorative_style: 0.8804
- final_overall: 0.7671

### `handwritten`

- parity.text_fidelity: 0.9403
- parity.critical_structure: 0.8959
- parity.decorative_style: 1.0
- final_overall: 0.9777
- rules:
  - [pass] corrected_phrase: Found required phrase for corrected_phrase.

### `page`

- parity.text_fidelity: 0.705
- parity.critical_structure: 0.7285
- parity.decorative_style: 1.0
- final_overall: 0.7141

### `paper`

- parity.text_fidelity: 0.9733
- parity.critical_structure: 0.9457
- parity.decorative_style: 1.0
- final_overall: 0.965

### `seal`

- parity.text_fidelity: 1.0
- parity.critical_structure: 0.944
- parity.decorative_style: 1.0
- final_overall: 0.9804

### `table`

- parity.text_fidelity: 1.0
- parity.critical_structure: 0.9841
- parity.decorative_style: 1.0
- final_overall: 0.9944
