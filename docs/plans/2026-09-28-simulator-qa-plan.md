# Simulator QA: implementation plan

<!-- RESUME
Status: NOT STARTED; amended 2026-10-04 before wave 1. Next: wave 1.
Spec: docs/designs/2026-09-28-simulator-qa-design.md (approved 2026-09-28), amended by docs/designs/2026-10-04-simulator-qa-layered-evidence-amendment.md (approved 2026-10-04). Decision records: [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md), amended by [ADR 0008](../adrs/0008-simulator-qa-layered-validation.md).
Scope: sub-project 3. `swiftgate sim up · snap · verify · down` and its holder process, the `agent-device` adapter and pin, dependency scenarios and `sim.scenario-drift`, the 7 `sim verify` rules, the validation table and `swiftgate qa run · lint` with the 5 `qa.flow-*` rules, the final pass with video and logs, the run viewer's tabs and Validation tab, `/swift-harness:qa`, its callers, a brownfield iOS trial, and an acceptance run on `examples/SampleApp`. Profiling (sub-project 4) is out of scope.
Order: the waves reach a useful brownfield iOS run first: `sim up`, `qa run` over acceptance and state rows, the flow lint rules, the `## Validation` import and the batch flow runner land by wave 6, the brownfield wiring in wave 7 and its trial in wave 8. Recording, the final pass and the run viewer follow.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec and the amendment by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan". Interfaces note: docs/handoffs/subproject-3-interfaces.md (the first wave's merge creates it; each wave appends).
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate, with mutate once on main per wave or per 2 waves.
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

The design and its amendment leave each of these open. None changes an approved choice in §11 or in the amendment's §12. The 2 marked "user" are cheap to
reverse, and the orchestrator may go ahead with the recommendation, since the user delegated approvals for
2026-09-28, but it should say so in the wave's merge note.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| The pinned version | `npm view agent-device version` was 0.21.16 on 2026-09-28; this Mac runs 0.21.18 on 2026-10-04, and 0.21.20 is out with the same step schemas (amendment §11.1, decision 12) | Pin 0.21.18. `agent-device-adapter-drives-the-pinned-cli` installs it with `npm i -g agent-device@0.21.18` and records the line in the fixtures README; any bump recaptures the fixtures and the schemas | — |
| Where the pin lives | §4: "in the plugin beside the `agent-device` fixtures"; the adapter needs it at runtime, and Tests fixtures don't ship to the binary | A Swift constant `AgentDevicePin.version` in `A/AgentDevice/`, and a test that fails when the captured `--version` fixture differs from it, so recapture and pin move together | — |
| Launch arguments | §6 calls forwarding unverified; `agent-device help open` at 0.21.16 lists `--launch-args <arg>`, "forwarded verbatim to the platform launch command" | `sim up` opens the app with `agent-device open <bundle id> --udid <udid> --session <name> --launch-args -harness-scenario --launch-args <scenario>`. The capture task confirms the app sees it; if it doesn't, that task reports a DEVIATION and `sim up` launches with `simctl launch` first | — |
| Which session the holder watches | §7.2: the holder exits "when the session that started it is gone" | The `agent-device` session the lease names: gone from `agent-device session list --json` once recorded. A dead Claude session is covered by `[qa] session_timeout_minutes` | — |
| Lease storage and `sim.not-owner` | §7.5: a lease covers 1 worktree and 1 device; `.harness/` is per checkout, so only a machine-wide record can show another worktree's lease | 1 JSON file per run beside the `sim` counting lock's slot files (`<lock dir>/sim-leases/<run id>.json`): `runID`, `worktree` (canonical root), `udid`, `holderPID`, `session`. `snap`, `verify` and `down` take an optional `<runID>`, default the caller's newest live lease; a lease naming another worktree is `sim.not-owner` | — |
| How the holder keeps the slot | §7.2; `SimulatorClones.withClone` holds 1 `sim` slot for a closure's life and names the device with its owner PID, so the orphan sweep deletes it once that PID dies | `swiftgate sim hold` is the device's owner: it runs `withClone` with its own PID, writes the lease, and returns from the closure on release, session loss or timeout. No second lock or sweep | — |
| Accessibility roles are a closed type | Worker brief pitfall 1; the tree is third-party output, and an unknown role must not quietly skip the 2 rules | `SimElementRole` lists every iOS role the pinned version can emit, read from the installed package and recorded in the fixtures README. An unknown role fails parsing, which `sim verify` reports as `sim.evidence-missing` naming the role. A version bump means recapture anyway ([ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md)) | — |
| "Readable label" | §5.2, standards §7: "visible text, or `.accessibilityLabel` for icon-only controls" | Readable: non-empty after trimming and not equal to the element's identifier. Anything subtler is review's | — |
| How `sim verify` sees an app exit | §5.2 needs a pure rule over the run directory | `sim snap` also calls `agent-device appstate --json` and adds `appState` to the step line (1 key beyond §5.1). `sim down` copies crash reports for the bundle's process, newer than `startedAt`, into `sim/crashes/`. `sim.app-exited` reads both | — |
| Typed `wait` failures | §9 lists them as `RED`, but `sim verify` sees only what the run directory holds, and the agent's own `wait` never reaches it | The adapter parses the typed error and the skill reports it as a failed flow. `sim verify` doesn't judge it. No rule id | — |
| The runner build failure (§9) | Breaking the `agent-device` XCTest runner on purpose to capture its output isn't practical, and fixtures are never hand-written | Any `open` failure that isn't an app-level error is `sim.driver-failed` (`BLOCKED`, naming `agent-device.log`), tested with the captured `DEVICE_IN_USE` and unknown-device errors | — |
| Where `sim.scenario-drift` finds the enum | §6 names the enum, not its file | `arch` scans Swift files outside the `packages` globs and `exclude` for `enum Scenario: String`. 0 enums with a non-empty `[[scenarios]]`, 2 or more, or different names is drift. No `[[scenarios]]` and no enum passes: the repo hasn't adopted scenarios | — |
| What bootstrap stamps | §6: "The bootstrap template stamps the enum with 1 case, `live`"; bootstrap today stamps harness files only, never app source | Bootstrap writes `Scenario.swift` beside the one file outside `packages` that declares `@main` on an `App`, and the `[[scenarios]] live` entry only when it creates `.swiftgate.toml`. With 0 or 2+ entry points, or an existing config, it prints the file and the 1-line call to add under "consider" and writes nothing | — |
| `sim_qa` in presets | Every preset key is required today (`BuildPreset` doc comment); §8.2: the template stamps `changed` | Required, like every other key: a preset without it fails `doctor` naming the key. A consumer repo with presets adds 1 line on upgrade | user |
| When `doctor` needs `agent-device` | A missing CLI blocks `doctor` for repos that never run QA | `doctor.agent-device` is `BLOCKED` when any preset sets `sim_qa = "changed"` or `[[scenarios]]` is non-empty; otherwise a `nit` note | user |
| The macOS permission (§9, unverified) | Survey §4 | The capture task records whether any Accessibility or Screen Recording prompt appeared. If one did, `doctor-checks-the-agent-device-pin` adds the check with the captured failure as its fixture; if none did, no rule and a line in the fixtures README | — |
| Kept flows in the acceptance run | §8.1 step 4 asks the user; the user delegated approvals for this run | The orchestrator answers "keep" once, if the skill proposes a flow, to exercise §8.3 end to end; otherwise it records that none was proposed | — |
| Where the step schemas live | Amendment §6.1 and [ADR 0008](../adrs/0008-simulator-qa-layered-validation.md): `qa.flow-schema` reads the pinned tool's `tools/list` schemas at runtime, and Tests fixtures don't ship to the binary | The capture task writes the captured `tools/list` output to `plugin/qa/agent-device-schemas-<pin>.json`; `swiftgate qa lint` reads it from the plugin root, as bootstrap reads `templates/`, and a test fails when its version differs from `AgentDevicePin.version` | — |
| Where `qa.flow-unknown-id` finds the ids | Amendment §6.1, decision 17: a typed accessibility-id module the app and its UI tests share | `[qa] accessibility_ids = "<repo-relative Swift file>"` names it; the file declares 1 `enum AccessibilityID: String` whose raw values are the ids. With no key set, the rule reports a non-gating `qa.flow-ids-unknown` note naming the missing key and checks nothing else (worker brief pitfall 4) | — |
| How a row reaches its server | Amendment decision 15 | `qa run` binds port 0, reads the assigned port, and exports `QA_PORT` to every command and script of that row; the row's own command starts the server on `$QA_PORT` | — |
| The recording lock | Amendment decision 6 and 14 | A `FileCountingLock` named `sim-record` with capacity 1. `apple_simulator_recording_busy` from a recording outside the harness retries every 15 s for up to 5 minutes on an injected clock, then the flow runs without video | — |
| Where `qa/` lives | Amendment decision 5; the edit guard denies subagent writes outside the checkouts and into `.git` | The validation worker writes `<worktree>/.harness/qa/<plan>/`. The orchestrator copies it into `<plans>/<slug>/qa/` with `swiftgate qa adopt <worktree>`, the only writer of that folder | — |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and behaviour, and
  proves at it (worker brief pitfall 10), and runs `swiftgate surface-check <surface sha>` on it.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a wave,
  merge every surface commit first and prove at that merge. Mutate runs once on `main` after each wave, or once per
  2 waves when the first of the pair adds only skill or doc text.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Live simulator work.** Tasks that capture fixtures or run `sim` for real use a clone or created device through the
  harness (`sim` lock), never the pinned base device, and never a device another session is using. Capture steps run
  in the foreground; each capture command goes in `plugin/gate/Tests/Fixtures/README.md` exactly.
