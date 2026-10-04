# Simulator QA

How `swiftgate sim verify` judges a run's steps, how `swiftgate sim down` ends a run, how
`swiftgate qa lint` checks flow files, and how `swiftgate qa run` and `swiftgate qa adopt` treat a
plan's validation rows. Their rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

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

Each judged run writes `sim/report.json` with keys `schemaVersion`, `command`, `runID`, `verdict`,
`stepCount`, `headCommit` (the commit `sim up` built), `checkoutHead`, `blocked` and `findings`,
each `{rule, step, path, message}` with `path` relative to `sim/`. Unknown values are `null`. It
also appends a `sim verify` line to the runs history with the run id and verdict.

## qa lint

`swiftgate qa lint <flow file>... [--json]` checks `agent-device batch` steps files offline, before
any device boots (simulator QA amendment §6.1). A steps file is a JSON list of
`{"command": "<name>", "input": {...}}` steps. The rules check each step against the step schemas
the pinned `agent-device` reports from its MCP `tools/list`, which ship as
`qa/agent-device-schemas-<pin>.json` in the plugin. They check each `id="…"` selector against the raw
values of the 1 `enum AccessibilityID: String` in the Swift file `[qa] accessibility_ids` names. The
rules never read strings under `text` and `value`, which hold app content, as selectors or refs.

The verdict is RED (exit 1) on any finding but the note, and BLOCKED (exit 2) when:

- the plugin root (`SWIFTGATE_HARNESS_ROOT`) is unset;
- the schema file is missing, doesn't parse, uses a schema keyword the reader doesn't support or
  records another version than the pin;
- `.swiftgate.toml` doesn't load;
- the configured id file doesn't read or holds no single String-backed `AccessibilityID` enum with
  plain string raw values;
- or a flow file doesn't read.

## qa run

`swiftgate qa run [--plan <slug>] [--after <task>] [--at-base] [--json]` runs the rows of a plan's
validation.json (simulator QA amendment §6, §6.2). Without `--plan` it takes the 1 plan holding a
validation.json; with none it is GREEN with a note, and with several it exits 2 naming them. A row
runs once every `Runs after` task is `done` in the ledger, the `--after` task counting as merged;
`--after` keeps only the rows that name it, and a row with an unmerged task reads `waiting`.

Rows run in the current checkout in layer order, acceptance, then flow, then state, and a layer with
a red row leaves every later row `unverified`. An acceptance or state check is a shell command run by
`/bin/sh -c`, or a file under the plan's state directory such as `qa/<name>.state.sh`, run as its own
program when executable and by `/bin/sh` otherwise. Each gets `QA_PORT`, a loopback port the OS
assigned that run, `QA_DIR`, the plan's `qa/` folder, and `QA_EVIDENCE_DIR`, the run's `qa/` folder.

Exit 0 is `pass`; any other exit, a signal or the 10-minute timeout is `red`; a check that couldn't
start is `unverified`. Only the exit status decides: a screenshot, tree or log beside a row never
passes it. A flow row reads `unverified` with "flow runner not built", and a state row runs only once
every flow row for its requirement passed.

`--at-base` runs every row, whatever its tasks, at the merge base of `HEAD` and `main` (a brownfield
clone's plan branch) in a scratch worktree, with no layer stop, and records each failure's exit
status.

The run writes `.harness/runs/<runID>/qa/report.json`, each row's command, exit status, stdout and
stderr in `qa/<NN>-<requirement>.<layer>.txt`, and 1 qa.check event per row.

## qa adopt

`swiftgate qa adopt <worktree> [--json]` replaces each plan's `qa/` folder in plan state with a copy
of `<worktree>/.harness/qa/<plan>/`. It exits 1 and copies nothing for a path that isn't a checkout
of this repository, a worktree with no prepared folder, or a folder naming no plan.

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

A close that fails, a session still listed, or a failed release is `sim.driver-failed`: BLOCKED
(exit 3) after the device is given back, with each problem appended to `sim/agent-device.log`. A
lease that can't be removed, or a holder or device still there after the wait, is
`swiftgate.environment` (exit 3).

With no lease left, `sim down` does nothing and exits 0, so a second call is harmless. The JSON is
`{schemaVersion, verdict, released, runID, udid, notes}`; `notes` names an unreadable lease or a
session listing that failed, and never fails the call.

`swiftgate gc`, and the orphan sweep each `sim hold` runs before taking a device, run the same
`device release --stale --udid` on every orphaned device they delete. An `agent-device` that can't
be launched is skipped; any other failure is a `gc` error.
