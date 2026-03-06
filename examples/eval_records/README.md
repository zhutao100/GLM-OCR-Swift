# Example eval records

This folder holds a **persistent, repo-local record** of the latest run of the
scored evaluator in `tools/example_eval/`.

The goal is to make agentic workflows fast and actionable:

- a stable “baseline” exists in git history (for deltas)
- the current working tree can record a new run under a known path
- the record contains a short, actionable report pointing to likely fix areas

## How to refresh (agentic loop)

From the repo root:

```bash
scripts/verify_example_eval.sh
```

This runs the verification sequence:

1. Ensure `examples/result/` is up-to-date (refreshes via `scripts/run_examples.sh` when needed).
2. Run `tools/example_eval` from the repo root (writes to `.build/example_eval/`).
3. Copy + summarize into `examples/eval_records/latest/`, and compute a delta vs the baseline in git.

## Record layout

`examples/eval_records/latest/` is **overwritten** each time.

Key files:

- `examples/eval_records/latest/agent_report.md` — agent-focused summary + “Signals” + fix hints.
- `examples/eval_records/latest/delta_from_baseline.md` — per-example `final_overall` deltas vs baseline.
- `examples/eval_records/latest/summary.md` / `summary.json` — raw evaluator summary copy.
- `examples/eval_records/latest/meta.json` — git/tooling metadata plus the captured example-run contract.
- `examples/eval_records/latest/examples/<name>/report.md` / `report.json` — per-example evaluator reports.

The agent report header also records the `glm_snapshot`, `layout_snapshot`, and `generation_preset` when `examples/result/.run_examples_meta.json` is available.

## Baseline semantics (how deltas work)

`scripts/example_eval_record.py` reads the baseline summary from git using:

```text
git show <baseline-ref>:examples/eval_records/latest/summary.json
```

The default `<baseline-ref>` is `HEAD`, which is “before code changes” for an
agentic edit session (until you commit).

To keep deltas meaningful over time:

- commit `examples/eval_records/latest/` when you accept a new baseline
- run `scripts/verify_example_eval.sh` after code changes to see improvements/regressions vs that baseline
