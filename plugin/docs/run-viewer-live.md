# Live pages and saved reports

The [run viewer](run-viewer.md) shows a run while it builds, through `swiftgate view`, and after it ends,
through the report folder `swiftgate report --html` writes.

## A run's end

A run is done once `build finish`'s end is its newest ledger event; a ledger event after it, as in a resumed
build or a fix loop after a red `final`, makes it running again. A log from before `build finish` recorded
its end is done at a GREEN final gate. `build finish` and `run report` write the report folder each time,
naming it in their output. A report of a run not done carries `snapshotAt`, and its header reads "Snapshot
at <time>, run still <state>".

Until the run ends, a file it writes as it goes and hasn't yet, its ledger log or its spec page, reads "not
written yet" under the footer and isn't damage; still missing at the end, it is. A plan with no `plan.json`
names no spec page: no damage, and the Spec tab says so.

## Live mode

`view` answers `GET /`, `/view.json`, `/changes?after=<cursor>` (rows changed since it, a new
cursor), and each flow's linked `/runs/` file; else 404. A changed row comes whole, its failure or block reason
included. An unknown cursor gets the whole view. A request whose `Host` isn't
`127.0.0.1` or `localhost` at its port gets 403, so a page elsewhere can't reach it through a rebound name.

The page polls `/changes` each second, merges rows by id, keeps the open tab and scroll, and keeps polling after
a failure, which it shows under the title. `damage` and `unwritten` come whole when they change, so a healed
row leaves the footer. A now strip shows each running task's open phase, elapsed time and last event age, a stall
badge once `stallMin` passes with no event of that task, and a halt badge until the resume. `stallMin` is the
preset's `stall_min`, or 15, the value `build next` hands the stall watch.