- **Generic harness.** No task names an app shape, practice prompt or preset value beyond the template's. SampleApp's
  scenario is a plain example.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `R/` = `plugin/gate/Sources/SwiftGateRules/`,
  `S/` = `plugin/gate/Sources/SwiftGateTestSupport/`, `TD/` `TA/` `TC/` `TR/` =
  `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI,Rules}Tests/`, `F/` = `plugin/gate/Tests/Fixtures/`,
  `P/` = `plugin/`, `SA/` = `examples/SampleApp/`.

### Merge points (hot files)

| File | Edited only by |
|---|---|
| `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift` | `sim-hold-keeps-a-simulator-slot` (registers the `sim` group), then `qa-run-checks-acceptance-and-state` (registers the `qa` group) |
| `C/Commands/SimCommand.swift` (subcommand list) | `sim-hold-keeps-a-simulator-slot`, then `sim-up-launches-the-app-in-a-scenario`, then `sim-snap-records-a-step`, then `sim-verify-judges-step-evidence`, then `sim-down-releases-the-device-and-claims` (1 per wave) |
| `plugin/docs/standards.md` rule id index | at most 1 task per wave per subsection: "Harness and environment" (`doctor-checks-the-agent-device-pin`), "Code rules" (`arch-checks-scenario-drift`), a new "Simulator QA commands (`sim up`, `snap`, `down`)" (`sim-up-launches-the-app-in-a-scenario`, then `sim-snap-records-a-step`), a new "Simulator QA evidence (`sim verify`)" (`sim-verify-judges-step-evidence`, then `sim-verify-requires-accessible-controls`, then `sim-verify-reports-app-exits`) |
| `plugin/docs/standards.md` §7 (Accessibility) | `sim-verify-requires-accessible-controls` |
| `F/README.md` | `agent-device-adapter-drives-the-pinned-cli`, `qa-run-drives-batch-flows`, `sim-verify-requires-accessible-controls`, `sim-verify-reports-app-exits`, `qa-final-pass-records-flows`, `t3-keeps-flow-video`, `run-viewer-shows-validation-rows` (1 per wave) |
| `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `A/Config/ConfigDecoding.swift` | `config-declares-scenarios-qa-and-sim-qa`, then `qa-flow-lint-checks-steps-offline` (`[qa] accessibility_ids`). Fast-modes' `presets-may-skip-design` edits `BuildPreset`: whichever merges second rebases |
| `P/templates/swiftgate.toml` | `config-declares-scenarios-qa-and-sim-qa`, then `bootstrap-stamps-a-live-scenario` |
| `SA/.swiftgate.toml` | `sample-app-declares-typed-accessibility-ids` (wave 2, `[qa]`), then `arch-checks-scenario-drift` (wave 3, `[[scenarios]]`) |
| `C/Commands/GCCommand.swift`, `A/SimulatorClones.swift` | `sim-down-releases-the-device-and-claims`, then `base-device-lookup-notes-duplicates` (`sim-hold-keeps-a-simulator-slot` only calls `SimulatorClones`) |
| `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/validate/SKILL.md`, `P/skills/sprint/SKILL.md`, `P/skills/ship/SKILL.md` | `callers-run-simulator-qa`. Sub-project 4's plan also targets the `validate` stage: whichever merges second rebases |
| `docs/index.md` | `qa-skill-drives-flows-to-a-verdict`, then `callers-run-simulator-qa` |
| `tests/skill_commands_test.mjs` | `brownfield-run-validates-each-merge`, then `qa-skill-drives-flows-to-a-verdict`, then `plan-skill-writes-the-validation-table`, then `callers-run-simulator-qa` (1 per wave) |
| `C/Commands/QACommand.swift`, `C/Commands/QARunCommand.swift` | `qa-run-checks-acceptance-and-state` (creates them), then `qa-flow-lint-checks-steps-offline`, then `qa-run-drives-batch-flows`, then `qa-final-pass-records-flows` (1 per wave) |
| `P/skills/run/references/plan-shape.md` | `validation-table-imports-from-plan-md`, then `brownfield-run-validates-each-merge` |
| `P/skills/build/references/event-loop.md` | `brownfield-run-validates-each-merge`, then `callers-run-simulator-qa` |
| `plugin/viewer/run-viewer.js`, `plugin/docs/run-viewer.md` | `run-viewer-tabs-the-report`, then `run-viewer-shows-validation-rows` |

### Risks

- **Live simulators under load.** Capture and acceptance tasks boot devices on a machine that also runs T2/T3 gates.
  They share the `sim` cap, so they queue rather than fail; a task that waits past its lock timeout reports `BLOCKED`
  with the holders' PIDs, not a flake.
- **`agent-device` output drift.** The adapter parses a third-party CLI. The pin plus the fixtures-equal-pin test
  make an unplanned upgrade fail loudly; a planned one is a recapture task.
- **Skill routing.** A new skill can move routing in the evals session's sets. Tell that session before
  `qa-skill-drives-flows-to-a-verdict` merges.
- **Standards index churn.** 13 tasks add rows. The subsection split keeps each wave to non-adjacent hunks.

## Wave map

The waves put the fastest path to a useful brownfield iOS run first (amendment §13). Waves 1 to 6 land `sim up`,
`qa run` over all 3 layers, the flow lint rules and the `## Validation` import. Wave 7 wires them into the
brownfield run, and wave 8 tries it on a real iOS repository. Recording, the final pass and the run viewer follow.

