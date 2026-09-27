# `ledger set` self-test seeds

Each case's `ledger.json` is hand-authored plan-state data, staged under a throwaway plan
directory. `set.json` names the task and the status to move it to. The runner makes the change
through the ledger writer `ledger set` uses. A refusal that still rewrote the ledger is reported as
`ledger-set.written-despite-refusal`.

`done-to-pending` tries to move a `done` task back to `pending`. `valid` moves a `pending` task to
`in-progress`.
