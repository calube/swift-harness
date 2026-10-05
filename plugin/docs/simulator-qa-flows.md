# Simulator QA flows

This page covers how `swiftgate qa run` checks a flow row, what the run leaves behind, and how the
final pass records video and logs. How T3 records a kept XCUITest flow is in
[`simulator-qa-kept-flows.md`](simulator-qa-kept-flows.md). Read this page when a flow row reads red or `unverified`, or when you need a flow's evidence.

The other rows and the layer order are in [`simulator-qa.md`](simulator-qa.md#qa-run), and the
`sim` commands in [`simulator-qa-sim.md`](simulator-qa-sim.md). To write a flow's steps, see
[`simulator-qa-flow-steps.md`](simulator-qa-flow-steps.md) for `wait` and `is`,
[`simulator-qa-flow-selectors.md`](simulator-qa-flow-selectors.md) for selectors, and
[`simulator-qa-flow-gestures.md`](simulator-qa-flow-gestures.md) for gestures a selector alone
doesn't drive, such as pull to refresh. Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## Running a flow row

A flow row's check is a steps file in the plan's state, such as `qa/<name>.flow.json`. `qa run`
takes these steps, in this order:

1. It lints the file with the `qa lint` rules. A red lint makes the row `red`, naming the rules,
   and no device starts. A lint that can't run, such as with no plugin root, leaves the row
   `unverified`.
2. It runs `sim up` in the tree the row runs in. It opens the app with the `launchArgs` of a
   leading `open` step. A failed `sim up` leaves the row `unverified`, naming its rule.
3. It runs 1 `agent-device batch --on-error stop` on the leased UDID and session. It adds a `sim/`
   step after each `wait` or `is` step: a `snapshot`, plus the video's frame from that moment as a
   PNG. A batch with no recording takes a `screenshot` and a second `snapshot` instead. An
   `is text` step's value becomes that `sim/` step's assert.
4. When the batch exits 0 and this is the requirement's last flow row, it runs the requirement's
   state rows while the device is up. They get `QA_SIM_UDID`, `QA_SIM_SESSION`,
   `QA_SIM_BUNDLE_ID` and `QA_SIM_DIR` beside the usual variables.
5. Once it has asked for `sim up`, it runs `sim down` on every path, so 1 `qa run` holds at most
   1 device.
6. It runs `sim verify` over the row's `sim/` folder. This runs after `sim down`, which copies the
   app's crash reports into `sim/crashes/`, so the report can name an app exit.

### Results

| Result | When |
|---|---|
| `pass` | the batch exits 0 and `sim verify` is GREEN |
| `red` | a step fails, named by its number in the flow file, with any `sim verify` RED findings; or `agent-device` refuses the steps file; or `sim verify` is RED |
| `unverified` | a driver or machine failure, a failed capture, or an unreadable video frame |

A state row behind a flow that isn't `pass` reads `unverified`, even when it ran on the device
first.

`--at-base` runs flow rows too, in the scratch tree. It runs the state rows on the flow's device
whatever the batch showed. With no device up, they read `unverified`.

## What a flow leaves

Each flow row writes `qa/<NN>-<requirement>.flow/` in the run directory:

| File | Holds |
|---|---|
| `steps.json` | the steps file as driven |
| `batch.json` | the batch's `--json` output as printed |
| `flow.json` | the flow record |
| `sim/` | the session, the step log, each step's PNG and tree, and `sim verify`'s report |
| `lint.txt` | the lint output, when the lint stopped the row |

The record is also 1 `qa.flow` event:

```text
{plan, row, requirement, atBase, source, steps, video, sheet, videoUnverified, sheetUnverified, launch}
```

- `source` is `batch`.
- Each step that ran is `{n, label, offsetMs, ok, captureMs}`, with `n` in the flow file's
  numbering.
- `offsetMs` counts from the video's first frame when `video` is present, else from the batch's
  start.
- `captureMs` is the time the steps `qa run` added after this step took (captures,
  `record start`). It delays every later step.
- `launch` is the leading `open`'s `{launchMs, settleMs}`, as `agent-device` reports them.
- The failing step comes last, with `ok` false. A red row's message ends with where the time
  before that step went.
- The 4 recording keys (`video`, `sheet`, `videoUnverified`, `sheetUnverified`) appear only after
  a recording.

## The final pass

`qa run --final` records each flow, 1 at a time, under the 1-slot `sim-record` lock:

1. It starts the app log stream and an `agent-device` trace.
2. It runs the batch with `record start` first, or after a leading `open` so the video opens on
   that launch. Each offset drops the time before the video.
3. It runs `record stop` on every path, then `record contact-sheet`. These leave `video.mp4` and
   `sheet.png` in the flow's folder.
4. It saves these under `qa/logs/<NN>-<requirement>/`:
   - `app.log`;
   - `network.json`, from `network dump 25`;
   - `trace.log`;
   - `os.log`, from `log show` for the subsystem named after the bundle id;
   - `container/`, the app's data container.

When `record start` refuses with `apple_simulator_recording_busy`, `qa run` retries every 15 s for
up to 5 minutes. Past that, after any other refusal, or when the lock stays held for 10 minutes,
the flow runs unrecorded:

- `videoUnverified` names `recorderBusy`, `recordLockTimedOut` or `recordFailed`.
- A failed contact sheet sets `sheetUnverified` to `sheetFailed`.
- Each missing video is a `qa.video-unverified` nit, and each missing log a `qa.evidence-unsaved`
  nit.
- The row still passes or fails on its assertions.

An `--after` run records each flow the same way when the lock is free at once, and saves no logs.
When the lock or the recorder is busy, it runs the flow unrecorded at once, with no nit, and the
row's message says `no video:` and why.

The report shows each row's newest passing run with its video, labelled with that run, when the
row's newest run didn't pass.

