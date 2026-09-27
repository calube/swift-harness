# `plan-lint` self-test seeds

Each case's `design.md` and `ledger.json` are hand-authored plan-state data, not captured tool
output. The runner stages the shared `Sample` package (library modules `Core` and `Other`, and
`Core`'s test target `CoreTests`) alongside them in a throwaway repo, writes
`plan.json`/`ledger.json` under that repo's own common dir the way `plan claim` would, and calls
`plan-lint`'s own run function. An optional `bounds.toml` fragment is appended under the generated
`.swiftgate.toml`'s `[plan]` table for a case that needs a tighter bound than the defaults.

`overlapping-wave` reds on both `plan-lint.write-set-overlap` and `plan-lint.waves-mismatch`, never
`write-set-overlap` alone: `PlanSchedule.schedule` always places two colliding-write-set tasks in
different buckets, so any stored `waves` that groups them together has already diverged from the
schedule it would recompute.

`design-moved` adds an `amended.md`, which the runner commits over the design after the plan is
made from `design.md`. The design at HEAD then no longer hashes to the plan's designSha.

`covered-test-untested` covers a T3 test but leaves it out of `tests`. The gate is still read from
`covers`, so `fast` is too weak. `unknown-test` misspells its `tests` id. `duplicate-task-id`
repeats a task id, which is a finding rather than a trap.

Every case's task carries `"model": "sonnet"` except `missing-model`, which omits the field to
prove the rule fires on an untagged task.

`own-test-target` writes `Core` and `CoreTests`, which count as one module, so it's green.
`two-modules` writes `Core` and `Other` and reds on `plan-lint.too-many-modules`.

`done-task-renamed-test` is a replan after an amend renamed `test-alpha-old` to `test-alpha`: the
`done` task still names the old id and carries no `model`, and a fix task covers the new id. A done
task is history (spec §5.7, §8.4), so it's judged only on the graph and coverage, and the case is
green.
