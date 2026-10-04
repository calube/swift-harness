# swift-harness: simulator QA amendment, layered validation and evidence

<!-- RESUME
Status: PROPOSED 2026-10-04. Nothing here is approved. Each choice waits on the user's decisions in §12.
Amends: the approved simulator QA design (docs/designs/2026-09-28-simulator-qa-design.md), its decision record
[ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md), and its plan (docs/plans/2026-09-28-simulator-qa-plan.md), which has not started.
Why: the user asked for layered validation planning and richer QA evidence, fitted to this harness's QA setup and
report format.
Read first: this header, §2, §4, §10 (conflicts) and §12 (decisions).
-->

## 1. Purpose

Plan every acceptance criterion against 4 validation layers before the code exists, and prepare the checks while the
build runs. Run them cheapest first after each merge. Finish with a report in which only an assertion or a state
check's exit status passes a row. Video, logs and stored data become evidence beside the pass, never the pass.

### Non-goals

- Android, physical devices and CI. The approved design (§1) keeps them out, and this amendment keeps them out.
- Web and other non-iOS UI. This amendment covers iOS only.
- A new regression gate. Kept flows stay T3 XCUITest ([ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md)); prepared flows serve 1 run.
- Visual diffing of video frames. T2 snapshot tests own pixels.

## 2. What exists today

| Piece | State on `main` at 7305f994 |
|---|---|
| Simulator QA design and [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md) | merged 2026-09-28 (`41620782`) |
| Simulator QA plan | merged (`8b01ab70`); its RESUME header says `Status: NOT STARTED` |
| `swiftgate sim`, the `AgentDevice` adapter, `sim verify` rules, `/swift-harness:qa` | none: no source under `plugin/gate/Sources` names `agent-device`, and `plugin/skills/` has no `qa` skill |
| The build executor's `validate` stage | prints `validate: not configured` and passes (`plugin/skills/build/SKILL.md`) |
| Requirement ids | `req-<name>` in design docs, in a brownfield `PLAN.md`'s `## Requirements`, in ledger `covers`, and in the run viewer's spec region |
| Brownfield `final` tier | runs `merge` for every area plus the UI and end-to-end commands discovery found |
| Run viewer failure context | a red gate span and a blocked task show the gating findings and failing tests (`plugin/docs/run-viewer-failures.md`) |
| Simulator QA in brownfield | a non-goal for areas that aren't iOS (brownfield design §1) |

Since no simulator QA task has started, this amendment can change the plan before its first wave without a replan.

## 3. The 4 layers

| Layer | Proves | Check | Cost | Runs |
|---|---|---|---|---|
| unit | each task's own behaviour | the task's tests, test-first, proven by `prove` | seconds | the task's gate; not listed in the validation table |
| acceptance | behaviour at a boundary: an API, a CLI, the module that joins 2 tasks | a test in the repository's framework, or a `curl -fsS … \| jq -e '<condition>'` command | seconds | after the tasks it names merge |
| flow | a user journey in the running app | an `agent-device batch` steps file | about a minute | once the UI it drives merges |
| state | the result persisted or left the app | a script that exits non-zero when the stored or sent result is wrong | seconds | straight after its flow |

A state check reads 1 of: a database query, a read after the write, the app's stored data, or a log line.

## 4. The validation table

### 4.1 Shape

Each plan carries 1 table. A row maps 1 acceptance criterion to 1 check.

| Done when | Layer | Check (command or file) | Runs after | Writer |
|---|---|---|---|---|
| `req-save-draft` | acceptance | `DraftClientTests/saveDraftPersists` | `draft-client` | `validation` |
| `req-save-draft` | flow | `qa/save-draft.flow.json` | `draft-ui` | `validation` |
| `req-save-draft` | state | `qa/save-draft.state.sh`: reads the stored draft file | `draft-ui` | `validation` |

- **Done when** names a requirement id. The table uses the existing `req-<name>` ids that the ledger's `covers`
  and the run viewer's spec rows join on (decision 1).
- **Layer** is a closed enum: `acceptance`, `flow` or `state`.
- **Runs after** lists ledger task ids. The row runs once every named task has merged.
- **Writer** is the validation task's id, or the owning task for a 1-task plan.

### 4.2 The contract names the targets

