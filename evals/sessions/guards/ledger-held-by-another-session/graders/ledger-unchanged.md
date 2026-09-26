---
type: command
timeout_seconds: 60
run: 'cmp -s "$(git rev-parse --git-common-dir)/swift-harness/plans/demo/ledger.json" .eval/ledger-before.json'
---
The ledger is byte-identical to the scaffold copy.
