# Simulator QA: implementation plan

<!-- RESUME
Status: NOT STARTED.
Spec: docs/designs/2026-09-28-simulator-qa-design.md (approved 2026-09-28). Decision record: [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md).
Scope: sub-project 3. `swiftgate sim up · snap · verify · down` and its holder process, the `agent-device` adapter and pin, dependency scenarios and `sim.scenario-drift`, the 7 `sim verify` rules, `/swift-harness:qa`, its callers, and an acceptance run on `examples/SampleApp`. Profiling (sub-project 4) is out of scope.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan". Interfaces note: docs/handoffs/subproject-3-interfaces.md (the first wave's merge creates it; each wave appends).
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate, with mutate once on main per wave or per 2 waves.
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

The design leaves each of these open. None changes an approved choice in §11. The 2 marked "user" are cheap to
reverse, and the orchestrator may go ahead with the recommendation, since the user delegated approvals for
2026-09-28, but it should say so in the wave's merge note.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| The pinned version | `npm view agent-device version` is 0.21.16 on 2026-09-28; the survey found 0.21.15; `agent-device` isn't installed on this Mac | Pin 0.21.16. `agent-device-adapter-drives-the-pinned-cli` installs it with `npm i -g agent-device@0.21.16` and records the line in the fixtures README | — |
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
| `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift` | `sim-hold-keeps-a-simulator-slot` (registers the `sim` group) |
| `C/Commands/SimCommand.swift` (subcommand list) | `sim-hold-keeps-a-simulator-slot`, then `sim-up-launches-the-app-in-a-scenario`, then `sim-snap-records-a-step`, then `sim-verify-judges-step-evidence`, then `sim-down-releases-the-device-and-claims` (1 per wave) |
| `plugin/docs/standards.md` rule id index | at most 1 task per wave per subsection: "Harness and environment" (`doctor-checks-the-agent-device-pin`), "Code rules" (`arch-checks-scenario-drift`), a new "Simulator QA commands (`sim up`, `snap`, `down`)" (`sim-up-launches-the-app-in-a-scenario`, then `sim-snap-records-a-step`), a new "Simulator QA evidence (`sim verify`)" (`sim-verify-judges-step-evidence`, then `sim-verify-requires-accessible-controls`, then `sim-verify-reports-app-exits`) |
| `plugin/docs/standards.md` §7 (Accessibility) | `sim-verify-requires-accessible-controls` |
| `F/README.md` | `agent-device-adapter-drives-the-pinned-cli`, then `sim-verify-requires-accessible-controls`, then `sim-verify-reports-app-exits` (different waves) |
| `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `A/Config/ConfigDecoding.swift` | `config-declares-scenarios-qa-and-sim-qa`. Fast-modes' `presets-may-skip-design` edits `BuildPreset`: whichever merges second rebases |
| `P/templates/swiftgate.toml` | `config-declares-scenarios-qa-and-sim-qa`, then `bootstrap-stamps-a-live-scenario` |
| `SA/.swiftgate.toml` | `arch-checks-scenario-drift` |
| `C/Commands/GCCommand.swift`, `A/SimulatorClones.swift` | `sim-down-releases-the-device-and-claims` (`sim-hold-keeps-a-simulator-slot` only calls `SimulatorClones`) |
| `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/validate/SKILL.md`, `P/skills/sprint/SKILL.md`, `P/skills/ship/SKILL.md` | `callers-run-simulator-qa`. Sub-project 4's plan also targets the `validate` stage: whichever merges second rebases |
| `docs/index.md`, `tests/skill_commands_test.mjs` | `qa-skill-drives-flows-to-a-verdict`, then `callers-run-simulator-qa` |

### Risks

- **Live simulators under load.** Capture and acceptance tasks boot devices on a machine that also runs T2/T3 gates.
  They share the `sim` cap, so they queue rather than fail; a task that waits past its lock timeout reports `BLOCKED`
  with the holders' PIDs, not a flake.
- **`agent-device` output drift.** The adapter parses a third-party CLI. The pin plus the fixtures-equal-pin test
  make an unplanned upgrade fail loudly; a planned one is a recapture task.
- **Skill routing.** A new skill can move routing in the evals session's sets. Tell that session before
  `qa-skill-drives-flows-to-a-verdict` merges.
- **Standards index churn.** 6 tasks add rows. The subsection split keeps each wave to non-adjacent hunks.

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `agent-device-adapter-drives-the-pinned-cli`, `config-declares-scenarios-qa-and-sim-qa`, `sample-app-selects-a-scenario-by-launch-argument` | independent foundations: the driver and its fixtures, config, and the example app's scenario |
| 2 | `sim-tree-reads-agent-device-snapshots`, `sim-hold-keeps-a-simulator-slot`, `doctor-checks-the-agent-device-pin` | the tree parser and doctor need the captured fixtures; the holder needs `[qa]` config |
| 3 | `sim-up-launches-the-app-in-a-scenario`, `arch-checks-scenario-drift`, `bootstrap-stamps-a-live-scenario` | `sim up` needs the holder, adapter and scenario; drift lands with SampleApp's config entry, its first passing input |
| 4 | `sim-snap-records-a-step` | needs a session from `sim up` |
| 5 | `sim-verify-judges-step-evidence` | judges what `sim snap` writes |
| 6 | `sim-verify-requires-accessible-controls`, `sim-down-releases-the-device-and-claims` | disjoint: a verify rule, and the teardown command |
| 7 | `sim-verify-reports-app-exits`, `qa-skill-drives-flows-to-a-verdict` | the exit rule edits `snap` and `down`; the skill names every command, now all present |
| 8 | `callers-run-simulator-qa` | calls the skill |
| 9 | `simulator-qa-acceptance-on-sample-app` | attended-style; the orchestrator runs it unattended |

### `agent-device-adapter-drives-the-pinned-cli`
- Deps: none · Gate: push · Model: opus · estLines: 420
- Writes: `A/AgentDevice/AgentDevice.swift` (protocol, live adapter), `A/AgentDevice/AgentDevicePin.swift`, `A/AgentDevice/AgentDeviceError.swift`, `S/FakeAgentDevice.swift`, `TA/AgentDeviceTests.swift`, `F/AgentDevice/` (captured), `F/README.md`
- Does: §4 layering. Installs `agent-device@0.21.16` globally (`npm i -g agent-device@0.21.16`) and records the line in the fixtures README. Capture session (survey §5 part A) against `SA/` on a harness-created device: `agent-device --version`; `open com.example.SampleApp --udid <udid> --session <name> --launch-args -harness-scenario --launch-args live --json`; `snapshot --json`; `screenshot <path> --json`; `appstate --json`; `session list --json`; a typed failure from `wait text "<absent text>" 2000 --json`; an `open` refused with `DEVICE_IN_USE` and one for an unknown UDID; `device release --stale --json`; `close --json`. It records whether any macOS permission prompt appeared, and the iOS role vocabulary the installed package can emit, with the file it read. The `AgentDevice` protocol wraps these calls through `ProcessRunner`, always passing `--udid` and `--session`; `snapshotJSON` returns the raw bytes unmodified; a `--json` error decodes to `AgentDeviceError` with its typed code as a closed enum of the codes captured, plus the raw message. `AgentDevicePin.version` is `"0.21.16"`.
- Tests: the captured `--version` output equals `AgentDevicePin.version` (catches a recapture that forgets the pin). Each captured error decodes to its code and an unknown code fails decoding naming itself. Every call carries `--udid` and `--session` (catches a call that lets `agent-device` pick a device). `snapshotJSON` hands back the fixture's bytes unchanged (catches a parser rewriting evidence). A non-zero exit with unparseable stderr is an error naming the command, never an empty success.

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
- Deps: sim-down-releases-the-device-and-claims, sim-verify-judges-step-evidence · Gate: push · Model: opus · estLines: 220
- Writes: `P/skills/qa/SKILL.md`, `tests/skill_commands_test.mjs` (its rows), `docs/index.md` (router row)
- Does: §8.1 and §8.3. Picks flows from the changed feature modules' screens and any flow the spec page or plan task names. Per flow: `sim up --scenario`, an inspect, act, verify loop through `agent-device` (MCP or CLI, always with the run's `--udid` and `--session`), `sim snap` at every checked point, then `sim verify` and `sim down`. `RED` hands off to `/swift-harness:tdd`; `BLOCKED` runs `doctor`. It proposes flows to keep and asks with `AskUserQuestion`; a kept flow is written test-first with `/swift-harness:tdd` as an XCUITest plus a `[[flows]]` entry, and at `max_flows` it asks which to drop. It never keeps a flow unasked and never states a verdict `sim verify` didn't print. It stays generic.
- Tests: every `swiftgate` command and flag the skill names exists (contract test). `claude plugin validate --strict` passes. The skill's step order matches `up`, `snap`, `verify`, `down`.

### `callers-run-simulator-qa`
- Deps: qa-skill-drives-flows-to-a-verdict, config-declares-scenarios-qa-and-sim-qa · Gate: push · Model: opus · estLines: 200
- Writes: `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/sprint/SKILL.md`, `P/skills/ship/SKILL.md`, `P/skills/validate/SKILL.md`, `tests/skill_commands_test.mjs` (their rows), `tests/preset_profile_skills_test.mjs` if it pins these steps
- Does: §8.2. The build's `validate` stage, after the final `ready` gate on merged `main`, runs `/swift-harness:qa` when the preset's `sim_qa = "changed"` and prints `validate: sim_qa off` otherwise; sprint does the same after `sprint finish`, and ship after its final gate. `/swift-validate` adds a "Simulator QA" row with the verify run's id, verdict and step count, and lists a skipped QA under "Not run".
- Tests: the contract test finds each caller naming `/swift-harness:qa` and the `sim_qa` key, and no caller still prints `validate: not configured`. The validate block's "Simulator QA" row reads its values from `report.json` keys that `sim verify` writes.

### `simulator-qa-acceptance-on-sample-app`
- Deps: every task above · Gate: ready · Model: opus · estLines: 80
- Writes: `docs/e2e-report.md` (a "Simulator QA" section)
- Does: attended-style; the orchestrator runs it unattended under the user's delegation. From a clean checkout of merged `main`: `doctor` is `GREEN`; `/swift-harness:qa` on `examples/SampleApp` with the counter screen as the changed flow, in the `fixed-fact` scenario; `sim verify` is `GREEN`; `sim down` leaves no device and no `agent-device` claim. Then, on the seeded branch from `sim-verify-requires-accessible-controls`, the skill's run is `RED` on both accessibility rules. Live isolation: 3 `sim up` calls from 3 worktrees with a cap of 2, where the third queues until 1 `down`. Live kill: SIGKILL the holder mid-run; the next `gc` leaves no device and no claim. The report records wall time per command, run ids, verdicts, each finding, and the keep-flow answer (Decisions).
- Tests: the clean run ends `GREEN` with at least 1 asserted step, the seeded run ends `RED` with both accessibility rule ids, the third `sim up` waited for a slot, and no harness device or claim survives either teardown.