The contract commit (brownfield design §11.3) and a design's surface commit already fix types and signatures. This
amendment adds the names a check targets, so a check can exist before the code: element identifiers and labels,
routes with their request and response shapes, storage keys and tables, and log lines with their subsystem. An
identifier the contract names is also what the `sim.a11y-identifier` rule (approved design §5.2) expects to find.

### 4.3 Where the table comes from

| Path | Who writes the table | Where it lives |
|---|---|---|
| Design, then `/swift-harness:plan` | the decomposer adds rows beside its tasks, and `plan-lint` checks them | plan state, beside `ledger.json`, as `validation.json` |
| Brownfield `swiftgate run` | Opus writes a `## Validation` section in `PLAN.md` | `plan import` reads it into the same `validation.json` |
| Sprint and design-free ship | none in the first cut: each slice keeps its 1 acceptance test | (decision 9) |

New `plan-lint` rules, each with a fixture and a rule-index row, flag:

- a requirement with no row outside `unit` and no stated reason;
- a `Runs after` naming no ledger task;
- a `state` row with no `flow` row for the same requirement and task;
- a `flow` row in a repository with no iOS area.

## 5. Preparing checks during the build

A validation task runs beside the first wave, with no deps on the build tasks, and finishes before them.

1. It writes each row's check against the contract's names only.
2. It runs each check now and records why it fails: a stub, a 404, a missing element. A check that fails on an
   import error, a typo or a missing file isn't ready; the task fixes it before it reports.
3. It may build and install the base app, through `swiftgate sim up` (approved design §7), never on a device it
   picks itself.
4. Its return lists each check with its path and its recorded failure reason.

### 5.1 Write set

| Files | Where | Merged |
|---|---|---|
| acceptance tests | in the repository, on the validation task's branch | after every task its tests need, as a ledger dep |
| flow steps files and state scripts | a `qa/` folder outside the tracked tree (decision 5) | never |

The edit guard denies a subagent's write outside the repository's checkouts (`guard.subagent-outside-checkouts`)
and any write into `.git` (`guard.subagent-protected-path`). Because of the edit guard, `qa/` can't sit in a work
directory outside the repository. The recommended option writes `qa/` under the validation worktree's own
`.harness/qa/<plan>/`, which no commit carries. The orchestrator then copies it into plan state.

### 5.2 Proof that a check fails first

| Layer | How the harness confirms the red run |
|---|---|
| acceptance | `prove` with `--proof-base` set to `main` before the row's `Runs after` tasks merged: the test must fail there on an assertion. Host tests only; the testing playbook says simulator tests aren't proven yet |
| flow, state | `swiftgate qa run --at-base` runs the check on the base app and stores the failing step or exit status in the evidence folder |

Recommended: the gate confirms the red run, not the worker's own note (decision 7).

## 6. Running checks after each merge

After each merge, the build runs only the rows whose `Runs after` tasks have now all merged, in layer order:
acceptance, then flow, then state. It stops at the first failing layer, since a slower layer can't pass over a
broken boundary. A red row stops the next merge, as a red `main` does today (build executor design §8.3).

Every row runs through `swiftgate`, because the harness never re-implements a check outside it:

```bash
swiftgate qa run --after <task id>        # rows this merge unblocks
swiftgate qa run --final                   # every row, recording flows (§7)
swiftgate qa run --at-base                 # the validation task's red runs (§5.2)
```

A flow row runs as 1 call on the device `sim up` leased:

```bash
agent-device batch --steps-file <qa>/<name>.flow.json --session <session> --udid <udid> --on-error stop --json
<qa>/<name>.state.sh
```

### 6.1 Flow file rules

| Rule id (proposed) | Finding | Verdict |
|---|---|---|
| `qa.flow-unparsed` | the steps file isn't a JSON array of `{"command","input"}` steps | `RED` |
| `qa.flow-ref-target` | a step targets an `@e` ref or a coordinate, not a selector | `RED` |
| `qa.flow-no-assert` | a flow has no `wait` or `is` step | `RED` |

`get` reads a value and takes no predicate, so it never counts as the assertion. The installed guide says
"get text alone ... is not enough" (decision 4). Each rule ships with a captured fixture and a rule-index
row in `plugin/docs/standards.md`.

### 6.2 What passes a row

| Layer | Passes when |
|---|---|
| acceptance | the test passes in the gate, or the command exits 0 |
| flow | the batch exits 0, and `sim verify` is `GREEN` over the run's steps |
| state | the script exits 0 |

