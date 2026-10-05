# swift-harness: simulator QA

**Status: Built.** `swiftgate sim up|snap|verify|down`, the `agent-device` adapter and its `doctor` pin check, the
`sim.*` evidence rules, launch-argument dependency scenarios (`plugin/templates/Scenario.swift`), the `sim_qa`
preset key and `/swift-harness:qa` all ship. The [layered evidence amendment](2026-10-04-simulator-qa-layered-evidence-amendment.md)
later added `swiftgate qa` and planned validation rows. Notes in §4, §6 and §8.2 mark where the code differs.

**In brief.** Simulator QA lets an agent run the app it built on an iOS Simulator and tap through the changed
screens as a user would. `swiftgate sim up`, `snap`, `verify` and `down` lease a device, save a screenshot and an
accessibility tree for each checked step, and judge that evidence. The agent decides what to try, and `sim verify`
alone gives the verdict: it fails a run on missing evidence, absent text, a crash or an unlabelled control. A flow
worth keeping becomes an XCUITest that the T3 tier runs, so an agent's judgment never decides a merge. A pinned
`agent-device` drives the device. User guide: [`plugin/docs/simulator-qa.md`](../../plugin/docs/simulator-qa.md).

<!-- RESUME
Status: APPROVED 2026-09-28 by the user: the tool choice (§2), and every choice in §11, with kept flows as T3 UI
flows.
Why: the Foundation design's sub-project 3 row (`swiftgate sim`, launch-arg dependency scenarios, a QA skill driving
`agent-device`, screenshot and accessibility-tree evidence), and the build executor's `validate` stage (§8.6), which
calls sub-projects 3 and 4 once they exist.
Decision record: [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md), accepted.
Read first: this header, §2, then §4 and §11 (approved choices).
-->

## 1. Purpose

Let an agent run the app it built on a simulator, drive the changed flows the way a user would, and leave
evidence a reviewer can check: a screenshot and an accessibility tree for every step it asserts on. Flows worth
keeping become checked-in XCUITest, so the regression gate never depends on an agent's judgment.

Input: the QA and profiling tool survey (2026-09-26), sections 1, 2, 4, 5 and 6.

### Non-goals

- Profiling, leaks and timing. The [agentic profiling design](2026-09-28-agentic-profiling-design.md) owns them,
  even where `agent-device` offers `perf` commands. That design never shipped.
- Physical devices, Android and CI. The Foundation design locks iOS Simulator on 1 Mac with no CI.
- A second regression format. The repo holds no `.ad` scripts and no Maestro YAML (§2).
- Visual diffing. T2 snapshot tests already own pixels.

## 2. Decisions from the user (2026-09-28)

| Question (survey §6) | Answer |
|---|---|
| Driver | `agent-device`, at a pinned version, is the agent's hands and evidence collector. `swiftgate sim` shells out to its CLI; agents may use its MCP server or its CLI. |
| Regression format | A flow worth keeping becomes a T3 UI flow: XCUITest in the UI test target plus a `[[flows]]` entry, run by T3 on a cloned simulator. Not `.ad`, not Maestro YAML. |
| Maestro | Dropped. It needs Java 17, which isn't installed. |
| AutoMobile | May stay connected for ad-hoc exploration. It is never the gate's driver. |

Why `agent-device` (survey §2.4): 1 install behind a CLI, an MCP server and a Node API; a real accessibility tree with
stable refs and `--settle` diffs; typed `wait` failures in `--json`; sessions scoped per git worktree; MIT; no
usage telemetry.

## 3. Decision map

| Decision | Choice | Section |
|---|---|---|
| Command surface | `swiftgate sim up · snap · verify · down` | §4 |
| Evidence | `.harness/runs/<id>/sim/` with `session.json`, `steps.ndjson`, a PNG and a tree per step | §5 |
| Scenarios | 1 closed list, selected by the `-harness-scenario <name>` launch argument, applied with `prepareDependencies` | §6 |
| Devices | the harness creates, locks and deletes the device; `agent-device` only drives it | §7 |
| QA skill and callers | `/swift-harness:qa`; the `validate` stage and `/swift-validate` call it | §8 |
| Kept flows | T3 UI flows: an XCUITest in the UI test target plus a `[[flows]]` entry, written test-first | §8.3 |

## 4. `swiftgate sim`

`swiftgate sim` owns the device, the run directory and the verdict. The agent owns the taps.

| Command | Does | Exit |
|---|---|---|
| `sim up [--scenario <name>]` | Checks the pinned `agent-device` version, takes a simulator slot (§7), creates the device, builds and installs the app with the per-worktree DerivedData and `-skipMacroValidation`, launches it with the scenario argument, opens an `agent-device` session on that device, and prints `{runID, udid, session, scenario}` | 0, or 3 for `BLOCKED` |
| `sim snap <label> [--assert "<text>"]` | Calls `agent-device screenshot` and `snapshot --json` on the session's device, writes both under the run, and appends a step line | 0, or 1 when the device or session is gone |
| `sim verify [<runID>]` | Pure evidence rules over the run directory (§5.2); writes `report.json` and a history line like any check | 0 `GREEN`, 1 `RED`, 3 `BLOCKED` |
| `sim down` | Closes the session, deletes the device and releases the slot. Idempotent | 0 |

