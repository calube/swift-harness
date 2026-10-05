# Validation rows in the run viewer

The [run viewer](run-viewer.md)'s Validation tab shows what `swiftgate qa run` found for the plan's
validation rows during 1 build run. Read this page to know which `qa run` results the tab keeps,
what each part of the tab shows, and how it links evidence. The tab shows once a `qa run` checked a
row, and reads only what that command wrote: nothing here runs a check.

## What it reads

The reader keeps a `qa.check` event, and a qa.flow event with a row, when it names the build run's
plan and its `qa run` started at or after the build run and before the plan's next build run. It
keeps a qa.flow with no row, a kept XCUITest flow, when its gate run is the build run's. For each kept
`qa run` it reads `runs/<run id>/qa/report.json` from the main checkout's state root, the clone's
kept runs or a live task worktree, and each red row's `.txt` evidence as saved output, at most its
last 16 KB. In a brownfield clone, `run checkout remove` keeps the plan checkout's runs in the git
common dir's state root, whatever a committed config in the user's tree picks.

Each row shows its newest result outside the merge base. A `qa run --at-base` should fail every
row, so it sets a row's result only when no other `qa run` checked the row, which then reads "at
base", counted apart from red; it never draws a timeline bar. Each row keeps every `qa run` that
checked it, newest first: its stage (at base, after a task, final, or plain), result, reason, saved
output, flow, and the prepared at-base run a reused check took its result from.

## The tab

- **Strip.** Counts of pass, red, unverified and waiting rows, and abandoned and at-base rows
  when any. The tab's badges carry every count but pass and at base, so a red check shows from any
  tab.
- **Runs.** A row more than 1 `qa run` checked, or 1 at base only, lists each run under it, newest
  first, marking the run the row shows. An earlier red run has its own Why button, and an earlier
  flow its steps and links.
- **Groups.** Rows group by the tasks they run after, in ledger order; a row that runs after several
  tasks shows under each. A waiting row ends each of its groups as "waiting on <task>". A row whose
  report didn't read sits under "no task named".
- **Why it failed.** A red row's button opens its requirement, layer, check, exit status, reason,
  evidence paths and the last 12 lines of its saved output.
- **Why unverified.** An unverified row's button names the check that didn't run and why, such as a red
  row in an earlier layer, or a flow row that ran with no flow runner (`flow runner not built`).
- **Why unverified** also opens on a passing flow row whose final pass left no video or no contact
  sheet, naming which and why, such as a recorder busy past the 5-minute bound.
- **Flow rows.** A flow row lists its steps with a pass or fail mark. Each step links to the video at
  its offset, `video.mp4#t=<seconds>`, and the row links the video and the contact sheet. A red flow's
  Why popover names its failing step.
- **Kept flows.** Each kept XCUITest flow's newest record lists under "Kept flows", by `[[flows]]`
  entry, then test, with its gate run, task and steps linked the same way.
- **Task details.** A task's popover lists the rows that run after it, each with its Why button.
- **Timeline.** Each check that answered, pass or red, is a `qa.check` bar ending when its `qa run`
  recorded it; a red bar's failure reason names the row, layer and exit status. A flow's bar carries 1
  tick per step, linked to the video at that offset.

## Evidence and privacy

Each row lists its evidence by path and never embeds it: the page holds no image or video. A report links
`runs/<run id>/<path>` in its own folder, where `report` copies each file the view links, videos and sheets
first, up to 256 MB, so its links work wherever the folder goes. A result bundle stays behind for its
`.tests.json` summary. A file it can't copy is a footer line, named without a link. A live page links
`../runs/<run id>/<path>`, and its server answers each linked file and 404s any other.

Every string passes the payload guard. A check, reason, step label,
test name or path the guard rejects, or a path that leaves its run directory, drops out as a footer
line naming the `qa run` and row, or the gate run and kept flow. Output lines lose machine paths and stay
1 line each. A missing or undecodable report, and an evidence path that leaves its run directory, are
footer lines too; the reader never follows such a path.
