This folder contains **opt-in** golden fixtures for `DocLayoutAdapterTests`.

By default, `swift test` **does not** require these fixtures.

To generate the PP-DocLayoutV3 forward-pass golden fixture:

```bash
python3 scripts/generate_ppdoclayoutv3_golden.py --model-folder "$LAYOUT_SNAPSHOT_PATH" --device mps
```

To generate a CPU/float32 fixture (useful to separate dtype vs porting issues):

```bash
PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py \
  --model-folder "$LAYOUT_SNAPSHOT_PATH" \
  --device cpu \
  --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v1.json
```

To generate CPU/float32 intermediate parity fixtures:

- v3 (pre-decoder intermediates)

```bash
PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py \
  --model-folder "$LAYOUT_SNAPSHOT_PATH" \
  --device cpu \
  --include-intermediates \
  --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v3.json
```

- v4 (decoder layer-0 intermediates)

```bash
PYENV_VERSION=venv313 pyenv exec python3 scripts/generate_ppdoclayoutv3_golden.py \
  --model-folder "$LAYOUT_SNAPSHOT_PATH" \
  --device cpu \
  --include-decoder-intermediates \
  --out Tests/DocLayoutAdapterTests/Fixtures/ppdoclayoutv3_forward_golden_cpu_float32_v4.json
```

Then run the golden check:

```bash
LAYOUT_SNAPSHOT_PATH=<path-to-snapshot> LAYOUT_RUN_GOLDEN=1 swift test
```

To run just the CPU/float32 golden test:

```bash
LAYOUT_SNAPSHOT_PATH=<path-to-snapshot> LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3GoldenFloat32IntegrationTests
```

To run just the intermediate parity tests (v3 + v4):

```bash
LAYOUT_SNAPSHOT_PATH=<path-to-snapshot> LAYOUT_RUN_GOLDEN=1 swift test --filter PPDocLayoutV3IntermediateParityIntegrationTests
```