A screenshot, tree, video or log alone never passes a row. A row whose check didn't run reads `unverified`.

## 7. Video on the final pass

`swiftgate qa run --final` wraps each flow in a recording, 1 flow at a time:

```bash
agent-device record start <ev>/<name>.mp4 --session <session>
agent-device batch --steps-file <qa>/<name>.flow.json --session <session> --udid <udid> --on-error stop --json
agent-device record stop --session <session>
agent-device record contact-sheet <ev>/<name>.mp4 --out <ev>/<name>-sheet.png
```

Claude reads the contact sheet PNG to confirm the journey reached its end state. The MP4 is for people. Neither passes
a row (§6.2).

Limits the installed help states:

- **Host-wide lock.** An iOS simulator host holds 1 recording at a time, and a second `record start` returns
  `DEVICE_IN_USE` with reason `apple_simulator_recording_busy`. The `sim` lock lets 2 QA runs share the Mac (approved
  design §7), so recording needs its own 1-slot lock (decision 6).
- **Mac only.** `record contact-sheet` decodes with AVFoundation and refuses other hosts.
- **Coverage, not review.** The sheet samples a bounded grid, so a brief flash between samples doesn't show.
- **Android** splits recordings over 180 s, but Android stays a non-goal here.

## 8. Logs and other evidence

### 8.1 Evidence kinds

| Kind | Source | When |
|---|---|---|
| test output with counts | the gate's `report.json` | every acceptance row |
| raw responses | the `curl` body each acceptance command saves | every API row |
| backend stdout and stderr | the service the row started | every API row |
| app logs | `agent-device logs`, and `xcrun simctl spawn <udid> log show --predicate 'subsystem == "<subsystem>"'` | final pass |
| network | `agent-device network dump <limit> --include headers` | final pass |
| trace | `agent-device trace start <path>` and `trace stop <path>` | final pass |
| stored app data | `xcrun simctl get_app_container <udid> <bundle id> data` | each state row |

Android's `logcat -d` and `run-as … cat` from the request stay out with Android (§1).

### 8.2 Layout

The evidence extends approved design §5.1 with a sibling folder:

```
.harness/runs/<runID>/
  sim/                    unchanged: session.json, steps.ndjson, a PNG and a tree per step
  qa/
    report.json           1 entry per row: requirement, layer, check, result, evidence paths
    <name>.batch.json     agent-device batch --json output
    <name>.state.txt      the state script's stdout, stderr and exit status
    <name>.mp4            final pass only
    <name>-sheet.png      final pass only
    logs/                 app log, network dump, trace, backend output
```

Each flow's batch adds `snapshot` and `screenshot` steps at every assertion, so `sim/` keeps a tree and a PNG per
asserted step, and the 7 `sim verify` rules keep their input. Whether `batch --json` returns each step's snapshot
in a form `sim snap` can store is unverified, and the fixture capture task settles it (§11).

### 8.3 Running beside another session

Another session on the same Mac may drive its own simulator, record its own screen or run its own server. The gate
already isolates its devices; this section states what the other session must leave alone, and what QA adds.

- **Simulators.** Each simulator-tier run finds the base device by the `[simulator]` `device` name and `os`
  version in `.swiftgate.toml`, uses a copy of it, and deletes the copy at the end:
  - It clones the base when the base is shut down. When the base is running, it creates a fresh device of the same
    type and runtime instead, and never clones a booted device.
  - Every copy carries a `swift-harness-<pid>-` name. The sweep deletes only devices with that name whose owner
    process has died, so it never touches a device another session named.
  - A machine-wide `sim` counting lock caps how many copies exist at once (`[simulator] max_concurrent`). It counts
    harness copies only; another session's own simulators don't take a slot.
  - The base lookup takes the lowest UDID among devices that share the base's name and `os`. Another session must
    therefore use its own simulator under a different name, and never boot or change the base device: each clone
    copies the base's installed apps and settings.
- **Checkouts.** Each session works in its own clone or worktree of the app, never 1 shared checkout. The simulator
  tiers already build into DerivedData per worktree, so 2 sessions never share build products.