| Wave | Tasks | Why |
|---|---|---|
| 1 | `agent-device-adapter-drives-the-pinned-cli`, `config-declares-scenarios-qa-and-sim-qa`, `sample-app-selects-a-scenario-by-launch-argument`, `validation-table-imports-from-plan-md` | independent foundations: the driver, its fixtures and schemas, config, the example app's scenario, and the validation table |
| 2 | `sim-tree-reads-agent-device-snapshots`, `sim-hold-keeps-a-simulator-slot`, `doctor-checks-the-agent-device-pin`, `sample-app-declares-typed-accessibility-ids` | the tree parser and doctor need the captured fixtures; the holder needs `[qa]` config; the id module needs the scenario's UI test |
| 3 | `sim-up-launches-the-app-in-a-scenario`, `qa-run-checks-acceptance-and-state`, `arch-checks-scenario-drift`, `bootstrap-stamps-a-live-scenario` | `sim up` needs the holder; `qa run` needs the table; drift lands with SampleApp's config entry |
| 4 | `sim-snap-records-a-step`, `qa-flow-lint-checks-steps-offline` | `snap` needs a session; the lint needs the schemas, the id module and the `qa` group |
| 5 | `sim-verify-judges-step-evidence`, `sim-down-releases-the-device-and-claims` | judge and tear down what `sim up` and `snap` made |
| 6 | `qa-run-drives-batch-flows`, `base-device-lookup-notes-duplicates` | the flow runner needs `up`, `verify`, `down` and the lint; the note edits `SimulatorClones` after `down` |
| 7 | `brownfield-run-validates-each-merge`, `sim-verify-requires-accessible-controls` | the run skill calls every `qa` command, now present |
| 8 | `brownfield-ios-trial-runs-validation`, `qa-skill-drives-flows-to-a-verdict`, `sim-verify-reports-app-exits` | the trial needs the wired run; the skill names every command |
| 9 | `qa-final-pass-records-flows`, `plan-skill-writes-the-validation-table` | recording wraps the flow runner; the design-plan path reuses the table |
| 10 | `t3-keeps-flow-video`, `callers-run-simulator-qa`, `run-viewer-tabs-the-report` | the callers' `validate` stage runs `qa run --final`, now present |
| 11 | `run-viewer-shows-validation-rows` | reads `qa.check` and `qa.flow` from both flow sources |
| 12 | `simulator-qa-acceptance-on-sample-app` | attended-style; the orchestrator runs it unattended |

### `agent-device-adapter-drives-the-pinned-cli`
- Deps: none · Gate: push · Model: opus · estLines: 560
- Writes: `A/AgentDevice/AgentDevice.swift` (protocol, live adapter), `A/AgentDevice/AgentDevicePin.swift`, `A/AgentDevice/AgentDeviceError.swift`, `S/FakeAgentDevice.swift`, `TA/AgentDeviceTests.swift`, `F/AgentDevice/` (captured), `F/README.md`, `plugin/qa/agent-device-schemas-0.21.18.json` (captured)
- Does: §4 layering. Installs `agent-device@0.21.18` with `npm i -g agent-device@0.21.18` and records the line in the fixtures README. Capture session (survey §5 part A) against `SA/` on a harness-created device: `agent-device --version`; `open com.example.SampleApp --udid <udid> --session <name> --launch-args -harness-scenario --launch-args live --json`; `snapshot --json`; `screenshot <path> --json`; `appstate --json`; `session list --json`; a typed failure from `wait text "<absent text>" 2000 --json`; an `open` refused with `DEVICE_IN_USE` and one for an unknown UDID; `device release --stale --json`; `close --json`. It records whether any macOS permission prompt appeared, and the iOS role vocabulary the installed package can emit, with the file it read. The `AgentDevice` protocol wraps these calls through `ProcessRunner`. Each call passes `--udid` and `--session`; `snapshotJSON` returns the raw bytes unmodified; a `--json` error decodes to `AgentDeviceError` with its typed code as a closed enum of the codes captured, plus the raw message. `AgentDevicePin.version` is `"0.21.18"`. For the amendment, the capture also takes `batch --steps-file <file> --json` on success and on a failing `wait`, `record start`, `record stop`, `record contact-sheet`, `logs path`, `network dump 25 --include headers`, `trace start` and `trace stop`, and the MCP server's `tools/list`, saved as `plugin/qa/agent-device-schemas-0.21.18.json`. The protocol adds `batch`, `recordStart`, `recordStop`, `contactSheet`, `logs`, `networkDump` and `trace`.
- Tests: the captured `--version` output equals `AgentDevicePin.version`, and so does the schema file's version (catches a recapture that forgets the pin). A failing batch decodes to the failing step's index and command. Each captured error decodes to its code and an unknown code fails decoding naming itself. Every call carries `--udid` and `--session` (catches a call that lets `agent-device` pick a device). `snapshotJSON` hands back the fixture's bytes unchanged (catches a parser rewriting evidence). A non-zero exit with unparseable stderr is an error naming the command, never an empty success.

