# Fast modes: implementation plan

<!-- RESUME
Status: IN PROGRESS. Wave 1 merged 2026-09-28 with speed wave 3 (push and prove GREEN; mutate RED on 2 survivors, fixed in the next wave; interfaces note docs/handoffs/subproject-5-interfaces.md). Waves 2 and 3 merged 2026-09-28 (interfaces note "Fast-modes waves 2 and 3"; mutate running). Wave 4 (`sprint-rehearsals`) ran 2026-09-28 unattended at the user's request: both runs stopped short of a GREEN `ready` on harness defects, so waves 5 and 6 fix them and the rehearsals run again. The user approved the 3 "Rehearsal fix decisions" on 2026-09-28; wave 5 builds, and wave 6 follows it.
Spec: docs/designs/2026-09-27-fast-modes-design.md (approved 2026-09-27). Decision record: [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md).
Scope: surface commits (`swiftgate surface-check`) and sprint. Design-free ship waits for sprint's rehearsals and gets its own plan tasks then.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan".
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate, with mutate once on main.
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

| Decision | Evidence | Reversal |
|---|---|---|
| `surface-check` analyses source text in `SwiftGateDomain` with SwiftSyntax; reading the commit's diff and file contents is an adapter | Gate layering; `SwiftSyntax` already runs in the domain for T0 checks | — |
| Sprint state is its own file, `sprint.json`, under the plan-state directory in the git common dir, written under the same lock as other plan state | Spec §4.2, §7 (no ledger); plan state is shared by every worktree | Fold into the ledger |
| Sprint states are a closed enum; the transition table lives in the domain and every command goes through it | Spec §4.2; worker-brief pitfall 1 | — |
| `sprint slice` and `sprint finish` read the gate run from run history by id and compare its `headCommit` to the branch HEAD | Speed wave 1 added `headCommit` to every gate run | — |
| `sprint finish` fast-forwards `main` only; it never merges or rebases | Spec §4.2: `main` only moves to a green sprint | A merge commit |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and behaviour, and
  proves at it (worker brief pitfall 10). Once `surface-check` merges, workers also run it on their surface.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a wave,
  merge every surface commit first and prove at that merge. Mutate runs once on `main` after the wave.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `TD/` `TA/` `TC/` = `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI}Tests/`,
  `P/` = `plugin/`.

### Merge points (hot files)

| File | Edited only by |
|---|---|
| `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift` | `surface-check-command`, then `sprint-commands` (different waves) |
| `plugin/docs/standards.md` rule id index | `surface-check-command`, then `sprint-commands` |
| `docs/index.md` | `sprint-skill` |
| `P/skills/sprint/SKILL.md` | `slice-gates-measure-from-the-surface`, then `sprint-skill-rehearsal-lessons` |
| `plugin/docs/standards.md` rule id index (waves 5-6) | `slice-gates-measure-from-the-surface`, then `t3-never-clones-a-booted-base` |
| `docs/designs/2026-09-27-fast-modes-design.md` | `slice-gates-measure-from-the-surface` (§4.1-4.2), then `surface-check-allows-additive-manifest-edits` (§3.2) |

### Rehearsal fix decisions

The user approved all 3 recommendations on 2026-09-28.