- **Screen recording.** The Mac allows 1 simulator recording at a time, whoever started it. The recording lock
  (decision 6) orders the harness's own final passes. A recording that another session holds still returns
  `apple_simulator_recording_busy`. On that reason, `qa run --final` waits and retries within a bounded time
  (decision 14). Past the bound, it runs the flow without video and marks that flow's video `unverified`. The row
  still passes or fails on its assertions and state check alone (§6.2).
- **Backend ports.** An acceptance row that starts a server picks a free port for that run and passes it to every
  check in the row (decision 15). A fixed port could collide with another session's server, and the row would then
  test the wrong process.

## 9. How this fits the rest of the harness

| Part | Change |
|---|---|
| `/swift-harness:design` | none to the template: `## Requirements` already gives the ids. The design's surface section names the check targets (§4.2) |
| `/swift-harness:plan` | the decomposer adds the validation task and the table; `plan-lint` gains the §4.3 rules |
| Build executor | after each merge, `swiftgate qa run --after <task>`; the `validate` stage runs `swiftgate qa run --final` on merged `main` instead of printing `validate: not configured` |
| Brownfield | `PLAN.md` gains `## Validation`. Acceptance and state rows apply in any language with no simulator, and run at `merge`. Flow rows run at `final`, for iOS areas only |
| `/swift-validate` | its block gains 1 row per validation row, with result and evidence, under "Simulator QA" (approved design §8.2) |
| Run viewer | the report becomes tabbed, with a Validation tab (§9.2); a `qa.check` event per row feeds it. A red row reuses the "Why it failed" popover with layer, check, failing step or exit status, and evidence paths relative to the run |

The run viewer change adds a field to the closed `RunView` contract and a new `HarnessEvent` kind. Each evidence path
passes the payload guard; a path the guard rejects becomes a `damage` row, as today. The page links the MP4 and the
contact sheet by run-relative path and embeds neither (decision 10).

### 9.1 The report

The final report has 1 row per check:

| Done when | Layer | Check | Result | Evidence |
|---|---|---|---|---|
| `req-save-draft` | acceptance | `DraftClientTests/saveDraftPersists` | pass | 1 test, 0 failures, run `<runID>` |
| `req-save-draft` | flow | `save-draft.flow.json` | pass | batch exit 0; `sim verify` GREEN; MP4 and contact sheet |
| `req-save-draft` | state | `save-draft.state.sh` | unverified | not run: flow failed |

Below the table, the report lists what only a person can verify: gestures the tool can't perform, visual polish,
and any row that reads `unverified`.

A row's result is `pass`, `red`, `unverified` or `waiting`. A row reads `waiting` while a task it runs after hasn't
merged yet.

### 9.2 The run viewer's tabs

The user chose the tabbed layout on 2026-10-04: the validation layout mockups, variant B (decision 10).

- **Tabs.** The report and the live page show 8 tabs: Overview, Timeline, Board, Graph, Spec, Gates, Tokens and
  Validation. The regions the run viewer design §7 lays out on 1 page move into these tabs.
- **Badges.** Every tab label carries live counts. Validation shows its red, unverified and waiting counts, and Gates
  shows its retries, so a red check shows from any tab.
- **Validation tab.** A summary strip counts pass, red, unverified and waiting rows. Below it, the tab groups rows
  by task.
- **Shared checks.** A row that runs after several tasks shows under each of them as "waiting on <task>" until the
  last of them merges.
- **Why buttons.** A red row opens the existing "Why it failed" popover. An `unverified` row opens a "Why
  unverified" popover naming what didn't run and why, such as a failed flow before its state check, or a recording
  past the decision 14 bound.
- **Task details.** A click on a board card or a graph node opens a task details popover: status, board column,
  deps, gate, commits, covered requirements, and the task's validation rows with their Why buttons. Its "Open task"
  action opens the task drawer.

## 10. Against the approved choices