### `config-declares-scenarios-qa-and-sim-qa`
- Deps: none · Gate: push · Model: opus · estLines: 260
- Writes: `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `D/Build/BuildPreset.swift`, `A/Config/ConfigDecoding.swift`, `P/templates/swiftgate.toml` (`sim_qa` in each preset, a commented `[qa]` block), their tests
- Does: §6, §7.2, §8.2. `[[scenarios]]` entries `{name, reason}` (non-empty, unique, kebab-case), `[qa] session_timeout_minutes` (default 30, range 1...240), and a required `sim_qa` preset key, a closed enum `changed` | `off`. Every failure is a `ConfigIssue` naming the key.
- Tests: a preset without `sim_qa` fails naming `build.presets.<name>.sim_qa` (catches a silent default). `sim_qa = "sometimes"` fails naming the allowed values. A duplicate or blank scenario name fails. `session_timeout_minutes = 0` fails `outOfRange`. The template's presets decode with `sim_qa = changed` (catches a template that no longer loads).

### `sample-app-selects-a-scenario-by-launch-argument`
- Deps: none · Gate: ready · Model: opus · estLines: 140
- Writes: `SA/App/Scenario.swift`, `SA/App/SampleApp.swift`, `SA/UITests/CounterFlowUITests.swift`
- Does: §6. A `DEBUG`-only `enum Scenario: String, CaseIterable` with `live` and `fixed-fact` (the API client returns 1 fixed fact, so the flow needs no network), each with `apply(to: inout DependencyValues)`. The app's `init` reads `-harness-scenario <name>` and calls `prepareDependencies { Scenario(rawValue: name)?.apply(to: &$0) }` before the store exists; an unknown name calls `reportIssue` and runs live. SampleApp's `.swiftgate.toml` gets its `[[scenarios]]` in `arch-checks-scenario-drift`, the task that enforces it.
- Tests: a new method in `CounterFlowUITests` (flow `counter`) launches with `-harness-scenario fixed-fact`, taps `counter.fact`, and asserts the fixed text in `counter.factText`: it fails with the entry point's `prepareDependencies` call removed (catches an app that ignores the argument). T3 runs it.

### `sim-tree-reads-agent-device-snapshots`
- Deps: agent-device-adapter-drives-the-pinned-cli · Gate: push · Model: opus · estLines: 240
- Writes: `D/SimQA/SimTree.swift`, `TD/SimTreeTests.swift`
- Does: §5.2's input. Pure parse of the captured `snapshot --json` into elements `{role, identifier?, label?, value?, children}`, with `SimElementRole` the closed role list the capture task recorded, and `isInteractive` true for button, switch, text field and cell. A missing identifier or label is `nil`, never `""` (pitfall 2). `SimTree.contains(text:)` matches a label or value exactly.
- Tests: the captured SampleApp tree yields its 4 buttons with their identifiers (catches a parser that drops nested nodes). An unknown role fails parsing naming the role (catches a role silently read as non-interactive). An element with an empty label parses to `label == nil`. `contains(text:)` finds the counter value and not a substring of it.

### `sim-hold-keeps-a-simulator-slot`
- Deps: config-declares-scenarios-qa-and-sim-qa, agent-device-adapter-drives-the-pinned-cli · Gate: push · Model: opus · estLines: 380
- Writes: `C/Commands/SimCommand.swift` (the group), `C/Commands/SimHoldCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `D/SimQA/SimLease.swift`, `A/SimQA/SimLeaseStore.swift`, `A/SimQA/DetachedLauncher.swift`, their tests
- Does: §7.1-7.2. `swiftgate sim hold --run <runID>` (internal; `sim up` starts it detached with `DetachedLauncher`, in its own session, stdio to `agent-device.log`) runs `SimulatorClones.withClone` with its own PID as owner, writes the lease (keys in Decisions) by atomic rename, then waits until the lease file is removed, the lease's `session`, once recorded, is gone from `agent-device session list --json`, or `session_timeout_minutes` passes. It then removes the lease and returns, so the clone is deleted and the slot freed. `SimLease.owner(of:callerWorktree:)` is the pure ownership check later commands call.
- Tests: with a real `FileCountingLock` of capacity 2 in a temp directory and `FakeSimctl`, 2 holders get devices and a third waits until 1 releases (§10 isolation, catches a holder outside the shared cap). Removing the lease ends the holder and deletes its device. A timeout of 1 minute, driven by an injected clock, ends it. A lease from worktree A checked by worktree B is `.otherWorktree` (pitfall 5 cross case). Killing the holder with SIGKILL leaves a device whose owner PID is dead, which the next `sweepOrphans` deletes (§10 kill test, device half).

### `doctor-checks-the-agent-device-pin`
- Deps: agent-device-adapter-drives-the-pinned-cli, config-declares-scenarios-qa-and-sim-qa · Gate: push · Model: opus · estLines: 180
- Writes: `D/Doctor/Doctor.swift`, `C/Commands/DoctorCommand.swift`, `F/Doctor/` (captured `agent-device --version` and the not-found error), `TD/DoctorTests.swift`, `TC/DoctorCommandTests.swift`, `plugin/docs/standards.md` ("Harness and environment" row)
- Does: §4, §9 row 1. `DoctorFacts.agentDeviceVersion: String?`. `doctor.agent-device` is `BLOCKED` with the exact `npm i -g agent-device@<pin>` line when QA is configured (Decisions) and the CLI is missing or not the pin; otherwise a `nit`. If the capture task found a permission prompt, the same task adds its check with the captured failure; otherwise nothing.
- Tests: missing CLI in a QA repo is `BLOCKED` with the install line (catches a doctor that passes a machine `sim up` will block on). 0.21.15 is `BLOCKED` naming both versions. A repo with every preset at `sim_qa = "off"` and no scenarios gets a `nit`, never `BLOCKED`. The rule id is in the index.

