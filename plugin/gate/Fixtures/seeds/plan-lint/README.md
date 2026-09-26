# `plan-lint` self-test seeds

Each case's `design.md` and `ledger.json` are hand-authored plan-state data, not captured tool
output. The runner stages the shared `Sample` package (one library module, `Core`) alongside them
in a throwaway repo, writes `plan.json`/`ledger.json` under that repo's own common dir the way
`plan claim` would, and calls `plan-lint`'s own run function. An optional `bounds.toml` fragment is
appended under the generated `.swiftgate.toml`'s `[plan]` table for a case that needs a tighter
bound than the defaults.

`overlapping-wave` reds on both `plan-lint.write-set-overlap` and `plan-lint.waves-mismatch`, never
`write-set-overlap` alone: `PlanSchedule.schedule` always places two colliding-write-set tasks in
different buckets, so any stored `waves` that groups them together has already diverged from the
schedule it would recompute.

`design-moved` adds an `amended.md`, which the runner commits over the design after the plan is
made from `design.md`. The design at HEAD then no longer hashes to the plan's designSha.

`covered-test-untested` covers a T3 test but leaves it out of `tests`. The gate is still read from
`covers`, so `fast` is too weak. `unknown-test` misspells its `tests` id. `duplicate-task-id`
repeats a task id, which is a finding rather than a trap.
