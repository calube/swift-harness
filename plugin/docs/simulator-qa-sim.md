# Simulator QA sessions

How `swiftgate sim up` reuses its build, how `sim verify` judges a run's steps and how `sim down`
ends a run. Flow files and validation rows (`qa lint`, `qa run`, `qa adopt`) are in
[`simulator-qa.md`](simulator-qa.md).
Rule ids are in [`standards.md` § Rule id index](standards.md#rule-id-index).

## sim up builds

`sim up` builds into 1 DerivedData folder per worktree, `derived-data/sim-up/` under its state
root, and stamps a good build with HEAD and the uncommitted changes outside `.harness/`. A later
`sim up` with the same stamp installs those products without building, and says so in its
`sim/build.log`.

## sim verify

`swiftgate sim verify [<runID>] [--json]` judges the evidence `sim snap` recorded (simulator QA
§5.2). It reads only the run's `sim/` folder and the checkout's HEAD, and never touches the device.
Without `<runID>` it takes this worktree's newest run whose holder is alive. It judges a named run
from its folder even after `sim down`, but a lease that names another worktree is `sim.not-owner`
(RED, exit 1), and it writes nothing.

The verdict is GREEN (exit 0), RED (exit 1) on any finding, or BLOCKED (exit 2) when `session.json`
or `steps.ndjson` doesn't read, git can't name HEAD, or the caller named no run and none is live.
A RED finding outranks BLOCKED.

Each step's tree must also show every button, switch, text field and cell with an accessibility
identifier (`sim.a11y-identifier`) and a readable label (`sim.a11y-label`). A label is readable when
it holds more than whitespace and differs from the identifier. Static text, images and containers
need neither. These 2 rules check standards §7 on the screen the app drew, so an icon-only
button with no `.accessibilityLabel` fails here even when review missed it.

`sim snap` records each step's `appState` from `agent-device appstate`. When it finds the app
`notRunning`, it keeps the step with its screenshot and no tree, and exits 1 with `sim.app-exited`.
`sim verify` reports that step as `sim.app-exited`, naming the run's next crash report in
`sim/crashes/`, and reports any crash report no step claimed. It skips reports of another app,
another device or an earlier run. `sim down` copies the reports, so run `sim verify` after it to
name them.

Each judged run writes `sim/report.json` with keys `schemaVersion`, `command`, `runID`, `verdict`,
`stepCount`, `headCommit` (the commit `sim up` built), `checkoutHead`, `blocked` and `findings`,
each `{rule, step, path, message}` with `path` relative to `sim/`. Unknown values are `null`. It
also appends a `sim verify` line to the runs history with the run id and verdict.

## sim down

`swiftgate sim down [<runID>] [--json]` ends a QA run (simulator QA design §4, §7.4). Without
`<runID>` it takes this worktree's newest lease, whether or not its holder is alive. In order:

1. A lease from another worktree is `sim.not-owner`: RED (exit 1), and nothing is touched.
2. `agent-device close` on the lease's session and device, then `session list` must no longer name
   the session. `SESSION_NOT_FOUND` or `DEVICE_NOT_FOUND` from `close` counts as closed.
3. The lease is removed, so the `sim hold` process deletes the device and frees the `sim` slot.
   `sim down` waits up to 2 minutes for the holder to exit and the device to go. If the holder
   died holding it, `sim down` deletes that one device, which is named for the dead PID.
4. `agent-device device release --stale --udid <udid>` clears claims whose owner is dead.
5. It copies into `sim/crashes/` each `.ips` crash report of the run's app on its device since
   `startedAt`, from the user's `DiagnosticReports` log folder. A report lands seconds after its
   crash, so with fewer reports than recorded exits it waits up to 30 s, then notes the shortfall.

A close that fails, a session still listed, or a failed release is `sim.driver-failed`: BLOCKED
(exit 3) after the device is given back, with each problem appended to `sim/agent-device.log`. A
lease that can't be removed, or a holder or device still there after the wait, is
`swiftgate.environment` (exit 3).

With no lease left, `sim down` does nothing and exits 0, so a second call is harmless. The JSON is
`{schemaVersion, verdict, released, runID, udid, crashReports, notes}`; `notes` names an
unreadable lease, a session listing that failed or a crash report it couldn't copy, and never fails
the call.

`swiftgate gc`, and the orphan sweep each `sim hold` runs before taking a device, run the same
`device release --stale --udid` on every orphaned device they delete. An `agent-device` that can't
be launched is skipped; any other failure is a `gc` error.