### `sim-up-launches-the-app-in-a-scenario`
- Deps: sim-hold-keeps-a-simulator-slot, sim-tree-reads-agent-device-snapshots, sample-app-selects-a-scenario-by-launch-argument · Gate: push · Model: opus · estLines: 480
- Writes: `C/Commands/SimUpCommand.swift`, `C/Commands/SimCommand.swift` (subcommand list), `D/SimQA/SimSession.swift`, `D/SimQA/SimUpFailure.swift`, `A/SimQA/AppBundleReader.swift`, `plugin/docs/standards.md` (new "Simulator QA commands" subsection), their tests
- Does: §4 `sim up [--scenario <name>] [--json]`, §6, §9. In order: the pin (`sim.agent-device-pin`, `BLOCKED`, install line); the scenario against `[[scenarios]]` (`sim.scenario-unknown`, `RED`, before any build); start `sim hold` and wait for its lease (`sim.no-slot`, `BLOCKED`, naming the holders' PIDs); build the app scheme with the per-worktree DerivedData and `-skipMacroValidation` through the existing `Xcodebuild` adapter (`sim.app-build-failed`, `RED`, the build log); install; read the bundle id from the built app; `agent-device open` with the scenario argument (`sim.driver-failed`, `BLOCKED`, `agent-device.log`); record the session in the lease; write `session.json` (§5.1 keys, `schemaVersion` 1). Prints `{runID, udid, session, scenario}`; exit 0, 1 for `RED`, 3 for `BLOCKED`. Any failure after the hold starts removes the lease, so the holder frees the device.
- Tests: an unknown scenario exits 1 with no build or hold started (catches a build wasted on a typo). A wrong pin exits 3 before taking a slot. The captured `DEVICE_IN_USE` error is `sim.driver-failed` and leaves no lease behind (catches a leaked slot). A build failure is `RED` naming the log. The happy path with fakes writes `session.json` whose keys decode with an unknown key rejected, and passes `-harness-scenario <name>` to `open`. Each rule id is in the index.

### `arch-checks-scenario-drift`
- Deps: config-declares-scenarios-qa-and-sim-qa, sample-app-selects-a-scenario-by-launch-argument · Gate: push · Model: opus · estLines: 220
- Writes: `R/Arch/ScenarioDriftRule.swift`, `R/RuleCatalog.swift` (its entry), `C/Commands/ArchCommand.swift` (the app-source input), `SA/.swiftgate.toml` (`[[scenarios]]` for `live` and `fixed-fact`), `plugin/gate/Fixtures/arch/sim.scenario-drift/` (a drifted and a clean case, like the other `arch.*` fixtures), `TR/ScenarioDriftRuleTests.swift`, `plugin/docs/standards.md` ("Code rules" row)
- Does: §6 `sim.scenario-drift` (`RED`, `major`): the enum's case raw values and `[[scenarios]]` names differ, or the enum is missing or duplicated while `[[scenarios]]` is non-empty (Decisions). The finding names each name on 1 side only. It lands with SampleApp's config entry, so the sample passes the first time the rule runs.
- Tests: SampleApp passes `arch` (catches a rule switched on with no passing input). A config naming `offline` that the enum lacks fails naming `offline`. An enum case missing from the config fails naming it. No scenarios and no enum passes. Self-test's rule fixtures trip and pass as expected. The id is in the index.

### `bootstrap-stamps-a-live-scenario`
- Deps: config-declares-scenarios-qa-and-sim-qa · Gate: push · Model: opus · estLines: 240
- Writes: `P/templates/Scenario.swift`, `P/templates/swiftgate.toml` (`[[scenarios]] live`), `D/Bootstrap/BootstrapPlan.swift`, `A/Bootstrap.swift`, `F/Bootstrap/` (captured bootstrap runs), their tests, `P/skills/bootstrap/SKILL.md` (the "consider" line)
- Does: §6's last bullet, as Decisions sets it. On a repo with 1 `@main … : App` file outside `packages`, bootstrap creates `Scenario.swift` beside it with the `live` case and a `static func prepareFromLaunchArguments()` holding the `prepareDependencies` call, and the stamped config has `[[scenarios]] live`. It never edits the app file: its report prints the 1-line call to add. With 0 or 2+ entry points, or an existing config, it writes neither and prints both under "consider".
- Tests: a captured single-entry-point repo gets both files, and `arch` passes on it (catches a stamp that fails its own drift check). A repo with 2 entry points gets neither and a "consider" line naming both. A second run leaves an existing `Scenario.swift` untouched.

### `sim-snap-records-a-step`
- Deps: sim-up-launches-the-app-in-a-scenario · Gate: push · Model: opus · estLines: 300
- Writes: `C/Commands/SimSnapCommand.swift`, `C/Commands/SimCommand.swift` (subcommand list), `D/SimQA/SimStep.swift`, `A/SimQA/SimRunStore.swift`, `plugin/docs/standards.md` ("Simulator QA commands" rows), their tests
- Does: §4 `sim snap <label> [--assert "<text>"] [<runID>]`. Resolves the lease and refuses another worktree's (`sim.not-owner`, exit 1). Calls `screenshot` and `snapshot --json`, writes `steps/NNN.png` and `steps/NNN.tree.json` unmodified, and appends a step line (`n`, `label`, `assert?`, `screenshot`, `tree`, `settled`, `elapsedMs`) by append-and-fsync. A gone session or device is `sim.session-gone`, exit 1, and writes no half step.
- Tests: 2 snaps number `001` and `002` with the fixture tree's bytes on disk unchanged (catches rewritten evidence). A lease from another worktree is refused and writes nothing (pitfall 5). The captured session-gone error exits 1 with no step line and no orphan PNG. A step line with no `--assert` omits the key (pitfall 2). Each id is in the index.

### `sim-verify-judges-step-evidence`
- Deps: sim-snap-records-a-step · Gate: push · Model: opus · estLines: 380
- Writes: `D/SimQA/SimEvidenceRules.swift`, `C/Commands/SimVerifyCommand.swift`, `C/Commands/SimCommand.swift` (subcommand list), `plugin/docs/standards.md` (new "Simulator QA evidence" subsection), their tests
- Does: §5.2's first 4 rules as pure domain over a loaded run: `sim.no-steps`, `sim.evidence-missing` (a named file missing, or a tree that doesn't parse, naming why), `sim.assert-absent`, `sim.stale-head` (`headCommit` against the checkout's HEAD, read by the CLI). `sim verify [<runID>]` writes `report.json` (`schemaVersion`) and a history line like any check; exit 0 `GREEN`, 1 `RED`, 3 `BLOCKED` when the run directory can't be read.
- Tests: an empty `steps.ndjson` is `RED` `sim.no-steps` (catches an empty run passing). A step whose tree file is deleted is `sim.evidence-missing` naming it. An `--assert` text absent from the captured tree is `sim.assert-absent`, and a present one passes. A HEAD that moved since `sim up` is `sim.stale-head`. A run the command can't read exits 3, never `GREEN`. The history line records the run id and verdict. Each id is in the index.

### `sim-verify-requires-accessible-controls`
- Deps: sim-verify-judges-step-evidence · Gate: push · Model: opus · estLines: 240
- Writes: `D/SimQA/SimAccessibilityRules.swift`, `F/AgentDevice/seeded/` (captured), `F/README.md`, `plugin/gate/Fixtures/seeds/sim-verify/` (self-test cases), `C/Commands/SelfTestCommand.swift` (`SeedFamily.simVerify`), `plugin/docs/standards.md` (§7 "Enforced by", and 2 "Simulator QA evidence" rows), their tests
- Does: §5.2 `sim.a11y-identifier` and `sim.a11y-label`, both `RED`, naming the step and the element's role and label or identifier. Capture: on a local, never-merged SampleApp branch that adds 1 button with no identifier and 1 icon-only button with no label, `sim up`, then `sim snap` on the screen, and copy the trees into `F/AgentDevice/seeded/`; the README names the branch diff and each command. Standards §7 moves from "review" to these rule ids.
- Tests: the seeded tree fails both rules on the right elements, and the clean SampleApp tree passes (catches a rule that flags static text). Self-test's `sim-verify` seeds go `RED` on the seeded run and `GREEN` on the clean one (§10 seeded violations). Removing the interactive check turns the clean case `RED` (pitfall 6).

### `sim-down-releases-the-device-and-claims`
- Deps: sim-snap-records-a-step · Gate: push · Model: opus · estLines: 240
- Writes: `C/Commands/SimDownCommand.swift`, `C/Commands/SimCommand.swift` (subcommand list), `C/Commands/GCCommand.swift`, `A/SimulatorClones.swift` (a sweep hook for `agent-device` claims), their tests
- Does: §4 `sim down [<runID>]` and §7.4. Refuses another worktree's lease (`sim.not-owner`). Closes the `agent-device` session, removes the lease, waits for the holder to exit and the device to go, then runs `agent-device device release --stale`. Idempotent: a second call, or a call with no lease, exits 0. `gc` and the orphan sweep also run `release --stale` when `agent-device` is present.
- Tests: `down` twice exits 0 both times and calls `close` once (catches a non-idempotent teardown). After `down` the lease file and device are gone. Another worktree's lease is refused and its device survives (pitfall 5). With a holder killed by SIGKILL, the next `gc` deletes the device and calls `release --stale` (§10 kill test, claim half).

### `sim-verify-reports-app-exits`
- Deps: sim-verify-requires-accessible-controls, sim-down-releases-the-device-and-claims · Gate: push · Model: opus · estLines: 260
- Writes: `D/SimQA/SimExitRule.swift`, `D/SimQA/SimStep.swift` (`appState`), `C/Commands/SimSnapCommand.swift` (records `appstate`), `C/Commands/SimDownCommand.swift` (copies crash reports), `A/SimQA/CrashReportReader.swift`, `F/AgentDevice/crash/` (captured), `F/README.md`, `plugin/docs/standards.md` (1 "Simulator QA evidence" row), their tests
- Does: §5.2 `sim.app-exited`, `RED`, naming the step and the crash report path. Capture: `sim up` on SampleApp, kill the app process on the device with `SIGABRT` (`xcrun simctl spawn <udid> kill -ABRT <pid>`), then `agent-device appstate --json` and the resulting `.ips` report. `sim snap` adds the step's `appState`; `sim down` copies reports for the bundle's process newer than `startedAt` into `sim/crashes/`.
- Tests: the captured post-crash `appstate` is `sim.app-exited` naming the copied report (catches a crash that still verifies `GREEN`). A run with the app in front at every step and no crash file passes. A report older than `startedAt` is ignored. The id is in the index.

### `qa-skill-drives-flows-to-a-verdict`
- Deps: sim-down-releases-the-device-and-claims, sim-verify-judges-step-evidence, qa-run-drives-batch-flows · Gate: push · Model: opus · estLines: 300
- Writes: `P/skills/qa/SKILL.md`, `P/skills/qa/references/validation-worker.md`, `tests/skill_commands_test.mjs` (its rows), `docs/index.md` (router row)
- Does: §8.1 and §8.3. Picks flows from the changed feature modules' screens and any flow the spec page or plan task names. Per flow: `sim up --scenario`, an inspect, act, verify loop through `agent-device` (MCP or CLI, always with the run's `--udid` and `--session`), `sim snap` at every checked point, then `sim verify` and `sim down`. `RED` hands off to `/swift-harness:tdd`; `BLOCKED` runs `doctor`. It proposes flows to keep and asks with `AskUserQuestion`; the skill writes a kept flow test-first with `/swift-harness:tdd` as an XCUITest plus a `[[flows]]` entry, and at `max_flows` it asks which to drop. It never keeps a flow unasked and never states a verdict `sim verify` didn't print. With a `validation.json`, it runs the prepared rows with `qa run` first and explores beyond them; its validation worker brief matches the run skill's (amendment §5). A kept flow uses the app's `AccessibilityID` module. It stays generic.
- Tests: every `swiftgate` command and flag the skill names exists (contract test). `claude plugin validate --strict` passes. The skill's step order matches `up`, `snap`, `verify`, `down`.

