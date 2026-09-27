# `build check-return` self-test seeds

Each case's `return.json` is a hand-authored task return. The runner builds a throwaway repository
the way the build loop leaves it: a task worktree on `self-test-build/queue-core` with one commit
and one GREEN `check push` run in its run store, an `elsewhere` branch whose commit the task
branch never reaches, the plan's ledger and a build run. It then substitutes `{{taskCommit}}`,
`{{offBranchCommit}}` and `{{gateRunId}}` with the real values and calls `build check-return`'s own
run function.

`commit-off-branch` also names the `elsewhere` commit. `gate-run-missing` cites a run id that isn't
in the worktree's history. `valid` names only the task's commit and its real gate run.
