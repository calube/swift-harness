# Calibrate design fixtures

Each file here is copied unmodified from a real `swiftgate calibrate design` run.

## `kept-sonnet.json`

The served-models file the run kept beside a sonnet agent's reply: what `--model sonnet` resolved to on
2026-09-30, after the alias moved. Captured from the repository root with:

```sh
plugin/bin/swiftgate calibrate design
cp .harness/runs/20260930T165620Z-3e9dd0fa/calibrate-design/design-lane-codebase/code-fact-question.json \
  plugin/gate/Tests/Fixtures/CalibrateDesign/kept-sonnet.json
```