### `callers-run-simulator-qa`
- Deps: qa-skill-drives-flows-to-a-verdict, config-declares-scenarios-qa-and-sim-qa, qa-final-pass-records-flows · Gate: push · Model: opus · estLines: 200
- Writes: `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/sprint/SKILL.md`, `P/skills/ship/SKILL.md`, `P/skills/validate/SKILL.md`, `tests/skill_commands_test.mjs` (their rows), `tests/preset_profile_skills_test.mjs` if it pins these steps
- Does: §8.2. The build's `validate` stage runs after the final `ready` gate on merged `main`. When the preset's `sim_qa = "changed"`, it runs `swiftgate qa run --final` if the plan has a `validation.json`, then `/swift-harness:qa`. Otherwise it prints `validate: sim_qa off`. Sprint does the same after `sprint finish`, and ship after its final gate. `/swift-validate` adds a "Simulator QA" row with the verify run's id, verdict and step count, 1 row per validation row from `qa/report.json` with its result and evidence paths (amendment §9.1), and lists a skipped QA under "Not run".
- Tests: the contract test finds each caller naming `/swift-harness:qa` and the `sim_qa` key, and no caller still prints `validate: not configured`. The validate block's "Simulator QA" row reads its values from `report.json` keys that `sim verify` writes.