| # | Item | Approved choice | Relationship | Why |
|---|---|---|---|---|
| 1 | Validation table and layers | §8.1 picks flows from the diff and the spec | extends | the table names the flows ahead of time; the diff-based pick stays for a plan with no table |
| 2 | Contract names targets | §5.2 accessibility rules, §6 scenarios | extends | the identifiers the rules demand become plan inputs |
| 3 | Validation worker and prepared checks | §8.1: the QA skill decides what to try at the end | extends | checks exist before the code; the skill still explores beyond them |
| 4 | Batch flows from steps files | [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md) and §1: "no `.ad` scripts", kept flows are XCUITest | conflicts in part | a steps file is a second scripted format for `agent-device`; it stays outside the tracked tree, serves 1 run, and no gate replays it across runs. Kept flows stay XCUITest |
| 5 | Batch replaces per-step `sim snap` | §4 `sim snap` per asserted step, §8.1 inspect, act, verify loop | replaces the loop for prepared flows | the batch carries snapshot and screenshot steps instead; the hand loop stays for exploration |
| 6 | What passes a flow | §8.1 "the verdict comes only from `sim verify`" | extends | a flow passes on batch exit 0 and `sim verify` GREEN |
| 7 | State scripts | none | extends | a new layer; no approved choice covers stored data |
| 8 | Video and contact sheet | §5.1 screenshot and tree per step | extends | video is extra evidence on the final pass; the PNG and tree stay |
| 9 | Recording lock | §7 a `sim` lock with 2 slots | conflicts | the host-wide recording lock means 2 QA runs can't record at once; a 1-slot recording lock or serial final passes fixes it |
| 10 | Logs, network, trace, app data | §1 non-goal: profiling | extends | evidence, not timing; sub-project 4 keeps `perf` |
| 11 | Android evidence | §1 non-goal: Android | conflicts | out of scope; this amendment drops it |
| 12 | Report with requirement rows | §8.2 a "Simulator QA" row in `/swift-validate` | extends | 1 row per check instead of 1 per verify run |
| 13 | The pin | plan: 0.21.16 | changes | this Mac runs 0.21.18, and every help text this amendment cites comes from 0.21.18 |
| 14 | Tabbed report | run viewer design §7: 1 page of regions | replaces | the user chose tabs on 2026-10-04 (§9.2); every region keeps its content inside a tab |

## 11. Verified against the installed tool

Captured on 2026-10-04 on this Mac. Nothing here comes from memory.

| Command | Result |
|---|---|
| `agent-device --version` | `0.21.18` |
| `agent-device help batch` | `--steps <json>`, `--steps-file <path>`, `--on-error stop`, `--max-steps <n>`, `--out <path>`; each step is `{"command":"<name>","input":{...}}` with camelCase inputs; `wait`, `is`, `get`, `screenshot`, `snapshot`, `record`, `trace`, `logs` and `network` may run inside a batch |
| `agent-device help record` | `record start [path] [--scope <app\|device\|system>] [--fps <n>] [--quality <medium\|high>] [--hide-touches]`, `record stop`, `record contact-sheet <video.mp4> [--out <sheet.png>]`; the limits in §7 |
| `agent-device help trace` | `trace start <path>`, `trace stop <path>` |
| `agent-device help logs`, `help network` | `logs path\|start\|stop\|clear [--restart]\|doctor\|mark`; `network dump [limit] [summary\|headers\|body\|all]` |
| `agent-device help wait`, `help is`, `help get` | `wait text <text> [timeoutMs]`, `wait absent <selector>`; `is <predicate> <selector> [value]`; `get text\|attrs <@ref\|selector>` reads without a predicate |
| `agent-device help workflow` | selectors take the form `id="…"` and `label="…"`; "get text alone ... is not enough" |
| A batch whose `wait` fails, with and without `--json` | exit 1; the message names the failing step's index and command |
| A batch with no `--udid` on this Mac | `AMBIGUOUS_MATCH` across 11 devices, so every call passes the leased UDID |

Unverified, for the fixture capture task: the shape of `batch --json` per-step output on success; whether
`record start` in a batch works while the batch also drives the app; and the `--session` binding when `open` ran
with `--udid`.

## 12. Decisions for the user

