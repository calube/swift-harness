# `build next` self-test seeds

Each case's `ledger.json` is hand-authored plan-state data. The runner schedules it as `build next`
does, with the ledger's `in-progress` tasks as the running set and a budget phase of `normal`, and
names why each `pending` task it didn't start was held.

`unmerged-dependency` holds `feature` because its dependency `core` is still `in-progress`, not
`done`. `overlapping-write-sets` has two ready tasks whose write sets collide, so only one starts.
`valid` has two ready tasks with disjoint write sets, and both start.
