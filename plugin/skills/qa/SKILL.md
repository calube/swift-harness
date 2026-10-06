---
name: qa
description: This skill should be used to check a swift-harness iOS change in a running simulator and report the verdict swiftgate prints — run the plan's prepared validation rows with swiftgate qa run, pick the screens the change touched, drive each flow with agent-device on a device swiftgate sim up leases, record each checked point with sim snap, release the device with sim down, judge with sim verify, hand RED to tdd and BLOCKED to doctor, and offer to keep a flow as an XCUITest. It also holds the brief for a plan's validation task. Use when the user says "QA this", "drive the app", "check it in the simulator", "does the screen work", "/swift-harness:qa", or a build, sprint or ship validate stage asks for simulator QA. Not for writing a test (use tdd), judging tests (use test-gate) or PR evidence (use validate).
---

# QA

This skill decides what to try in the app. `swiftgate` decides whether it worked: a flow's verdict
comes from `sim verify`, and a prepared row's result from `qa run`. The skill never re-checks a
screen another way.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the repository toplevel. Read
only `verdict`, `findings[]` and the fields named below from `--json` output; the evidence stays
under `.harness/runs/<runID>/`, so open it only to explain a finding.

## Foreground work

A headless session ends when a turn ends with only background Bash work left, and that work dies
with it: a `qa run` cut short leaves no report and no verdict. On a cold cache, the first
`swiftgate` call also builds the binary, which can take minutes. So, before step 1, warm it:

```bash
"$SG" --version
```

Give that call, and every `qa run` and `sim up`, `sim snap`, `sim down` and `sim verify` after it,
the Bash tool's `timeout` at 600000, its longest. Never pass `run_in_background` to one and never
end one with a shell `&`.

## 1. Run the prepared rows

A plan built from a design or a brownfield `PLAN.md` may carry a validation table, stored as
`validation.json` beside its ledger. Run its rows before any device of your own:

```bash
"$SG" qa run --json
```

- `GREEN` with the note that no plan holds a validation table: there are no prepared rows. Go to
  step 2.
- Exit 2 naming several plans: run it again with `"$SG" qa run --plan <slug> --json` for the plan
  this change belongs to.
- Otherwise list each row's `requirement`, `layer` and `result` (`pass`, `red`, `unverified`,
  `waiting` or `abandoned`) from `rows[]`. The run already drove its flow rows on its own leased devices and wrote
  `.harness/runs/<runID>/qa/report.json`.

A `red` row is a finding like any other: it goes to step 4 with the run's verdict. Then explore
beyond the rows in steps 2 and 3, since a table covers only what the plan foresaw.

A build's `validate` stage runs the final pass itself before it calls this skill:

```bash
"$SG" qa run --plan <slug> --final --json
```

It also records each flow with a video and a contact sheet, and saves its logs under
`.harness/runs/<runID>/qa/logs/`. Called from a validate stage, take that run's `runID` and rows
and run no `qa run` of your own. Run `--final` yourself only when the user wants that recorded
evidence.

## 2. Pick the flows

1. The screens the change touched: `git diff --name-only <base>...HEAD` plus uncommitted changes,
   kept to SwiftUI views in `feature` and `render` modules and the app target. `.swiftgate.toml`
   `[[modules]]` gives each module's kind; a module with no entry is a `feature`.
2. Any flow the spec page or the plan task names, such as "add an item, then see it in the list".
3. For each flow, a scenario: a `[[scenarios]]` name in `.swiftgate.toml` whose dependencies make
   the screen's data fixed. With none that fits, the flow runs on live dependencies.

No touched screen and no named flow: report `qa: no flow to drive` and stop. Don't drive screens
the change didn't touch.

## 3. Drive each flow

One flow at a time, so this session holds at most 1 device:

1. Start the run:

   ```bash
   "$SG" sim up --scenario <scenario> --json
   ```

   Leave out `--scenario` for live dependencies. Keep `runID`, `udid` and `session` from the
   JSON. A non-zero exit means no device is yours: record its verdict and rule for this flow, skip
   to item 5, and go on to the next flow.