### `validation-table-imports-from-plan-md`
- Deps: none · Gate: push · Model: opus · estLines: 380
- Writes: `D/Plan/ValidationTable.swift`, `D/Plan/PlanLintValidation.swift`, `D/Brownfield/LivePlan.swift` (the `## Validation` section), `C/Commands/PlanImportCommand.swift`, `C/Commands/PlanLintCommand.swift`, `P/skills/run/references/plan-shape.md` (the section's shape), `plugin/docs/standards.md` (plan-lint rows), their tests
- Does: amendment §4.1, §4.3. A row is `{requirement, layer, check, runsAfter, writer, reason?}`: `requirement` a `req-<name>` id, `layer` a closed enum `acceptance` | `flow` | `state`, `runsAfter` ledger task ids. `plan import` reads the `## Validation` table of `PLAN.md` into `<plans>/<slug>/validation.json` (`schemaVersion` 1) beside `ledger.json`. `plan-lint` adds `plan-lint.validation-uncovered` (a requirement with no non-unit row and no `reason`), `plan-lint.validation-unknown-task`, `plan-lint.validation-state-without-flow` and `plan-lint.validation-flow-without-ios` (a flow row in a repository with no iOS area). A plan with no `## Validation` section imports as before, with a non-gating note.
- Tests: a captured brownfield `PLAN.md` with a `## Validation` table imports every row, and a row with layer `unit` fails import naming the line (catches a layer read as free text). Each lint rule fires on its case and passes the clean plan. A plan without the section imports unchanged with the note (catches a silent drop). Each id is in the index.

### `sample-app-declares-typed-accessibility-ids`
- Deps: sample-app-selects-a-scenario-by-launch-argument · Gate: ready · Model: opus · estLines: 160
- Writes: `SA/Packages/AccessibilityIDs/` (a package with 1 `enum AccessibilityID: String`), `SA/App/SampleApp.swift`, `SA/Packages/CounterFeature/Sources/` (the view's `.accessibilityIdentifier` calls), `SA/UITests/CounterFlowUITests.swift`, `SA/SampleApp.xcodeproj/` (the package in both targets, a test plan with `systemAttachmentLifetime` `keepAlways` for UI tests), `SA/.swiftgate.toml` (`[qa] accessibility_ids`)
- Does: amendment decision 17. The app and its UI tests read every identifier from `AccessibilityID`, so a typo fails to compile. The UI test plan keeps attachments on a pass, so T3 leaves an MP4 and per-step activities.
- Tests: the counter flow's UI test uses `AccessibilityID.counterFact.rawValue` and passes in T3 (the existing assertion). Renaming a case breaks the UI test's build (recorded in the task's report, since a compile error isn't an assertion). A T3 run's xcresult holds a video attachment for the passing test (catches a test plan that didn't take).

### `qa-run-checks-acceptance-and-state`
- Deps: validation-table-imports-from-plan-md, config-declares-scenarios-qa-and-sim-qa · Gate: push · Model: opus · estLines: 520
- Writes: `C/Commands/QACommand.swift` (the group), `C/Commands/QARunCommand.swift`, `C/Commands/QAAdoptCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `D/QA/QARow.swift`, `D/QA/QARunPlan.swift`, `D/QA/QAReport.swift`, `D/Events/QAEvents.swift`, `D/Events/HarnessEvent.swift` (the `qa.check` kind), `A/QA/QACommandRunner.swift`, `plugin/docs/standards.md` (new "Simulator QA validation" subsection), their tests
- Does: amendment §6, §6.2, §8.2, decisions 5, 7, 11 and 15. `qa run [--after <task>] [--at-base] [--json]` reads `validation.json`, picks the rows whose `runsAfter` tasks have all merged, and runs them in layer order: acceptance, flow, state. It stops at the first layer with a red row. An acceptance row runs its command; a state row runs its script; each gets `QA_PORT` from a port the OS assigned. A row's result is a closed enum `pass` | `red` | `unverified` | `waiting`. Until `qa-run-drives-batch-flows` lands, a flow row reads `unverified` with the message "flow runner not built", and its state rows `unverified` behind it. `--at-base` runs each row at the merge base in a scratch worktree and records why it failed. It writes `.harness/runs/<runID>/qa/report.json` and 1 `qa.check` event per row; `qa.check-failed` is `RED`, `qa.check-unverified` a `nit`. `qa adopt <worktree>` copies `<worktree>/.harness/qa/<plan>/` into `<plans>/<slug>/qa/`.
- Tests: a state row after a red acceptance row reads `unverified` and never runs (catches a slow layer run over a broken boundary). A row whose task hasn't merged reads `waiting`. A `curl … | jq -e` acceptance row against a server started on `$QA_PORT` passes, and 2 runs at once get different ports (catches a fixed port). A state script's exit 1 is `red` with its output saved. A screenshot file beside a row never changes its result. `--at-base` records the failing exit status. `qa adopt` refuses a worktree outside this repository's checkouts. Each id is in the index.

### `qa-flow-lint-checks-steps-offline`
- Deps: agent-device-adapter-drives-the-pinned-cli, sample-app-declares-typed-accessibility-ids, qa-run-checks-acceptance-and-state · Gate: push · Model: opus · estLines: 440
- Writes: `D/QA/FlowSteps.swift`, `D/QA/FlowRules.swift`, `A/QA/ToolSchemaStore.swift`, `A/QA/AccessibilityIDReader.swift`, `C/Commands/QALintCommand.swift`, `C/Commands/QACommand.swift` (subcommand list), `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `A/Config/ConfigDecoding.swift` (`[qa] accessibility_ids`), `F/QA/` (flow files written for the cases, and the captured schemas they check against), `plugin/docs/standards.md` (new "Simulator QA flows" subsection), their tests
- Does: amendment §6.1. `qa lint <flow file>...` applies 5 rules, each `RED`. They are `qa.flow-unparsed`, `qa.flow-ref-target` (an `@e` ref or a coordinate target) and `qa.flow-no-assert` (no `wait` or `is` step). Then come `qa.flow-schema` (a step's input fails the schema `ToolSchemaStore` loads for the pin) and `qa.flow-unknown-id` (an `id="…"` selector that `AccessibilityIDReader` doesn't find in the configured module, read with SwiftSyntax). `qa run` calls the same rules before any flow step. With no `accessibility_ids` key, `qa.flow-ids-unknown` is a non-gating note.
- Tests: a flow with a typo'd id fails `qa.flow-unknown-id` naming it, in under 1 s (catches the typo the compiler missed). A step with a misspelt input key fails `qa.flow-schema` naming the command and key. A `get`-only flow fails `qa.flow-no-assert`. A ref target fails `qa.flow-ref-target`. The SampleApp counter flow passes all 5. A schema file whose version differs from the pin fails loading naming both. Each id is in the index.

### `qa-run-drives-batch-flows`
- Deps: qa-flow-lint-checks-steps-offline, sim-verify-judges-step-evidence, sim-down-releases-the-device-and-claims · Gate: push · Model: opus · estLines: 480
- Writes: `C/Commands/QARunCommand.swift`, `D/QA/QAFlowRecord.swift`, `A/QA/BatchFlowRunner.swift`, `A/SimQA/SimRunStore.swift` (steps from a batch), `F/AgentDevice/batch/` (captured success and failure), `F/README.md`, their tests
- Does: amendment §6, §8.2, [ADR 0008](../adrs/0008-simulator-qa-layered-validation.md) decision 1. A flow row: `qa lint`, then `sim up --scenario`, then `agent-device batch --steps-file <file> --session <s> --udid <udid> --on-error stop --json`. Each `snapshot` and `screenshot` step's output goes into `sim/steps/` as `sim snap` writes it, then `sim verify`, the row's state scripts, and `sim down`. The flow passes on batch exit 0 and `sim verify` `GREEN`. It writes 1 `qa.flow` record, `{source: batch, steps: [{n, label, offsetMs, ok}], video, sheet}`, with `video` and `sheet` absent until the final pass. `--at-base` runs flows too.
- Tests: the captured failing batch is `red`, names the failing step, and its state rows read `unverified` (catches a state check run after a failed flow). The captured passing batch with `sim verify` `GREEN` passes, and the same batch with a deleted tree is `red` through `sim.evidence-missing` (catches a flow that passes on exit status alone). A lint failure stops the row before `sim up`. Every `agent-device` call carries `--udid` and `--session`.

### `base-device-lookup-notes-duplicates`
- Deps: sim-down-releases-the-device-and-claims · Gate: push · Model: opus · estLines: 120
- Writes: `D/Simulator/SimulatorDevice.swift`, `A/SimulatorClones.swift`, their tests, `plugin/docs/standards.md` (1 "Harness and environment" row)
- Does: amendment §8.3, decision 16. When more than 1 device shares the base's name and `os`, the lookup still takes the lowest UDID and adds a non-gating `sim.base-ambiguous` note naming each UDID.
- Tests: 2 matching devices yield the lowest UDID and a note naming both (catches a silent pick). 1 match yields no note. The id is in the index.

### `brownfield-run-validates-each-merge`
- Deps: qa-run-drives-batch-flows, validation-table-imports-from-plan-md · Gate: push · Model: opus · estLines: 260
- Writes: `P/skills/run/SKILL.md`, `P/skills/run/references/plan-shape.md`, `P/skills/run/references/validation-worker.md`, `P/skills/build/references/event-loop.md` (the after-merge step), `tests/skill_commands_test.mjs` (their rows)
- Does: amendment §4.2, §5, §6, §9's brownfield row. The plan names check targets in the contract task. `PLAN.md` gains `## Validation`, and a validation task beside the first wave writes the checks under `.harness/qa/<plan>/`, runs `qa run --at-base`, and reports each failure reason. The orchestrator runs `qa adopt`, then `qa run --after <task>` after each merge, and `qa run` at `final`. It proves acceptance tests with `prove --proof-base` at `main` before their `Runs after` tasks. Flow rows run for iOS areas only.
- Tests: the contract test finds every `swiftgate qa` command and flag the skill names. The validation worker's write set holds test files and `.harness/qa/` only. The after-merge step names `--after`.

### `brownfield-ios-trial-runs-validation`
- Deps: brownfield-run-validates-each-merge · Gate: push · Model: opus · estLines: 60
- Writes: `evals/results/<date>-brownfield-ios-validation/` (report and the run's captured stores)
- Does: a one-shot `swiftgate run <spec.md>` on a public iOS app repository the orchestrator picks with no user step, tied to no practice task, with a spec holding at least 1 UI requirement and 1 stored-data requirement. It records wall time to the plan, to the first prepared check and to the end, each row's result and evidence, and every halt.
- Tests: the report shows at least 1 acceptance, 1 flow and 1 state row, each with a result from `qa run`, and no row that passed on evidence alone.

### `qa-final-pass-records-flows`
- Deps: qa-run-drives-batch-flows · Gate: push · Model: opus · estLines: 420
- Writes: `C/Commands/QARunCommand.swift` (`--final`), `A/QA/FinalPassRecorder.swift`, `A/QA/EvidenceCollector.swift`, `D/QA/RecordingRetry.swift`, `F/AgentDevice/record/` (captured `record start`, `stop`, `contact-sheet`, and the busy error), `F/README.md`, `plugin/docs/standards.md` ("Simulator QA validation" rows), their tests
- Does: amendment §7, §8.1, decisions 3, 6 and 14. `qa run --final` runs every row and wraps each flow in `record start` and `record stop` under the `sim-record` lock, then `record contact-sheet`. It fills the flow's `video` and `sheet`. On `apple_simulator_recording_busy` it retries every 15 s for up to 5 minutes, then runs without video and marks the video `unverified`. It also saves `agent-device logs`, `network dump` and `trace`, `simctl spawn … log show` for the app's subsystem, and the app's data container, under `qa/logs/`.
- Tests: with the injected clock, a busy recorder past 5 minutes runs the flow, passes the row on its assertions, and marks the video `unverified` (catches a pass that waits on video). 2 final passes take the `sim-record` slot 1 at a time. The captured contact-sheet run fills `sheet` with a run-relative path. Each id is in the index.

### `plan-skill-writes-the-validation-table`
- Deps: validation-table-imports-from-plan-md · Gate: push · Model: opus · estLines: 180
- Writes: `P/skills/plan/SKILL.md`, `P/agents/design-decomposer.md`, `tests/skill_commands_test.mjs` (its rows)
- Does: amendment §4.3's first row and decision 9. The decomposer returns validation rows beside its tasks and a validation task when 2 or more tasks build UI; the skill writes `validation.json` and runs `plan-lint`. Sprint and design-free ship stay as they are.
- Tests: the contract test finds the `validation.json` step and the plan-lint rules the skill names.

### `t3-keeps-flow-video`
- Deps: sample-app-declares-typed-accessibility-ids, qa-final-pass-records-flows · Gate: push · Model: opus · estLines: 300
- Writes: `A/XcresultReader.swift` (activities and video attachments), `A/QA/XCUITestFlowRecord.swift`, `F/Xcresult/activities/` (captured with `xcrun xcresulttool get test-results activities`), `F/README.md`, their tests
- Does: amendment §6, §7, §11.1, decision 17. After T3, each kept flow becomes 1 `qa.flow` record with `source: xcuitest`, steps and offsets from the xcresult activities, and its MP4. `agent-device record contact-sheet` fills `sheet`.
- Tests: the captured activities yield the counter flow's steps in order with offsets from the video's start (catches offsets from the wrong clock). A failing test's record marks its failing step not ok. A run with no video attachment leaves `video` absent and adds a note.

### `run-viewer-tabs-the-report`
- Deps: none · Gate: push · Model: opus · estLines: 360
- Writes: `plugin/viewer/run-viewer.html`, `plugin/viewer/run-viewer.js`, `plugin/viewer/run-viewer.css`, `tests/run_viewer_page_test.mjs`, `plugin/docs/run-viewer.md`
- Does: amendment §9.2's tabs, badges and task details. 8 tabs: Overview, Timeline, Board, Graph, Spec, Gates, Tokens, Validation (empty until the next task). Each tab label carries live counts; Gates shows retries. A board card or graph node opens a task details popover with status, column, deps, gate, commits, covers and an "Open task" action.
- Tests: every region the page drew before draws inside its tab with 0 console errors (catches a region lost in the move). Tab keys follow the ARIA tabs pattern. A RED gate shows its badge from every tab. A card click opens the popover; "Open task" opens the drawer; Escape returns focus.

### `run-viewer-shows-validation-rows`
- Deps: run-viewer-tabs-the-report, t3-keeps-flow-video, qa-final-pass-records-flows · Gate: push · Model: opus · estLines: 480
- Writes: `D/RunView/RunView.swift` (a `validation` field), `D/RunView/RunViewValidation.swift`, `D/RunView/RunViewBuilder.swift`, `A/RunView/RunViewReader.swift`, `plugin/viewer/run-view-model.js`, `plugin/viewer/run-viewer.js`, `tests/run_viewer_report_test.mjs`, `F/RunView/` (a captured run with `qa.check` and `qa.flow`), `F/README.md`, `plugin/docs/run-viewer.md`
- Does: amendment §9, §9.2, decision 10. The Validation tab has a summary strip of pass, red, unverified and waiting counts, and groups rows by task, with a shared row "waiting on <task>" under each. A flow row lists its steps with ok marks, each linked to the MP4 at its offset, and links the contact sheet. The page embeds no image or video. A red row opens "Why it failed"; an unverified row opens "Why unverified". A `qa.check` span on the timeline carries 1 tick per step. Each path passes the payload guard.
- Tests: the captured run draws every row and step with 0 console errors. The page holds no `img` or `video` element for evidence (catches an embedded thumbnail). A rejected path becomes a `damage` row. An unverified row's popover names what didn't run.

### `simulator-qa-acceptance-on-sample-app`
- Deps: every task above · Gate: ready · Model: opus · estLines: 80
- Writes: `docs/e2e-report.md` (a "Simulator QA" section), no file under `SA/`: the run's `qa/` lives under `.harness/`
- Does: attended-style; the orchestrator runs it unattended under the user's delegation. From a clean checkout of merged `main`: `doctor` is `GREEN`; `/swift-harness:qa` on `examples/SampleApp` with the counter screen as the changed flow, in the `fixed-fact` scenario; `sim verify` is `GREEN`; `sim down` leaves no device and no `agent-device` claim. Then, on the seeded branch from `sim-verify-requires-accessible-controls`, the skill's run is `RED` on both accessibility rules. Live isolation: 3 `sim up` calls from 3 worktrees with a cap of 2, where the third queues until 1 `down`. Live kill: SIGKILL the holder mid-run; the next `gc` leaves no device and no claim. Then it runs a validation table on SampleApp with 1 acceptance, 1 flow and 1 state row. `qa run --at-base` fails each for its recorded reason, `qa run` passes them, and `qa run --final` leaves an MP4 and a contact sheet that the run viewer's Validation tab links by step. A T3 run leaves the kept flow's `qa.flow` record with `source: xcuitest`. The report records wall time per command, run ids, verdicts, each finding, and the keep-flow answer (Decisions).
- Tests: every validation row ends `pass`, and the Validation tab links each flow step to its video offset. The clean run ends `GREEN` with at least 1 asserted step, the seeded run ends `RED` with both accessibility rule ids, the third `sim up` waited for a slot, and no harness device or claim survives either teardown.