Verdicts follow the Foundation design §5.3. `--json` reports carry `schemaVersion`.

The pinned version lives in the plugin beside the `agent-device` fixtures, because the adapter parses its output.
`swiftgate doctor` reports a missing or different version as `BLOCKED` with the exact
`npm i -g agent-device@<pin>` line. The survey found 0.21.15; the worker who captures the fixtures sets the pin.

> Note: in the shipped CLI, `BLOCKED` exits 2, as in every other `swiftgate` command, not 3. The pin is 0.21.18.

Layering: an `AgentDevice` protocol in `SwiftGateAdapters` wraps the CLI through `ProcessRunner`. Parsing the tree,
the step log and the rules in §5.2 is pure `SwiftGateDomain` code. The CLI wires them.

## 5. Evidence

### 5.1 Layout

```
.harness/runs/<runID>/sim/
  session.json        schemaVersion, agentDeviceVersion, udid, deviceType, runtime, bundleID,
                      scenario, headCommit, startedAt
  steps.ndjson        1 line per step: n, label, assert, screenshot, tree, settled, elapsedMs
  steps/003.png       agent-device screenshot
  steps/003.tree.json agent-device `snapshot --json`, unmodified
  agent-device.log    the CLI's stderr for the run
  report.json         sim verify's verdict and findings
```

`sim snap` keeps the raw `agent-device` JSON unmodified, so a parser bug never destroys evidence. `swiftgate gc` prunes these
directories with the rest of `.harness/runs/`.

### 5.2 Rules `sim verify` applies

| Rule id | Finding | Verdict |
|---|---|---|
| `sim.no-steps` | the run has no step | `RED` |
| `sim.evidence-missing` | a step line names a screenshot or tree that isn't on disk, or doesn't parse | `RED` |
| `sim.assert-absent` | an `--assert` text isn't in that step's tree | `RED` |
| `sim.a11y-identifier` | an interactive element (button, switch, text field, cell) in a step's tree has no identifier | `RED` |
| `sim.a11y-label` | an interactive element has no readable label | `RED` |
| `sim.stale-head` | `headCommit` isn't the checkout's HEAD | `RED` |
| `sim.app-exited` | the app process ended during the run | `RED`, with the crash log path |

The 2 accessibility rules turn standards §7 (Accessibility), which says "review" today, into a mechanical check on the
real tree, not the source. Each rule ships with a fixture and a rule-index row in `plugin/docs/standards.md`.

## 6. Dependency scenarios

A scenario is a named set of dependency overrides, such as `empty`, `network-offline` or `signed-in-with-3-items`.

- **Declared once.** The app target has 1 `enum Scenario: String, CaseIterable`, compiled only in `DEBUG`, and each
  case has an `apply(to: inout DependencyValues)`. `.swiftgate.toml` lists the same names in
  `[[scenarios]]` with a `reason`. A new `arch` rule, `sim.scenario-drift`, is `RED` when the 2 lists differ.
- **Selected by launch argument.** The app entry point reads `-harness-scenario <name>` and calls
  `prepareDependencies { Scenario(rawValue: name)?.apply(to: &$0) }` before the app creates its first store. An unknown
  name calls `reportIssue` and launches with live dependencies, so a typo is visible.
- **One mechanism for agents and tests.** `sim up --scenario` passes the argument through `simctl launch`. A kept
  XCUITest sets `app.launchArguments` to the same argument. The Foundation design's T3 "launch-arg scenario
  injection" is this.
- `sim up` refuses a name missing from `[[scenarios]]` with `sim.scenario-unknown` before it builds anything.
- The bootstrap template stamps the enum with 1 case, `live`, and its config entry.

Whether `agent-device open` forwards launch arguments is unverified. If it does, `sim up` uses it. If not, `sim up`
launches with `simctl launch` and then opens the session on the running app.

> Note: it does. The shipped `sim up` launches through `agent-device open <bundle> --launch-args`.

## 7. Devices, claims and the simulator lock

The harness already runs simulators for T2 and T3 (Foundation design §4.4). It clones or creates a device per run
and holds 1 slot of the machine-wide `sim` counting lock (default 2) for the device's life. It sweeps devices whose
owner process died.

`sim` reuses that machinery rather than let `agent-device` pick devices.

1. `sim up` takes a slot of the **same** `sim` lock, so QA, T2 and T3 share 1 cap and queue together.
2. The lock must outlive the `sim up` call, because the agent works between commands. `sim up` starts a detached
   holder process, `swiftgate sim hold`, which holds the slot; `sim up` records it as the device's owner. The holder exits
   on `sim down`, when the session that started it is gone, or after `[qa] session_timeout_minutes` (default 30).
   The existing orphan sweep then deletes the device, because its owner PID is dead.
