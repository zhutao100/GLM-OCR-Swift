# GLMOCRCLI

`GLMOCRCLI` is the supported command-line interface for running OCR locally on macOS. It accepts images and PDFs and prints Markdown to stdout.

For the authoritative flag list and current defaults, run:

```bash
swift run GLMOCRCLI --help
```

## Common usage

OCR an image to Markdown:

```bash
swift run GLMOCRCLI --input examples/source/page.png > out.md
```

OCR a PDF (all pages by default) and restrict pages explicitly:

```bash
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Pages_1_2_3.pdf > out.md
swift run GLMOCRCLI --input examples/source/GLM-4.5V_Pages_1_2_3.pdf --pages 1-2 > out.md
```

Download model snapshots without running inference:

```bash
swift run GLMOCRCLI --download-only
```

## Modes

### Non-layout mode

- Default for non-PDF inputs (unless `--layout` is passed).
- Uses a single OCR prompt for the entire input.
- `--task` selects the task preset: `text`, `formula`, `table`, or `json`.

### Layout mode (region-aware)

- Default for PDFs (disable with `--no-layout`).
- Runs `PaddlePaddle/PP-DocLayoutV3_safetensors` to detect page regions, then OCRs each region and merges them in reading order.
- `--task` is ignored in layout mode (the CLI will print a note if you pass a non-`text` task).
- Enables JSON exports:
  - `--emit-json`: canonical “block-list” JSON (examples-compatible)
  - `--emit-ocrdocument-json`: structured `OCRDocument` JSON

Example:

```bash
swift run GLMOCRCLI --layout --input examples/source/table.png \
  --emit-json out.blocks.json \
  --emit-ocrdocument-json out.ocrdocument.json > out.md
```

## Outputs

- Markdown is printed to stdout; redirect it to a file (for example `> out.md`).
- JSON exports are written to the provided paths and require layout mode.

### Cropped images for Markdown placeholders

In layout mode, Markdown may contain image placeholders for cropped regions. When you pass `--emit-json` or `--emit-ocrdocument-json`, the CLI uses the output directory to write crops under `imgs/` and rewrites the Markdown to point at those files. Without an export directory, the placeholders remain unresolved.

## Models, downloads, and cache

Inference runs locally. The only network dependency is downloading model snapshots when they are not already present on disk.

### Default model IDs

Defaults are defined in the CLI and may evolve; check `--help` for the current values.

Key defaults (from `--help`):

- `--model`: `zai-org/GLM-OCR`
- `--revision`: `main`
- `--layout-model`: `PaddlePaddle/PP-DocLayoutV3_safetensors`
- `--layout-revision`: `main`
- `--task`: `text`
- `--max-new-tokens`: `2048`
- `--generation-preset`: `default-greedy-v1` (also supports `parity-greedy-v1`)
- `--layout-parallelism`: `auto`

### Cache directory resolution

`VLMRuntimeKit` resolves the Hugging Face hub cache directory in this order:

1. `--download-base`
2. `HF_HUB_CACHE`
3. `HF_HOME` + `/hub`
4. `~/.cache/huggingface/hub`

### Snapshot overrides

You can bypass cache lookup/download by pointing directly at a local snapshot folder:

- `GLMOCR_SNAPSHOT_PATH` — preferred local snapshot for GLM-OCR loads
- `LAYOUT_SNAPSHOT_PATH` — preferred local snapshot for PP-DocLayout-V3 loads

## See also

- [README.md](../../README.md) — user-facing overview and quickstart
- [examples/README.md](../../examples/README.md) — example corpus contract and parity tooling
- [docs/golden_checks.md](../golden_checks.md) — opt-in parity and model-backed verification
