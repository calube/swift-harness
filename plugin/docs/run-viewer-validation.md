# Validation rows in the run viewer

The [run viewer](run-viewer.md)'s Validation tab shows what `swiftgate qa run` found for the plan's
validation rows during 1 build run. It shows once a `qa run` checked a row, and reads only what that
command wrote: nothing here runs a check.

## What it reads

The reader keeps a `qa.check` event when it names the build run's plan and its `qa run` started at or
after the build run and before the plan's next build run. For each such `qa run` it reads
`.harness/runs/<run id>/qa/report.json` from the main checkout or a live task worktree, and the saved
output of each red row's evidence file, at most its last 16 KB.

Each row shows its newest result. A `qa run --at-base` is expected to fail every row, so it neither sets
a row's result nor draws a timeline bar.

## The tab

- **Strip.** Counts of pass, red, unverified and waiting rows. The tab's badges carry the red,
  unverified and waiting counts, so a red check shows from any tab.
- **Groups.** Rows group by the tasks they run after, in ledger order; a row that runs after several
  tasks shows under each. A waiting row ends each of its groups as "waiting on <task>". A row whose
  report didn't read sits under "no task named".
- **Why it failed.** A red row's button opens its requirement, layer, check, exit status, reason,
  evidence paths and the last 12 lines of its saved output.
- **Why unverified.** An unverified row's button names the check that didn't run and why, such as a red
  row in an earlier layer, or a flow row before the flow runner exists.
- **Flow rows.** A flow row shows its result alone for now.
- **Timeline.** Each check that answered, pass or red, is a `qa.check` bar ending when its `qa run`
  recorded it; a red bar's failure reason names the row, layer and exit status.

## Evidence and privacy

Evidence is named by its path relative to the `qa run`'s run directory, never embedded: the page holds
no image or video. Every string passes the payload guard. A check, reason or evidence path the guard
rejects drops out as a footer line naming the `qa run` and row. Output lines lose machine paths and stay
1 line each. A missing or undecodable report, and an evidence path that leaves its run directory, are
footer lines too; the reader never follows such a path.