| # | Question | Options | Recommendation | Needs |
|---|---|---|---|---|
| 1 | How does a row name its acceptance criterion? | (a) existing `req-<name>` ids; (b) a separate per-plan numbering, `D1`, `D2` | (a): the ledger and the run viewer already join on them | user |
| 2 | Which tools run the checks? | (a) `agent-device` batch for flows, the repo's test runner or `curl` with `jq -e` for acceptance, shell for state, all behind `swiftgate qa run`; (b) the same tools called directly, with no `swiftgate` wrapper | (a): every enforcement point calls `swiftgate` | user |
| 3 | Which evidence kinds? | (a) the approved PNG and tree per step, plus final-pass MP4 and contact sheet, logs, network, trace and app data; (b) (a) without trace; (c) the approved evidence only | (a) | user |
| 4 | What passes a check? | (a) only `wait` or `is` steps with batch exit 0 plus `sim verify` GREEN, a test pass, or a state exit 0; (b) (a) plus `get` steps | (a): the installed guide says `get` alone isn't proof | user |
| 5 | Where does `qa/` live? | (a) the validation worktree's `.harness/qa/<plan>/`, copied into plan state by the orchestrator; (b) a tracked `qa/` folder in the repository; (c) plan state in the git common dir, with a new guard exception for the validation agent | (a): no guard change, no second tracked format | user |
| 6 | How do final passes share the recording lock? | (a) a 1-slot machine-wide recording lock; (b) final passes run 1 at a time by design | (a) | user |
| 7 | Who confirms a check fails first? | (a) the gate: `prove --proof-base` for acceptance, `qa run --at-base` for flow and state; (b) the worker's recorded reason | (a) | user |
| 8 | What may the validation worker write? | (a) acceptance test files named in its write set, plus `qa/`; (b) (a) plus contract additions it finds missing | (a): it reports a missing name and the orchestrator amends the contract | user |
| 9 | Do sprint and design-free ship get the table? | (a) not in the first cut; (b) yes, as an optional spec-page section | (a) | user |
| 10 | Where does the report live, and how does the run viewer show it? | Location: (a) `.harness/runs/<runID>/qa/report.json` plus rows in `/swift-validate`; (b) `/swift-validate` rows only. Layout: tabs with a Validation tab (variant B of the validation layout mockups) | Location: (a). Layout: decided, tabs (§9.2) | location: user; layout: decided (user, 2026-10-04) |
| 11 | Do flows run after each merge, or only at `validate`? | (a) after each merge for the rows it unblocks, stop at the first red layer; (b) acceptance after each merge, flow and state at `validate` only | (a) | user |
| 12 | The pin | (a) 0.21.18, the installed version every cited help text comes from; (b) keep 0.21.16 and recapture | (a) | user |
| 13 | ADR | (a) a new ADR that amends [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md) for run-scoped batch flows and the recording lock; (b) edit [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md) | (a): ADRs record history | user |
| 14 | How long does `qa run --final` wait when another recording holds the Mac? | (a) retry every 15 s for up to 5 minutes per flow, then run without video and mark the video `unverified`; (b) no wait: mark it `unverified` at once; (c) wait with no bound | (a): a bound keeps the final pass from hanging on a session the harness can't see | user |
| 15 | How does a server's port reach its checks? | (a) the row binds port 0, reads the port the OS assigned, and passes it as the `QA_PORT` environment variable to the row's commands and scripts; (b) a port range per worktree in `.swiftgate.toml` | (a): no config, no collisions between runs | user |
| 16 | What happens when more than 1 device shares the base's name and `os`? | (a) a non-gating note naming each UDID, and the lowest UDID as today; (b) `BLOCKED` until 1 remains; (c) no change | (a): no silent pick, and no new way to block a gate | user |
| 17 | Kept flows: XCUITest or `agent-device` batch? | (a) keep the split: batch for prepared flows that serve 1 run, XCUITest for kept regression flows; a prepared flow that proves its worth moves to XCUITest through its contract-named identifiers; (b) promote batch flows to the kept regression format: a tracked `qa/` folder, plus a new ADR superseding that part of [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md) | (a), for now: `agent-device` is pre-1.0 and its pin has already moved from 0.21.16 to 0.21.18; XCUITest compiles against the app and already runs in the gate; the §11 items (`batch --json`, `record` inside a batch, the `--session` and `--udid` binding) are still unverified; and every replay would depend on the `sim up` UDID lease. Revisit once the capture task settles §11 and the steps format holds across releases | user |

## 13. Changes to the plan, once approved

- The capture task also captures `batch --json` success and failure, `record start`, `record stop`, `record
  contact-sheet`, `logs`, `network dump` and `trace` at the pin.
- A task adds `swiftgate qa run` and `qa.check` events, surface first.
- A task adds the 3 `qa.flow-*` rules and the `plan-lint` rules, each with a fixture and a rule-index row.
- The QA skill task gains the validation worker's brief and the final-pass recording.
- The `validate` stage task calls `swiftgate qa run --final`.
- A run viewer task adds the validation column and the red-row popover.
- A brownfield task teaches `plan import` the `## Validation` section.
