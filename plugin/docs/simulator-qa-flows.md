# Simulator QA flows

How `swiftgate qa run` checks a flow row (simulator QA amendment §6, §6.2, §8.2). The other rows and
the layer order are in [`simulator-qa.md`](simulator-qa.md#qa-run), and the session commands in
[`simulator-qa-sim.md`](simulator-qa-sim.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## Running a flow row

A flow row's check is a steps file in the plan's state, such as `qa/<name>.flow.json`. `qa run`
takes these steps, in this order:

1. It lints the file with the `qa lint` rules. A red lint makes the row `red` naming the rules, and
   no device starts; a lint that can't run (no plugin root, say) leaves the row `unverified`.
2. It runs `sim up` in the tree the row runs in, with the app's live dependencies. A failed
   `sim up` leaves the row `unverified`, naming its rule.
3. It runs 1 `agent-device batch --on-error stop` on the leased UDID and session. After each `wait`
   or `is` step it adds a `snapshot`, a `screenshot` and a second `snapshot`, so each assertion
   leaves a `sim/` step with its tree and PNG, as `sim snap` would. An `is text` step's value
   becomes that step's assert.
4. On a batch that exits 0 it runs the requirement's state rows while the device is up, if this is
   the requirement's last flow row. They get `QA_SIM_UDID`, `QA_SIM_SESSION`, `QA_SIM_BUNDLE_ID` and
   `QA_SIM_DIR` beside the usual variables.
5. It runs `sim down`, on every path once it has asked for `sim up`, a failed `sim up` included, so 1
   `qa run` holds at most 1 device.
6. It runs `sim verify` over the row's `sim/` folder. It runs after `sim down`, which copies the
   app's crash reports into `sim/crashes/`, so the report names an app exit.

The row passes only when the batch exits 0 and `sim verify` is GREEN. A failing step is `red`,
named by its number in the flow file, with any `sim verify` RED findings added. A steps file
`agent-device` refuses is `red`. A `sim verify` RED is `red` with its findings. A driver or machine failure, or a failed capture `qa run` added,
is `unverified`. A state row behind a flow that isn't `pass` reads `unverified`, even when it ran on
the device first. `--at-base` runs flow rows too, in the scratch tree, and runs the state rows on
the flow's device whatever the batch showed; with no device up, they read `unverified`.

## What a flow leaves

Each flow row writes `qa/<NN>-<requirement>.flow/` in the run directory:

- `steps.json`, the driven steps file;
- `batch.json`, the batch's `--json` output as printed;
- `flow.json`, the flow record;
- `sim/`, the session, the step log and each step's PNG and tree, plus `sim verify`'s report;
- `lint.txt`, when the lint stopped the row.

The record is also 1 qa.flow event: `{plan, row, requirement, atBase, source, steps, video, sheet,
videoUnverified, sheetUnverified}`. `source` is `batch`, and each step that ran is
`{n, label, offsetMs, ok}`, with `n` in the flow file's numbering. `offsetMs` counts from the
video's first frame when `video` is present, else from the batch's start. The failing step is the last
one, with `ok` false. The last 4 keys appear only after a recording.

## The final pass

`qa run --final` records each flow, 1 at a time under the 1-slot `sim-record` lock:

1. It starts the app log stream and an `agent-device` trace.
2. It runs the batch with `record start` as its first step, so the video and the steps share the
   batch's clock. Each offset drops that step's time.
3. It runs `record stop` on every path, then `record contact-sheet`, leaving `video.mp4` and
   `sheet.png` in the flow's folder.
4. Under `qa/logs/<NN>-<requirement>/` it saves `app.log`, `network.json` (`network dump 25`),
   `trace.log`, `os.log` (`log show` for the subsystem named after the bundle id) and `container/`,
   the app's data container.

When `record start` refuses with `apple_simulator_recording_busy`, `qa run` retries every 15 s for up to 5
minutes. Past that, after any other refusal, or with the lock held 10 minutes, the flow runs
unrecorded. `videoUnverified` then names `recorderBusy`, `recordLockTimedOut` or `recordFailed`, and
a failed sheet names `sheetFailed`. Each missing video is a `qa.video-unverified` nit, and each
missing log a `qa.evidence-unsaved` nit. The row still passes or fails on its assertions.

An `--after` run records each flow the same way when the lock is free at once, saving no logs. A
busy lock or recorder runs the flow unrecorded at once, with no nit. The report shows each row's
newest passing run with its video, labelled with that run, when the row's newest run didn't pass.