2. Inspect, act and verify through `agent-device`, with the MCP tools or the CLI. Every call
   carries the run's device and session: on the CLI `--udid <udid> --session <session>`, as in
   `agent-device snapshot -i --udid <udid> --session <session>`, and as the `udid` and `session`
   inputs on an MCP tool. `sim up` already opened the app and `sim down` closes it, so never call
   `open`, `close`, `boot`, `install` or `reinstall`, and never touch a device `sim up` didn't
   give you. Target elements by `id="…"` selectors from the app's `AccessibilityID` raw values when
   the screen has them. Check what a user would see with `wait` or `is`; a `get`, a diff or a
   screenshot alone checks nothing.
3. At every point where you check what the user sees, record a step:

   ```bash
   "$SG" sim snap "<what the step shows>" --assert "<text the screen must hold>" <runID> --json
   ```

   Leave out `--assert` only for a step that shows a screen without checking text. When a `wait`
   or `is` fails, snap that step anyway with `--assert` set to the text you expected, so the
   verdict names it, and note the typed reason `agent-device` printed. A `sim snap` exit 1
   (`sim.app-exited`, `sim.session-gone`) ends the flow: go to item 4.
4. Release the device:

   ```bash
   "$SG" sim down <runID> --json
   ```

   Run `sim down` on every path once `sim up` was asked, after a failure as much as after a
   pass. It copies the run's crash reports, which `sim verify` then names.
5. Judge the run:

   ```bash
   "$SG" sim verify <runID> --json
   ```

   Keep `verdict`, `stepCount` and `findings[]` (`rule`, `step`, `path`, `message`). The run's
   `sim/report.json` holds the same.

## 4. Report the verdict

Each flow's verdict is the one `sim verify` printed, or, when no run started, the one `sim up`
printed. The skill never states a verdict `sim verify` didn't print, and never turns a RED or
BLOCKED into a pass because the screen looked right.

- `GREEN` for every flow and every row `pass` or `waiting`: QA passed. An `abandoned` row, which
  only a run after the build ended reads, never passes: its task was abandoned before it merged,
  so the row never ran, and its `qa.check-unverified` finding gates. Report it with the task the
  message names.
- Any `RED`, or a `red` row: list each finding as `rule step path — message`, plus the typed reason
  of any failed `wait`, and hand off to `/swift-harness:tdd` to name the regression in a failing
  test and fix it. Called from a validate stage, list them and hand off nothing: the caller decides.
- Any `BLOCKED`: run `"$SG" doctor` and report what the machine needs, such as the
  `agent-device` install line or the PIDs holding the simulator slots.

## 5. Offer to keep a flow

A flow worth keeping guards a journey that crosses features or that broke before. Propose those
flows, then ask with `AskUserQuestion`, 1 question per flow: keep it as a T3 UI flow, or not. The
skill never keeps a flow without asking, and offers none when nothing passed.

For each flow the user keeps:

1. Count the `[[flows]]` entries in `.swiftgate.toml` against `[pyramid] max_flows` (10 when unset).
   At `max_flows`, ask with `AskUserQuestion` which flow to drop, or not to keep this one.
2. Write the kept flow test-first with `/swift-harness:tdd`: an XCUITest in the app's UI test
   target that launches the app with the flow's scenario (`-harness-scenario <scenario>` in its
   launch arguments) and reads every identifier from the app's `AccessibilityID` module, the file
   `[qa] accessibility_ids` names. It must fail on an assertion with the feature reverted, so
   `prove` covers it.
3. Add its `[[flows]]` entry with `name` and a 1-line `reason`, and remove the entry and the test of
   a flow the user chose to drop.

## A plan's validation task

A design plan's validation task, and a brownfield run's, writes each `flow` and `state` check
before the code exists. Its worker follows
[`references/validation-worker.md`](references/validation-worker.md).

## Report

| Flow | Scenario | Run id | Verdict | Steps | Findings |
|---|---|---|---|---|---|

Then the prepared rows by result with the `qa run` run id, the flows proposed and the user's answer
for each, and the flows kept or dropped.

## Rules

- `swiftgate` is the judge. When a command and your reading of the screen disagree, the command
  wins.
- Every `agent-device` call names the run's `udid` and `session`.
- 1 device at a time, released with `sim down` before the next flow and before any report.
- No flow is kept unasked, and none past `max_flows` without the user choosing what to drop.
- Name no app, screen or scenario of your own in a kept test: take them from the repository.