| Decision | Evidence | Recommendation | Needs |
|---|---|---|---|
| What T3 does when the pinned base device is booted | `simctl clone` refuses a booted source (`SimError 405`); spec §4.4 says "clones the pinned base device"; the run sheet says "keep the simulator booted"; a 2nd session or an MCP (auto-mobile) may be using the booted device | Keep cloning a shut-down base. When the base is booted, make a fresh device with `simctl create <name> <device type> <runtime>` instead of shutting down a device someone else may be using. Amend §4.4. Fix the run sheet line either way | user (spec §4.4 change) |
| Where a slice's push gate measures from | Spec §4.1 step 4 and §4.2 name no base; the skill says `--base main`, so coverage.diff counts surface stubs later slices fill (B: 34/53, 64%) | Slice push gates run `--base <surface>`; the final `ready` stays `--base main`, so every changed line since `main` is still covered once | user (spec §4.1/§4.2 change) |
| Whether `surface-check` judges `Package.swift` | A's surface added a dependency to the existing `AppFeature` manifest; `let package = Package(…)` read as `changesStoredValue`; prove already treats manifests as keep-the-change input | A manifest's added array elements (`.package(path:)`, `.product(name:package:)`, `.target`, `.testTarget`, `.library`) are allowed stubs; any other manifest change stays behaviour. Amend the §3.2 table | user (spec §3.2 change) |

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `surface-check-command`, `sprint-state-machine` | independent: a new command, and a pure state model |
| 2 | `sprint-commands`, `surface-check-accepts-stub-shapes` | needs both; the stub shapes touch only the surface scan, not `sprint-commands`' files |
| 3 | `sprint-skill` | calls every command |
| 4 | `sprint-rehearsals` | attended: the user runs it on 2 different practice prompts |
| 5 | `prove-retries-emptied-targets-at-proof-base`, `plan-state-guard-allows-sprint-pages`, `slice-gates-measure-from-the-surface` | defects the rehearsals hit; disjoint write sets; the last waits on a user decision |
| 6 | `t3-never-clones-a-booted-base`, `surface-check-allows-additive-manifest-edits`, `shim-kill-cleanup-test-holds-under-load` | disjoint write sets; the flake fix is a user request (2026-09-28) |
| 7 | `sprint-skill-rehearsal-lessons` | the skill text follows the slice-base change |

