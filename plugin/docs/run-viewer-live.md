# Live pages and saved reports

The [run viewer](run-viewer.md) shows a run while it builds, through `swiftgate view`, and after it ends,
through the report folder `swiftgate report --html` writes.

## A run's end

A run is done once `build finish`'s end is its newest ledger event; a ledger event after it, as in a resumed
build or a fix loop after a red `final`, makes it running again. `build start` marks the run's `run.json`
with `endsAtFinish`; a run whose record lacks the mark, written before `build finish` recorded its end, or
that has no record, is done at a GREEN final gate. `build finish` and `run report` write the report folder each time,
naming it in their output. A report of a run not done carries `snapshotAt`, and its header reads "Snapshot
at <time>, run still <state>".

Until the run ends, a file it writes as it goes and hasn't yet, its ledger log or its spec page, reads "not
written yet" under the footer and isn't damage; still missing at the end, it is. A plan with no `plan.json`
names no spec page: no damage, and the Spec tab says so.

## Live mode

`view` answers `GET /`, `/view.json`, `/final`, `/server` and each flow's linked `/runs/` file; else
404. A request whose `Host` isn't `127.0.0.1` or `localhost` at its port gets 403, so a page
elsewhere can't reach it through a rebound name.

The page polls `/view.json?after=<token>` each second, naming the token of the view it holds. The
server answers 204 when none of the run's files moved since that token, and otherwise the whole
view under a new token, which the page puts in place of its own. An unknown token gets the whole
view. A redraw keeps the open tab, scroll, popover and drawer. The page keeps polling after a
failure, which it shows under the title. A now strip shows each running task's open phase, elapsed
time and last event age, a stall badge once `stallMin` passes with no event of that task, and a
halt badge until the resume. `stallMin` is the preset's `stall_min`, or 15, the value `build next`
hands the stall watch.

Once the run is done and `report --html` has written its final report, the view's `finalReport` is `/final`, which
serves that report, and the page shows an end banner linking it in place of the now strip. A ledger
line after the report, as in a resumed build, takes both back.

## The live server

`swiftgate view --ensure` prints the URL of the repository's live viewer and nothing else. It
reuses the server that `swift-harness/view-server.json` in the git common dir names while that
server answers `/server` with its own pid. Otherwise it starts `view --detached` from the main
checkout, in a session of its own, on the saved port when it's free, and waits for the server to
save its port and pid. The server's output goes to `view-server.log` beside the record.

The server follows the newest build run of any plan, and answers `/view.json` with 503 until one
exists. It exits 10 minutes after the run's final report exists, or after 2 hours with no request
and no change to the run. `SWIFTGATE_VIEW=off`, or `0`, `false` or `no`, starts nothing and prints
no URL, only a note on stderr.

The build skill calls `view --ensure` after `build start`, and the run skill at launch; each
prints `Live: <url>`.

## What a poll reads

The reader reads events from a day before the build run's start, or from an older gate run the
run names or the plan's launch, so a store's sealed history stays shut. The reader leaves out an
event of the run from more than a day before its start, such as the usage of a session that began
a day before `build start`.
