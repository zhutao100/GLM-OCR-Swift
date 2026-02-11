This folder contains **opt-in** golden fixtures for `DocLayoutAdapterTests`.

By default, `swift test` **does not** require these fixtures.

To generate the PP-DocLayoutV3 forward-pass golden fixture:

```bash
python3 scripts/generate_ppdoclayoutv3_golden.py --model-folder "$LAYOUT_SNAPSHOT_PATH" --device mps
```

Then run the golden check:

```bash
LAYOUT_SNAPSHOT_PATH=<path-to-snapshot> LAYOUT_RUN_GOLDEN=1 swift test
```