### `surface-check-command`
- Deps: none · Gate: push · Model: opus · estLines: 420
- Writes: `D/Surface/SurfaceCheck.swift`, `A/Surface/SurfaceCommitReader.swift`, `C/Commands/SurfaceCheckCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `plugin/gate/Tests/Fixtures/surface/` (captured), the fixtures README, `plugin/docs/standards.md` (rule index rows), their tests
- Does: §3.2: `swiftgate surface-check <commit> [--json]`. Over the commit's diff against its first parent, every added or changed body must be an allowed stub (§3.2 table, with §7's empty-defaults answer), including an initializer that only assigns its parameters or empty defaults, a value built by 1 initializer call from empty defaults and pass-through parameters, and bare type references or `Type.self` added to an existing array literal. Any other body, `fatalError`, `preconditionFailure`, non-empty preview data or an added test file is `surface-check.behaviour` (major) naming the file and declaration. Exit 0 GREEN, 1 RED, 2 when the reader can't load the commit. A summary note `surface-check.summary`.
- Tests: 1 captured commit per allowed body passes, and 1 per rejected shape fails naming its declaration. A stub returning non-empty sample data fails: this catches a surface holding real values. A `fatalError` stub fails. An added test file fails. A commit whose parent the reader can't load exits 2, never GREEN. Each rule id is in the standards rule index.

### `surface-check-accepts-stub-shapes`
- Deps: surface-check-command · Gate: push · Model: opus · estLines: 260
- Writes: `plugin/gate/Sources/SwiftGateRules/Surface/SurfaceBodyScan.swift`, `D/Surface/SurfaceCheck.swift`, `plugin/gate/Tests/Fixtures/surface/` (captured), the fixtures README, their tests, spec §3.2's table
- Does: §3.2, orchestrator decision 2026-09-27 within §7 (only non-empty sample data is behaviour), approved by the user 2026-09-28. `surface-check` also allows exactly 3 stub shapes real surface commits use, each as narrowly as possible: (1) a body whose only statement is `throw` of an error value: a payload-free case (`SomeError.notImplemented`, `.notImplemented`), an initializer call from empty defaults and parameters (`CancellationError()`), or an empty-payload case as in (2); (2) an enum case the parent or the same file declares, constructed with each associated value a §7 empty default or a parameter passed through (`.exited(0)`, `.loaded([])`, `.loaded(items)`), returned or yielded; (3) a parameter or a property of `self` returned unchanged (`return runsImpact`, `return value`, `return self.steps`), with no operator, call or member chain past 1 `self.` access. New stub forms `throwsError`, `emptyPayloadCase`, `returnsUnchanged`; the parent index gains enum case names. Everything else stays `surface-check.behaviour`: a `switch`, `if`/`guard`, closure calls, operators, non-empty literals, calls to non-initializers, a static function called like a case.
- Tests: 1 captured commit per shape passes as its own form, and 1 captured near miss per shape fails naming each declaration (`throw` after a statement or of `.failed("disk")` or `makeError()`; `.exited(1)`, `.loaded(items.reversed())`, `.make([])`; `return runsImpact && x`, `return self.a.b`, `a.b`). Loosening each rule turns its near-miss test red. A case the parent declares makes the check read the parent; a case the same file declares doesn't need it. `swiftgate surface-check` is run read-only on the repo's real surface commits and each verdict reported.

### `sprint-state-machine`
- Deps: none · Gate: push · Model: opus · estLines: 300
- Writes: `D/Sprint/SprintRun.swift`, `D/Sprint/SprintTransition.swift`, `A/PlanState/SprintStore.swift`, their tests
- Does: §4.2: `SprintRun` (slug, spec page path, branch, base `main` sha, surface sha, slices with status and gate run id, final gate run id) and a closed `SprintStep` enum: `started`, `surfaced`, `slicing(n)`, `finished`. `SprintTransition` accepts only start, surface, slice n in page order, finish; anything else is an error naming the step it expected. `SprintStore` reads `sprint.json` and replaces it by atomic rename under the plan-state lock, in a temp repo's git common dir in tests.
- Tests: every legal transition passes and every illegal 1 fails naming the expected step. Slice 2 before slice 1 fails. Finish before every slice fails. Round-trip is byte-stable. An unknown step fails decoding. 2 concurrent writers lose no update.

### `sprint-commands`
- Deps: surface-check-command, sprint-state-machine · Gate: push · Model: opus · estLines: 480
- Writes: `C/Commands/SprintCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `A/Build/GitWorkspace.swift` (branch create and fast-forward only), `plugin/docs/standards.md` (rule index rows), their tests
- Does: §4.1–4.2: `swiftgate sprint start <slug> --spec-page <path>` (from a GREEN `main`, creates `sprint/<slug>`), `sprint surface <sha>` (runs `surface-check`; refuses on any finding), `sprint slice <n> --gate <run id>`, `sprint finish --gate <run id>`, `sprint status [--json]`. `slice` refuses a RED, BLOCKED or push-below gate run, or 1 whose `headCommit` isn't the branch HEAD. `finish` refuses unless the run is a GREEN `ready` with prove at the surface base and `headCommit` equal to HEAD, and unless `main` is still at the recorded base; then it fast-forwards `main`. Every refusal exits 1 with `sprint.<reason>` naming what to do.
- Tests: in a temp repo with real commits, each refusal fires: stale `headCommit`, RED gate, a tier below push, a surface with behaviour, `main` moved, a `ready` run without prove Removing each check turns its test red. The happy path fast-forwards `main` to the branch. `status` names the next step after a simulated crash.

### `sprint-skill`
- Deps: sprint-commands · Gate: push · Model: opus · estLines: 260
- Writes: `P/skills/sprint/SKILL.md`, `P/skills/sprint/references/spec-page.md`, `tests/skill_commands_test.mjs` (its rows), `docs/index.md` (router row), `plugin/docs/` router if it lists skills
- Does: §4.1 and §5.2: the skill writes the spec page, skips the confirm only when every slice maps to an acceptance test the spec lists (§7), and otherwise asks once with `AskUserQuestion`. It then drives `swiftgate sprint` step by step, with the fast tier as the inner loop and push at each slice. It never advances past a refusal by hand. It stays generic: no app shape, prompt or preset value in its text.
- Tests: every `swiftgate` command and flag the skill names exists (contract test). The skill's steps match the state machine's order. The skill-reviewer or `claude plugin validate --strict` check passes.