3. `sim up` passes the device's UDID to every `agent-device` call. `agent-device`'s own worktree-scoped claim then
   covers that UDID alone, and the 2 claim systems never compete for a device.
4. `sim down` and the sweep also run `agent-device device release --stale`, so its claims don't outlive the device.
5. A lease covers 1 worktree and 1 device. `sim snap`, `verify` and `down` refuse a caller from another worktree
   with `sim.not-owner`, and a test covers that cross case.

## 8. The QA skill and its callers

### 8.1 `/swift-harness:qa`

1. Pick the flows: screens in feature modules the diff changed, plus any flow the spec page or plan task names.
2. For each flow: `sim up --scenario <s>`, then an inspect, act, verify loop through `agent-device` (MCP or CLI),
   with `sim snap` at every point where it checks what the user would see.
3. `sim verify`, then `sim down`. On `RED`, it reports findings like any gate and hands off to
   `/swift-harness:tdd`. On `BLOCKED`, it runs `doctor`.
4. It proposes which flows to keep (§8.3). It never keeps a flow without asking.

The skill decides what to try. The verdict comes only from `sim verify`.

### 8.2 Callers

| Caller | When |
|---|---|
| The build executor's `validate` stage (its §8.6) | after the `ready` tier, on merged `main`, when the preset's `sim_qa = "changed"` |
| Sprint and design-free ship (fast modes design §4, §5) | after `sprint finish` or the final `ready` gate, under the same preset key |
| `/swift-validate` | adds a "Simulator QA" row with the verify run's id, verdict and step count; a skipped QA goes under "Not run" |

`sim_qa` is a closed enum, `changed` or `off`. The template stamps `changed` in every preset.

> Note: the shipped validate skill is `/swift-harness:validate`, and it adds 1 row per validation row that
> `swiftgate qa run` checked, as the amendment describes.

### 8.3 Keeping a flow

A kept flow becomes a T3 UI flow: an XCUITest in the app's UI test target, built on the same identifiers and
scenario, plus a `[[flows]]` entry, because the Foundation design §7.3 requires every XCUITest to map to 1. T3 runs it. It follows the quality floor: it must fail on an
assertion with the feature reverted, so `prove` covers it. At `max_flows` the skill asks the user which flow to drop,
or not to keep this flow.

## 9. Failure modes

| Failure | Verdict | Remedy named in the output |
|---|---|---|
| `agent-device` missing or not the pinned version | `BLOCKED` | the install line |
| The Accessibility or Screen Recording permission is missing for the AX bridge (unverified, survey §4) | `BLOCKED` | the System Settings pane |
| The `agent-device` XCTest runner fails to build | `BLOCKED` | `agent-device.log` path |
| No simulator slot within the lock timeout | `BLOCKED` | the holders' PIDs |
| The app build fails | `RED` | the build log |
| The app crashes or a `wait` fails with a typed reason | `RED` | crash log, the step, the reason |
| An evidence or accessibility rule fails (§5.2) | `RED` | the step, the element |

## 10. Testing the harness

- **Fixtures from real runs only.** Capture `agent-device --version`, `snapshot --json`, `screenshot`, a typed `wait`
  failure and a crash against `examples/SampleApp` on a cloned simulator, and record each capture command in
  `plugin/gate/Tests/Fixtures/README.md`. The survey's §5 trial plan (part A) is the capture session.
- **Seeded violations.** A SampleApp branch with an unlabeled button and a missing identifier must fail
  `sim.a11y-label` and `sim.a11y-identifier` in `self-test`.
- **Isolation.** 2 worktrees run `sim up` at once with a cap of 2, then a third queues. `sim` refuses a lease holder in 1
  worktree that acts on the other's device.
- **Kill test.** Killing the holder mid-run leaves no device and no `agent-device` claim after the next sweep.

## 11. Approved choices

The user approved each item on 2026-09-28.

1. Command surface `sim up · snap · verify · down`, with a detached holder process keeping the lock (§4, §7).
2. The `agent-device` pin lives in the plugin beside its fixtures, and `doctor` checks it (§4).
3. The evidence layout under `.harness/runs/<id>/sim/`, keeping `agent-device`'s raw JSON (§5.1).
4. The 7 `sim verify` rules, including 2 accessibility rules that are `RED`, not advisory (§5.2).
5. Scenarios: a `DEBUG`-only `Scenario` enum mirrored in `[[scenarios]]`, the `-harness-scenario` argument, and the
   `sim.scenario-drift` check (§6).
6. QA shares the T2/T3 `sim` lock and cap, and the harness, not `agent-device`, creates and deletes devices (§7).
7. The QA skill name `/swift-harness:qa`, and a `sim_qa` preset key defaulting to `changed` (§8).
8. Kept flows are T3 UI flows: an XCUITest in the UI test target plus a `[[flows]]` entry under `max_flows`, run by T3
   (§8.3).