### `sprint-rehearsals`
- Deps: sprint-skill · Gate: ready · Model: opus · estLines: 60
- Writes: `docs/e2e-report.md`
- Does: attended. The user runs `/swift-harness:sprint` on 2 different practice prompts in a warm starter repo, timed with the run history. The report records wall time per step, every refusal and whether the final gate was GREEN.
- Tests: both runs end with `main` fast-forwarded and a GREEN `ready` gate, with no manual step except the spec-page confirm.

### `prove-retries-emptied-targets-at-proof-base`
- Deps: none · Gate: push · Model: opus · estLines: 220
- Writes: `C/ChangedTestChecks.swift`, `D/Testing/ChangedTestRules.swift`, `TC/ChangedTestChecksTests.swift`, `TD/ChangedTestRulesTests.swift`, `plugin/gate/Tests/Fixtures/` (1 captured `swift test` run of a package whose target is empty) and the fixtures README
- Does: fast modes §3.3. Today `proveUntimed` reverts to the merge base first and retries at each `--proof-base` only the tests `ProofRules.compileOnly` names. A package added since the merge base loses every source file there, so SwiftPM refuses the manifest ("target 'X' referenced in product 'X' is empty"), `judgeReverted` returns `.noEvidence` (BLOCKED), and the proof base, where the surface's stubs exist, is never tried. Fix: (1) a reverted run that is `.noEvidence` is retried at the next proof base, like compile-only; (2) `ProofRules.combine` takes each test's verdict and blocked flag from the last attempt that ran it, so a later proof drops the earlier package-level finding (today it has no line, so `isAbout` never matches it, and `blocked` is any attempt's); (3) with no proof base left, an emptied-target manifest error is `prove.compile-only` with the existing "commit the API first … pass that commit as --proof-base" message, not BLOCKED: its remedy is a code change.
- Tests: in a temp repo, a new package whose sources exist only from a surface commit: with `--proof-base <surface>` each new test is proven there and the judgement is GREEN (catches retrying only compile-only tests). The same without `--proof-base` is RED `prove.compile-only`, never BLOCKED (catches an emptied target read as environment). `combine` with a blocked merge-base attempt and a proving proof-base attempt is GREEN with no finding (catches a stale blocked flag). A real environment failure at every base stays BLOCKED. Remove the retry and confirm the first test goes red.

### `plan-state-guard-allows-sprint-pages`
- Deps: none · Gate: push · Model: opus · estLines: 160
- Writes: `D/Hooks/Guards.swift`, `D/Plan/PlanStateLayout.swift` (reserve the name only), `TD/Hooks/PlanStateGuardTests.swift`, `TC/` PreToolUse hook tests for the Write and Bash paths
- Does: fast modes §5.2 puts the spec page in plan state, and the sprint skill writes `<plans>/sprints/<slug>.md` before `sprint start`. `PlanStateGuard.planStateTarget` reads `sprints` as a plan directory, so the write needs a lock no sprint holds and B's main session was denied (`guard.plan-state`) for both Write and Bash. A's identical write passed only because it spelled the path as `"$P/…"`, which `ShellSyntax.writeTargets` documents as unreadable: not session-dependent. Fix: a new target `sprintPage` for a `.md` file directly under `<plans>/sprints/`, writable by any main session (`agentID == nil`) and never by a subagent; anything else under `sprints/` stays `malformedPlanPath`. `PlanStateLayout.plan("sprints")` throws, so no plan can take the name.
- Tests: a main session's Write and Bash writes to `<plans>/sprints/<slug>.md` are allowed (catches the over-match). A subagent's are denied. `<plans>/sprints/x/y.md`, `<plans>/sprints/x.json` and `plan claim sprints` are refused. A plan file under a real plan still needs its lock. Remove the new case and confirm the first test goes red.

### `slice-gates-measure-from-the-surface`
- Deps: none · Gate: push · Model: opus · estLines: 240 · Decision: "where a slice's push gate measures from", approved 2026-09-28
- Writes: `C/Commands/SprintCommand.swift`, `D/RunHistory.swift`, `C/GateRun.swift` (the history line only), `C/Commands/CheckCommand.swift` (passing the resolved base only), `TC/SprintCommandTests.swift`, `TA/RunStoreTests.swift`, `P/skills/sprint/SKILL.md` (§5 step 4 and the `sprint.gate-base` refusal row), `tests/skill_commands_test.mjs` (its rows), `plugin/docs/standards.md` (rule index row), spec §4.1 step 4 and the §4.2 table
- Does: a slice's push gate runs `check --tier push --base <surface>`, so `coverage.diff` counts only lines changed since the surface: a surface stub a later slice fills no longer fails slice 1 (B: 64% of 53 lines, 90% required; A added tests early to clear it). Each history line records `base`, the resolved sha `--base` named (`String?`, `nil` for older lines). `sprint slice` refuses a run whose `base` isn't the sprint's surface with `sprint.gate-base`, naming the command to run. `finish` is unchanged (`--base main`), so the whole sprint's diff is still covered once.
- Tests: in a temp repo, `sprint slice` with a push run at `--base main` is refused `sprint.gate-base`; at `--base <surface>` it passes (catches a slice gate measured against the wrong base). A history line without `base` decodes as `nil` and is refused, never accepted. The coverage of a surface stub a later slice fills doesn't count in slice 1's run. Remove the base check and confirm the refusal test goes red.

### `t3-never-clones-a-booted-base`
- Deps: none · Gate: push · Model: opus · estLines: 260 · Decision: "what T3 does when the pinned base device is booted", approved 2026-09-28
- Writes: `A/SimulatorClones.swift`, `A/Simctl.swift`, `D/Simulator/SimulatorDevice.swift`, `D/Simulator/` selection file, `C/SimulatorTestCheck.swift` (the not-run message only), `plugin/gate/Sources/SwiftGateTestSupport/FakeSimulator.swift`, `TA/SimulatorClonesTests.swift`, `TD/SimulatorSelectionTests.swift`, `plugin/gate/Tests/Fixtures/Simctl/` (captured `create`, and `clone` of a booted device), the fixtures README, spec §4.4, `plugin/docs/standards.md` if a rule id is added
- Does: `SimulatorClones.makeClone` clones `SimulatorSelection.baseDevice`, which ignores `state`; CoreSimulator refuses to clone a booted device, so a booted pinned device makes every T3 BLOCKED in 229 ms. With the recommended decision: `parseDevices` keeps `deviceTypeIdentifier`; a base whose state is `Shutdown` is cloned as today; a booted one is never shut down by the harness; the clone is made with `simctl create <harness clone name> <device type> <runtime>` instead, under the same lock, name and sweep. `SimulatorTestCheck.run` stops prefixing a not-run reason with "the result bundle could not be read". Verdict note: BLOCKED with a `minor` finding is correct: `Verdict` is separate from severity, and `SimulatorJudgement.block` sets BLOCKED for a machine problem.
- Tests: a fake `simctl` that refuses to clone a booted device, as the captured stderr shows (catches the fake that let this ship: `FakeSimulator` accepted any clone). With the base booted, `withClone` hands `body` a created device and never calls `shutdown` on the base. With it shut down, it clones. The created device is swept like a clone when its owner dies. The not-run finding names the simctl failure without mentioning a result bundle. A simctl call that times out under load gets a longer, configurable deadline, with a test that a slow fake simctl finishes inside it (rehearsal B's first ready run `20260928T132227Z-1590fe9a` was BLOCKED on a 60 s simctl timeout at load 60).

### `surface-check-allows-additive-manifest-edits`
- Deps: none · Gate: push · Model: opus · estLines: 200 · Decision: "whether surface-check judges Package.swift", approved 2026-09-28
- Writes: `plugin/gate/Sources/SwiftGateRules/Surface/SurfaceBodyScan.swift`, `D/Surface/SurfaceCheck.swift`, `plugin/gate/Tests/Fixtures/surface/` (captured), the fixtures README, `plugin/gate/Tests/SwiftGateRulesTests/SurfaceBodyScanTests.swift`, `TC/SurfaceCheckCommandTests.swift`, spec §3.2's table
- Does: A's surface linked a new package into the existing `AppFeature` manifest, and `SurfaceBodyScan` judged the whole `let package = Package(…)` as `changesStoredValue`. The session added a same-line `swiftgate:allow` (ignored: surface findings aren't waivable, which stays), then moved the feature into a new package, which cost a cold build and set up the prove failure above. In a `Package.swift`, an existing array literal that gains only `.package(path:)`, `.package(url:…)`, `.product(name:package:)`, a target or product declaration, or a string target name is a new stub form `extendsManifest`; removing or changing an existing element, or any other change, stays `surface-check.behaviour`.
- Tests: a captured surface that adds a local package dependency and a target to an existing manifest passes (catches the rehearsal refusal). Near misses fail naming `package`: a removed dependency, a changed `swiftSettings`, a changed platform. A new manifest is still allowed as before.

### `sprint-skill-rehearsal-lessons`
- Deps: slice-gates-measure-from-the-surface · Gate: push · Model: opus · estLines: 60
- Writes: `P/skills/sprint/SKILL.md`, `tests/skill_commands_test.mjs` (its rows)
- Does: skill-text gaps the rehearsals hit, each 1 line: `<spec-file>` is any readable file path, inside or outside the repository (the run sheet keeps it outside so preflight sees a clean tree); a new `@Dependency` client's `DependencyValues` accessor stubs as `get { .init() }` / `set {}` in the surface and becomes `self[Key.self]` in the slice that tests it; `surface-check` findings take no `swiftgate:allow`: turn the body back into a stub; the `ready` gate runs in the foreground, waiting on its report file in chunks past a tool timeout, never in the background (a headless session that ends its turn kills a background gate, as rehearsal B's did).
- Not in this task: the 417 s and 499 s `check --tier fast` T1 runs (A, `20260928T122638Z-c69b63e7`, `20260928T123402Z-e8b94f8d`). Their `swift test` logs show builds of 4.75 s and 18.5 s, so a cold build doesn't explain them. Capture a timed trace (per-step wall clock, SwiftPM stderr for `.build` lock waits) on the next rehearsal before drafting a fix.
- Tests: the skill contract test passes; every command and flag it names exists; the page stays generic (no app shape or prompt text).

### `shim-kill-cleanup-test-holds-under-load`
- Deps: none · Gate: push · Model: opus · estLines: 80
- Writes: `tests/shim_kill_cleanup_test.mjs`, and `plugin/bin/swiftgate` only if the root cause is in the shim (then `tests/shim_test.sh` too)
- Does: the test "a shim test killed outright leaves no process under its temp directory" fails in full push runs at load 40 or more and passes alone ("the shim test ran no shim within 20s"; main runs `20260928T121418Z-3d3de7e5`, and 2 runs on the prove-retry branch). Find why the shim doesn't start within 20 s under load: a fixed wall-clock deadline racing a cold start, or a real shim defect. Replace the fixed deadline with waiting on the real artifact (the shim's process or marker file), bounded by a deadline long enough for a cold shim under load and reported by name when it's exceeded. If the shim itself is slow to spawn, fix the shim instead.
- Tests: the test passes 10 times in a row under generated load (`timeout`-bounded busy loops on every core, cleaned up by their own deadline), and a shim that never starts still fails with the named deadline, never hangs. Revert the fix and confirm the loaded run goes red.
