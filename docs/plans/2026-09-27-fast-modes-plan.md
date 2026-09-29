# Fast modes: implementation plan

<!-- RESUME
Status: IN PROGRESS. Wave 1 merged 2026-09-28 with speed wave 3 (push and prove GREEN; mutate RED on 2 survivors, fixed in the next wave; interfaces note docs/handoffs/subproject-5-interfaces.md). Waves 2 and 3 merged 2026-09-28 (interfaces note "Fast-modes waves 2 and 3"; mutate running). Wave 4 (`sprint-rehearsals`) ran 2026-09-28 unattended at the user's request: both runs stopped short of a GREEN `ready` on harness defects, so waves 5 and 6 fix them and the rehearsals run again. The user approved the 3 "Rehearsal fix decisions" on 2026-09-28. Waves 5-8 merged 2026-09-28 (interfaces note "Fast-modes wave 5", "Fast-modes waves 6 and 7"). Wave 8 is building. Then one mutate covering waves 5-8, then both rehearsals re-run from their warm starting commits (user decision), then `docs/e2e-report.md`. Design-free ship: waves 9 and 10 merged 2026-09-28 (interfaces notes "Fast-modes wave 9" and "Fast-modes wave 10"; wave 9 survivors killed in `bd27a93`). Wave 11 merged 2026-09-28 (interfaces note "Fast-modes wave 11"). `shim-deadline-test-holds-under-load` was pulled forward into wave 11 because its flake blocks mutate; it merges on its own, then 1 mutate covers waves 10-11. The shim deadline fix merged 2026-09-28; mutate for waves 10-11 is RED on 2 survivors, in a fix round. Wave 12 merged 2026-09-29 (interfaces note "Fast-modes wave 12"). Waves 10-11 survivors killed in `90f85ab`. Wave 13 merged 2026-09-29 (interfaces note "Fast-modes wave 13"). Rehearsal A stopped at the surface gate (see "Design-free ship rehearsal fix decisions"); `surface-lands-on-a-fast-gate` fixed it (merged). Attempt 2 then stopped at the build's green-main check; `build-gates-measure-from-the-plan-surface` fixes that, then both rehearsals run from fresh warm clones. Wave 14 (`design-free-ship-rehearsals`) runs headless from `../ship-rehearsal-RUNSHEET.md`, orchestrator-answered under the user's 2026-09-28 delegation; D3 stays with the user. Then 1 mutate covers waves 12-13. Follow-up: `SpecPageWriteSet.resolve` returns modules unsorted, against its doc.
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

The user approved all 3 recommendations on 2026-09-28. Later that day, after rehearsal A's `ready` gate went RED on 11 `prove.compile-only` findings (slice 4 added the `…Live` target of a package new since `main`, with no stub in the surface), the user chose to refuse such a slice at `sprint slice`, and to re-run both rehearsals from their warm starting commits once waves 6-8 merge.

| Decision | Evidence | Recommendation | Needs |
|---|---|---|---|
| What T3 does when the pinned base device is booted | `simctl clone` refuses a booted source (`SimError 405`); spec §4.4 says "clones the pinned base device"; the run sheet says "keep the simulator booted"; a 2nd session or an MCP (auto-mobile) may be using the booted device | Keep cloning a shut-down base. When the base is booted, make a fresh device with `simctl create <name> <device type> <runtime>` instead of shutting down a device someone else may be using. Amend §4.4. Fix the run sheet line either way | user (spec §4.4 change) |
| Where a slice's push gate measures from | Spec §4.1 step 4 and §4.2 name no base; the skill says `--base main`, so coverage.diff counts surface stubs later slices fill (B: 34/53, 64%) | Slice push gates run `--base <surface>`; the final `ready` stays `--base main`, so every changed line since `main` is still covered once | user (spec §4.1/§4.2 change) |
| Whether `surface-check` judges `Package.swift` | A's surface added a dependency to the existing `AppFeature` manifest; `let package = Package(…)` read as `changesStoredValue`; prove already treats manifests as keep-the-change input | A manifest's added array elements (`.package(path:)`, `.product(name:package:)`, `.target`, `.testTarget`, `.library`) are allowed stubs; any other manifest change stays behaviour. Amend the §3.2 table | user (spec §3.2 change) |

### Design-free ship: what exists, and what §5 needs that doesn't

The sprint rehearsals are done: attempt 2 (harness `7b6d49f`) passed both runs (`docs/e2e-report.md`),
so §1's "design-free ship waits for sprint's rehearsal results" is met.

| §5 needs | Today | Gap |
|---|---|---|
| `design_tier = "none"` in a preset | `DesignTier` = `quick`/`standard`/`deep`/`sketch`, shared by config, `plan claim --tier`, `plan set --tier`, the design skill and docs-lint front matter | a value only a preset can hold |
| Spec page (§5.2) | sprint's format in `P/skills/sprint/references/spec-page.md`; the skill judges "every slice quotes the spec" in prose | no parser, no mechanical confirm-skip check |
| A plan with no design | `PlanFile.design` is required; `plan claim` needs `--design`; `plan-lint` exits 2 without `designSha`; `context-pack --role decomposer/worker` need `--design`; `design-render --ledger` reads the design at `designSha`; the decomposer prompt speaks `req-…`/`test-…` ids | a second plan source everywhere the design is read |
| Surface "on `main`" | sprint commits its surface on `sprint/<slug>`; `SprintCommand` has a fast-forward helper; `surface-check` exists | no command that lands a surface on `main` and records it for a plan |
| `surfaceCommit` "set to the 1 surface" per ledger task | `surfaceCommit` lives on `TaskReturn` (per worker, must be an ancestor of the task branch); ledger tasks have no such field; `build proof-bases` lists each merged return's surface | a plan-level surface the proof bases and workers use |
| Workers build on 1 surface | `build-task.js` tells each worker to write its own surface commit when it adds API | a worker told not to, and what it does when API is missing |
| New target outside the surface | `sprint.target-outside-surface` (`D/Sprint/SliceManifests.swift`, `SwiftGateRules/Surface/ManifestDeclarationsReader.swift`) | the same refusal at `build check-return` |

### Design-free ship decisions

The user approved every recommendation below on 2026-09-28 (D0: build it; the attended rehearsal wave is the go/no-go).

§5 and [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md) are silent or ambiguous on each of these. Tasks that wait are named.

| # | Question | Evidence | Recommendation | Waits |
|---|---|---|---|---|
| D0 | Build design-free ship now, or measure first? | Sprint attempt 2: 12 min 28 s (B) and 31 min 45 s (A, 23 min of it `ready` re-runs). Design-free ship adds worktrees, workers and merge gates (a push gate per merge, 19 s warm to 79 s cold) to buy parallel slices. Nothing measures whether parallel slices beat 1 model's pace for a 4-slice spec | Build it: the ADR is accepted, and only a rehearsal can answer the speed question. Keep `design-free-ship-rehearsals` as the go/no-go, timed against sprint on the same prompts | all |
| D1 | Is `none` a `DesignTier` case? | §9 says `design_tier` "adds `none`". `DesignTier` also feeds `plan claim --tier`, `plan set --tier`, `/swift-harness:design --tier` and docs-lint's front-matter tier; `design-scope` returns only quick/standard/deep | No. A preset-only type (`BuildPreset.DesignStep`: `.design(DesignTier)` or `.none`) parses `design_tier = "none"`, so `design --tier none`, a design doc with `tier: none` and `design-scope` can't produce it by construction. §9's key-level wording still holds | `presets-may-skip-design` |
| D2 | What is [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md)'s "explicit flag"? | ADR: "Only a preset or an explicit flag selects it"; ship takes only `--preset` | `--preset <name>` naming a `none` preset is the flag. No `ship --no-design`: 1 way in, and the profile default comes free | `ship-runs-without-design` |
| D3 | Which template preset, if any, gets `none`? | Template: `default` = `standard`, `interview` = `sketch` | No template change in this plan. Rehearsals use a repo-local preset. After they pass, the user picks: flip `interview` to `none`, or add a generic preset | follow-up after `design-free-ship-rehearsals` |
| D4 | Where does ship's spec page live, and what names the plan? | §5.2: "in plan state". Sprint pages are `<plans>/sprints/<slug>.md` (any main session, no lock). A plan's own directory is writable only by its lock holder (`PlanStateGuard.Target.planFile`) | `<plans>/<slug>/spec-page.md`, under the plan's lock, so no guard change. `plan.json` gets a closed `source`: `design(…)` or `specPage(path)`; a schema-1 file with `design` still decodes as a design plan | `plan-state-records-a-spec-page-source` |
| D5 | Is "every slice maps to an acceptance test the spec lists" checked by `swiftgate` or by the skill? | Sprint judges it in prose from each slice's `Spec: "<quote>"` / `none`; brief rule "never re-implement a check" | `swiftgate spec-page check` decides: every `Spec:` quote must appear verbatim in the spec file; it prints `confirm: required|skippable`. Sprint keeps its prose for now; adopting the command in sprint is a separate follow-up | `spec-page-check`, `spec-page-confirmation-binds-the-page` |
| D6 | What does the confirm bind to? | The page is in plan state, never committed, so it can change after the confirm with no trace. A design's approval binds `designSha` and `plan-lint.design-moved` catches a later edit | `plan confirm` records `{pageSha, by: user|spec-quotes, at}`; `by: spec-quotes` is refused unless the check says skippable. `plan-lint.spec-page-moved` fails a page whose sha differs | `spec-page-confirmation-binds-the-page`, `plan-lint-covers-spec-page-tests` |
| D7 | What ids and tiers does `plan-lint` coverage read from a spec page? | Coverage uses `req-…`/`test-…` ids and each test's tier (T0-T3) for the minimum task gate. The page has test names and no tier | Each slice is 1 coverage item, id `slice-<n>-<kebab test name>`; its tier is T1 unless the slice line adds an optional `Tier: T2` or `Tier: T3` (backward compatible with sprint pages). The final `ready` gate still runs T3 | `spec-page-check`, `plan-lint-covers-spec-page-tests`, `context-packs-read-spec-pages` |
| D8 | Who writes the surface, and how does it reach `main`? | §5.1 step 2: "the surface commit and `surface-check` on `main`". §6: every merge into `main` passes the merge gate GREEN. A surface committed straight onto `main` that then fails leaves `main` dirty | The main session writes it on `surface/<slug>` from `main`, runs the preset's merge gate there, then `swiftgate plan surface <slug> <sha> --gate <run id>` runs `surface-check`, checks the gate's `headCommit`, fast-forwards `main` and records the sha | `ship-surface-lands-on-main`, `ship-runs-without-design` |
| D9 | Where does "the 1 surface" live? | §5.1 step 3 says each ledger task has `surfaceCommit`; §3.3 says it "already exists per task", but it exists on `TaskReturn`, not on ledger tasks | Once, in `plan.json` (`surfaceCommit`). Ledger tasks stay as they are, so no copy can disagree. `build proof-bases` puts it first and drops duplicates | `plan-state-records-a-spec-page-source`, `build-proof-bases-start-at-the-plan-surface`, `workers-build-on-the-plan-surface` |
| D10 | "Each with a write set disjoint from the others": all tasks, or within a wave? | Sprint pages order slices so each builds on the ones before it; `plan-schedule` already splits overlapping write sets into waves | Within a wave, as `plan-schedule` does today; deps between slices stay allowed. No new lint rule | `plan-lint-covers-spec-page-tests`, `ship-runs-without-design` |
| D11 | What does a worker do when its test needs API the surface lacks? | Sprint (§3.3, user-approved 2026-09-28): an extra stub commit that passes `surface-check`, proved oldest first. Rehearsal A attempt 2 needed 2 stub-and-restore pairs for a renamed API | The same: the worker commits the missing API alone as a stub, reports it as its return's `surfaceCommit`, and the final gate proves at the plan surface, then each task's stub in merge order. A new target or product is refused at `check-return` (`build-return.target-outside-surface`) | `workers-build-on-the-plan-surface`, `check-return-refuses-targets-the-plan-surface-lacks` |
| D12 | What is a design conflict when there is no design? | `on_design_conflict = "amend"` runs `/swift-harness:design --amend`, which needs a design doc | A preset with `design_tier = "none"` must set `on_design_conflict = "block"`; any other value fails config loading, naming both keys. A worker's conflict cites a spec page section (`slices`, `surface`, `modules`) | `presets-may-skip-design`, `workers-build-on-the-plan-surface` |
| D13 | Surface before or after decomposition? | §5.1 orders page, surface, plan | Keep §5.1's order: the decomposer reads the surface's files and may put stub files in task write sets (a task fills the stubs it owns) | `ship-runs-without-design` |

Spec corrections the recommendations imply: §5.1 step 3 (surface recorded on the plan, not per ledger
task), §5.2 (page path, optional `Tier:`), §3.3 (worker stub commits in a build). They go in
`ship-runs-without-design`'s write set.

### Design-free ship rehearsal fix decisions

Rehearsal A (2026-09-29) stopped at the surface: the preset's `push` merge gate was RED on 3
`impact.untested-change` findings, because a surface commit adds modules and may add no test. No push-tier gate
can pass on a surface that adds a module. The orchestrator decided the fix under the user's delegation of
2026-09-28; the user can reverse it.

| Decision | Evidence | Choice | Reversal |
|---|---|---|---|
| D8 amended: how is the surface gated before it lands? | Rehearsal A, gate run `20260929T013554Z-2de37cc3`: push-tier `impact.untested-change` for every new module; push-tier coverage also counts stub lines as uncovered. Sprint gates its surface at `fast` plus `surface-check` and has passed 2 rehearsals that way | The surface lands on a GREEN `fast` gate at the surface commit plus a GREEN `surface-check`, as sprint's does; `plan surface` requires `fast` or above, not the preset's `merge_gate`. The build's task merges and final gate still run at the preset's tiers, so `main`'s next move after the surface is judged at full strength | Gate the surface at the merge gate, with impact and coverage skipping a commit `surface-check` judges all-stub |
| The build's gates after the surface lands | Rehearsal A attempt 2: with the surface on `main`, the build's green-main `check --tier push` (no `--base`, so from `origin/main`) was RED (run `20260929T021519Z-5f7ee3e6`) on the same 3 `impact.untested-change` findings, and an interface module no task tests would keep the final `ready` gate RED. Sprint's slice gates run `--base <surface>` | For a plan with a `surfaceCommit`, the build's green-main check, its merge gates on `main` and its final `ready` gate run with `--base <surfaceCommit>`: they judge what the tasks changed on top of the surface. Workers' task gates keep `--base main`. A plan without a surface is unchanged | Judge from `origin/main`, with impact skipping lines `surface-check` judges stubs |
| A surface's new `@Dependency` accessor | Rehearsal A attempt 3: the surface stubbed `DependencyValues.shoppingListClient` as `get { .init() } set {}` (sprint's rule, where the next slice wires it). In a parallel build the accessor's file belonged to the client task, which had no test needing it, so the reducer task could never inject a test client: a design conflict blocked 6 of 7 slices | The surface wires a new accessor for real, `get { self[Key.self] } set { self[Key.self] = newValue }`, and `surface-check` accepts exactly that shape; the key's `liveValue`/`testValue` stay stubs. Sprint and ship both follow it | The decomposer gives the accessor's wiring to a task every consumer depends on |
| New API a task's tests call, when `task_proof = "final"` | Rehearsal A attempt 3: the file-store worker added `defaultFileStoreURL(fileManager:)` without a stub commit and returned `surfaceCommit: null`; nothing caught it until the final `ready` gate went RED on 6 `prove.compile-only` findings (run `20260929T030053Z-2d4bf3b5`) | The user chose (2026-09-29): `build check-return` builds the task's new and changed tests at the plan surface plus the worker's returned stub, and refuses a test that doesn't compile there, so the worker commits its stub before merging. Full assertion prove stays at the final gate. About 30-60 s per task | Keep final-only prove; or prove every task (`task_proof` per task) |

### Merge points for the design-free ship waves

| File | Edited only by |
|---|---|
| `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift` | `spec-page-check` |
| `C/Commands/PlanCommand.swift` (subcommand list) | `spec-page-confirmation-binds-the-page`, then `ship-surface-lands-on-main` |
| `D/Plan/PlanFile.swift` | `plan-state-records-a-spec-page-source` (it adds every new field, with `approval` for a page, as surface) |
| `plugin/docs/standards.md` rule id index | `spec-page-check`, then `spec-page-confirmation-binds-the-page`, then `plan-lint-covers-spec-page-tests`, then `ship-surface-lands-on-main`, then `check-return-refuses-targets-the-plan-surface-lacks` (1 per wave) |
| `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md` | `workers-build-on-the-plan-surface` |
| `P/skills/ship/SKILL.md`, `P/skills/plan/SKILL.md`, the fast-modes spec | `ship-runs-without-design` |

### Design-free ship risks

- **The plan pipeline is design-shaped end to end.** `plan.json`, the edit guard, `plan-lint`, both context packs, the ledger page and the decomposer prompt all read the design. `plan-state-records-a-spec-page-source` changes a type 7 readers decode; every live plan's `plan.json` must still decode, and its first test says so.
- **Rehearsal findings carry over and grow with parallel workers.** Open in `docs/e2e-report.md`: a new package without `Package.resolved` BLOCKS `ready` (prove's scratch copy won't resolve); a surface API renamed mid-build needs stub-and-restore commits; created-device T3 boots cost 41-97 s per run. Parallel workers renaming the same surface API is likelier than 1 sprint doing it. None has a task here; the first is worth a task before the rehearsals.
- **Speed is unproven.** Each merge runs a push gate on `main` in series; for a 4-slice spec that may cost what parallelism saves (D0).
- **Standards index churn.** 5 tasks add rows across 5 waves; the merge-point table keeps it to 1 per wave.
- **Skill routing.** Changing ship's description or steps can move routing in the evals session's sets; tell that session before `ship-runs-without-design` merges.

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
| 8 | `sprint-slice-refuses-targets-the-surface-lacks` | user decision 2026-09-28: catch a new target at the slice, not at the final gate |
| 9 | `presets-may-skip-design`, `spec-page-check`, `plan-state-records-a-spec-page-source` | independent foundations: config, the page, plan state |
| 10 | `spec-page-confirmation-binds-the-page`, `context-packs-read-spec-pages`, `ledger-page-renders-spec-page-plans` | each reads the page and the new plan source |
| 11 | `plan-lint-covers-spec-page-tests`, `build-proof-bases-start-at-the-plan-surface`, `workers-build-on-the-plan-surface` | plan-lint needs the confirm's sha; the build side needs only the plan's `surfaceCommit` |
| 12 | `ship-surface-lands-on-main`, `shim-deadline-test-holds-under-load` | `shim-deadline-test-holds-under-load` too (a second flake in the shim deadline family, main run `20260928T193538Z-6929a7c9`); its own standards rows and `PlanCommand.swift`; needs the confirm |
| 13 | `check-return-refuses-targets-the-plan-surface-lacks`, `ship-runs-without-design` | the skill names every command, so it lands after them |
| 14 | `design-free-ship-rehearsals` | attended; go/no-go (D0) |

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

### `sprint-slice-refuses-targets-the-surface-lacks`
- Deps: slice-gates-measure-from-the-surface, surface-check-allows-additive-manifest-edits · Gate: push · Model: opus · estLines: 200
- Writes: `C/Commands/SprintCommand.swift`, the `D/Sprint/` file holding `SprintRefusal`, a manifest-reading helper in `A/` if one doesn't exist (reuse the surface scan's `Package.swift` parsing; never write a second parser), `TC/SprintCommandTests.swift`, `TD/` tests for the rule, `plugin/gate/Tests/Fixtures/` (captured manifests), the fixtures README, `plugin/docs/standards.md` (rule index row), `P/skills/sprint/SKILL.md` (the refusal row only), `tests/skill_commands_test.mjs` (its row), the fast-modes spec's §4.2 refusal table
- Does: a slice commit that adds a target or product to any `Package.swift`, or adds a new `Package.swift`, that the surface commit doesn't declare, can't be proven: at the surface its sources are empty, SwiftPM refuses the package, and every test in it and its dependents is `prove.compile-only` at the final `ready` gate (rehearsal A, run `20260928T164206Z-298fd7a6`, 11 findings, 50 minutes after the slice). `sprint slice` compares the declared targets and products at the slice's HEAD with those at the surface and refuses with a new rule `sprint.target-outside-surface` (exit 1), naming each package and target and the fix: amend the surface with a stub target, rebuild the slices on it. Slices that only fill declared targets pass.
- Tests: in a temp repo, a slice that adds a `…Live` target to a package the surface created is refused, naming it (catches the rehearsal case); one adding a whole new package is refused; one filling only declared targets passes; a slice that only reorders a manifest passes. Remove the check and confirm the first test goes red.

### `presets-may-skip-design`
- Deps: none · Gate: push · Model: opus · estLines: 200 · Decisions: D1, D12
- Writes: `D/Build/BuildPreset.swift`, `D/Config/ConfigSchema.swift`, `D/Build/BuildRun.swift`, `C/Commands/SelfTestCommand.swift` (its preset literal only), `TD/` config and build-run tests
- Does: build executor §5.1 as §9 corrects it. `design_tier` parses into a closed preset-only type: `none`, or one of `DesignTier`'s cases. `run.json`'s `preset.designTier` round-trips `none`, and a run.json written before this change reads as it did. A preset with `none` and any `on_design_conflict` but `block` fails config loading, naming both keys. `DesignTier`, `plan claim --tier`, `plan set --tier` and `design-scope` are unchanged, so none of them can produce `none`.
- Tests: a preset with `design_tier = "none"` and `on_design_conflict = "block"` loads (catches a config that rejects the new value). With `"amend"` it fails naming both keys. `plan claim --tier none` and `plan set --tier none` still exit 2. An unknown value (`"nothing"`) fails naming itself. A run.json with `none` round-trips byte-stable. Remove the conflict check and confirm its test goes red.

### `spec-page-check`
- Deps: none · Gate: push · Model: opus · estLines: 380 · Decisions: D5, D7
- Writes: `D/SpecPage/SpecPage.swift`, `D/SpecPage/SpecPageCheck.swift`, `C/Commands/SpecPageCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `plugin/gate/Tests/Fixtures/spec-page/` (the 2 rehearsal pages, copied as the sessions wrote them), the fixtures README, `P/skills/sprint/references/spec-page.md` (the optional `Tier:` token only), `plugin/docs/standards.md` (rule index rows), their tests
- Does: §5.2. `swiftgate spec-page check <page> --spec <spec-file> [--json]` parses the page into a closed `SpecPage` (title, spec path, goal, modules table, surface list, numbered slices each with 1 test name, an optional `Tier: T2|T3`, and a `Spec:` quote or `none`; out of scope). Findings: `spec-page.format` (a section missing or out of order, a slice without exactly 1 test, a repeated test name), `spec-page.too-long` (over 400 words), `spec-page.quote-not-in-spec` (a quote that isn't verbatim in the spec file). It prints `confirm: required` when any slice says `none`, else `skippable`, the slice ids (`slice-<n>-<kebab test name>`) and `pageSha` (sha-256 of the bytes). Exit 0 GREEN, 1 RED, 2 when the page or spec can't be read. Rule `spec-page.summary` is a nit.
- Tests: both rehearsal pages pass and report `skippable` (catches a parser tighter than the pages the sprint skill writes). A quote with 1 changed word is `quote-not-in-spec`, naming the slice. A slice with 2 tests, a missing `## Surface` and a 401-word page each fail naming themselves. 1 `none` slice makes `confirm: required`. An unreadable spec file exits 2, never GREEN. Loosen the verbatim match to case-insensitive and confirm the near-miss test goes red.

### `plan-state-records-a-spec-page-source`
- Deps: none · Gate: push · Model: opus · estLines: 320 · Decisions: D4, D9
- Writes: `D/Plan/PlanFile.swift`, `C/Commands/PlanClaimCommand.swift`, `C/Commands/PlanSetCommand.swift` (keeps the new fields), `A/PlanState/PlanStateStore.swift`, `A/PlanState/PlanLock.swift` (decode only), `D/Hooks/Guards.swift` (`PlanRecord.Design` gains a no-design case), `C/Hooks/PreToolUseHook.swift` (its reading of that case), `C/Commands/DesignDiffCommand.swift` (refuses a spec-page plan's `--chain`), `P/skills/plan/references/state-files.md` (the new shape), their tests
- Does: `plan.json` gains a closed `source`: `design` (today's `design`, `designSha`, `clarifyChain`, `tier`) or `specPage` (`path` = `<plans>/<slug>/spec-page.md`, `pageSha?`), a page `approval` (`pageSha`, `by`: `user` | `spec-quotes`, `at`), and `surfaceCommit?`. A schema-1 file with `design` decodes unchanged. `plan claim <slug> --spec-page` seeds a spec-page plan; `--design` and `--spec-page` together exit 2. The edit guard treats a spec-page plan as owning no design doc, and still lets only its lock holder write `spec-page.md`. Every command that needs a design (`design-diff --chain`, `evidence`) refuses a spec-page plan, naming it, instead of reading `design` as empty.
- Tests: every `plan.json` in the repo's own plan-state fixtures decodes as before (catches a break to live plans). A spec-page plan round-trips byte-stable. An unknown `source` or `by` fails decoding naming itself. `plan claim --spec-page` then a lock holder's Write to `<plans>/<slug>/spec-page.md` is allowed; another session's is denied; a subagent's is denied. `pageSha` absent reads as `nil`, never `""`. Run against a temp repo's common dir only.

### `spec-page-confirmation-binds-the-page`
- Deps: spec-page-check, plan-state-records-a-spec-page-source · Gate: push · Model: opus · estLines: 240 · Decisions: D5, D6
- Writes: `C/Commands/PlanConfirmCommand.swift`, `C/Commands/PlanCommand.swift`, `plugin/docs/standards.md` (rule index rows), their tests
- Does: §5.1 step 1, §7 "Confirming the spec page". `swiftgate plan confirm <slug> --by user|spec-quotes --spec <spec-file> --session <id> [--json]`, as the plan's lock holder: runs the spec page check on `<plans>/<slug>/spec-page.md`, refuses a RED page (`plan-confirm.page-red`) and `--by spec-quotes` when the check says `confirm: required` (`plan-confirm.needs-user`), then writes the approval with the page's sha and sets the index to `approved`. Exit 0 recorded, 1 refused, 2 unreadable.
- Tests: `--by spec-quotes` on a page with a `none` slice is refused (catches the skill skipping the confirm on its own reading). `--by user` on the same page is recorded with its sha. A RED page is refused under either `--by`. A session without the lock exits 1. A design plan is refused, naming it. Remove the `needs-user` check and confirm its test goes red.

### `context-packs-read-spec-pages`
- Deps: spec-page-check, plan-state-records-a-spec-page-source · Gate: push · Model: opus · estLines: 300 · Decision: D7
- Writes: `C/Commands/ContextPackCommand.swift`, `D/Context/ContextPack.swift`, `P/agents/design-decomposer.md` (the spec-page input and its ids), their tests
- Does: `context-pack --role decomposer --spec-page <path>` and `--role worker --spec-page <path>` stand in for `--design`, exactly 1 of the 2. The decomposer pack carries the page's modules, surface and slices verbatim, with each slice's id and tier. A worker pack carries the slices its task `covers`, the surface list, the modules rows its write set touches and the standards anchors as today. A `covers` id the page doesn't have is exit 1, as an unknown design id is. No summarising.
- Tests: a worker pack for a task covering `slice-2-…` holds slice 2's text byte for byte and no other slice (catches a pack that summarises or leaks slices). An unknown slice id exits 1 naming it. Both flags together exit 2. A design pack is byte-identical to before.

### `ledger-page-renders-spec-page-plans`
- Deps: spec-page-check, plan-state-records-a-spec-page-source · Gate: push · Model: opus · estLines: 180
- Writes: `C/Commands/DesignRenderCommand.swift` (the `--ledger` path only), `D/Design/LedgerRender.swift`, their tests
- Does: `design-render --ledger <plan>` for a spec-page plan reads the page at the confirmed `pageSha`, and the coverage matrix is slice × task. A page whose sha differs from the approval exits 2, naming both shas. A design plan renders as before.
- Tests: a spec-page plan's page shows each slice's row and the task covering it (catches rendering an empty matrix). A changed page exits 2. A design plan's page is byte-identical to before.

### `plan-lint-covers-spec-page-tests`
- Deps: spec-page-confirmation-binds-the-page, context-packs-read-spec-pages · Gate: push · Model: opus · estLines: 300 · Decisions: D6, D7, D10
- Writes: `C/Commands/PlanLintCommand.swift`, `D/Plan/PlanLintCoverage.swift`, `D/Plan/PlanLintGraph.swift`, `plugin/docs/standards.md` (rule index rows), their tests
- Does: §9's plan-lint correction. For a spec-page plan, `plan-lint` reads the page at the approval's `pageSha` instead of a design: every slice id is a coverage item (`plan-lint.uncovered-requirement`), `tests` ids must be slice ids (`plan-lint.unknown-test`), each task's gate is at least its slices' tier's minimum, and worker packs are built with `--spec-page`. A page whose sha differs from the approval is `plan-lint.spec-page-moved` (gating). A plan with no approval yet exits 2. Write-set disjointness stays per wave (D10).
- Tests: a ledger missing 1 slice is `uncovered-requirement` naming it (catches reading coverage from nowhere). A page edited after the confirm is `spec-page-moved`. A `Tier: T3` slice under a `fast` task is a gate finding. A design plan lints exactly as before. Remove the sha comparison and confirm its test goes red.

### `build-proof-bases-start-at-the-plan-surface`
- Deps: plan-state-records-a-spec-page-source · Gate: push · Model: opus · estLines: 140 · Decision: D9, D11
- Writes: `C/Commands/BuildProofBasesCommand.swift`, `TC/BuildProofBasesCommandTests.swift`
- Does: §3.3 for a build. `build proof-bases <slug>` puts the plan's `surfaceCommit` first when `plan.json` has one, then each merged task's return `surfaceCommit` in merge order, each sha once. A plan without one prints what it prints today.
- Tests: a plan surface plus 2 merged returns naming it and 1 naming a later stub prints the surface, then the stub, once each (catches a missing or repeated base). No plan surface: output unchanged. An unreadable `plan.json` exits 2, never an empty list.

### `workers-build-on-the-plan-surface`
- Deps: plan-state-records-a-spec-page-source · Gate: push · Model: opus · estLines: 200 · Decisions: D11, D12
- Writes: `P/workflows/build-task.js`, `tests/build_task_workflow_test.mjs`, `P/agents/build-worker.md`, `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `tests/skill_commands_test.mjs` (its build rows)
- Does: `build-task.js` takes a required `planSurface` arg (a sha or `null`). With a sha, the worker writes no surface of its own, runs its task gate with `--proof-base <planSurface>`, and when its test needs API the surface lacks commits that API alone as a stub, checks it with `swiftgate surface-check <sha>`, and returns it as `surfaceCommit`. A `design-conflict` names a spec page section. The build skill reads `surfaceCommit` from `plan.json` and passes it, and builds worker packs with `--spec-page` for a spec-page plan. `null` keeps today's prompt byte for byte.
- Tests: a missing `planSurface` arg throws `build-task: …` (catches a skill that forgets it). With a sha, the prompt names it as the proof base and forbids a new surface; with `null`, the prompt equals today's. The skill contract test passes.

### `ship-surface-lands-on-main`
- Deps: spec-page-confirmation-binds-the-page · Gate: push · Model: opus · estLines: 320 · Decision: D8
- Writes: `C/Commands/PlanSurfaceCommand.swift`, `C/Commands/PlanCommand.swift`, `A/Build/GitWorkspace.swift` (reuse the fast-forward; no second copy), `plugin/docs/standards.md` (rule index rows), their tests
- Does: §5.1 step 2 under §6. `swiftgate plan surface <slug> <sha> --gate <run id> --session <id> [--json]`, as the lock holder of a confirmed spec-page plan: `<sha>`'s parent must be `main`'s HEAD; `surface-check` on it must be GREEN; the gate run must be GREEN at the preset's `merge_gate` tier or above with `headCommit` equal to `<sha>`. Then it fast-forwards `main` to `<sha>` (refusing while another worktree has `main` checked out) and records `surfaceCommit`. Refusals exit 1 as `plan-surface.<reason>` (`not-confirmed`, `not-on-main`, `behaviour`, `gate-red`, `gate-stale`, `gate-tier`, `main-checked-out`, `already-recorded`); unreadable state exits 2.
- Tests: in a temp repo with real commits, each refusal fires: a surface with a body, a stale gate, a RED gate, a parent that isn't `main`, an unconfirmed page, a second surface. The happy path moves `main` and records the sha. Remove the `surface-check` step and confirm its test goes red.

### `check-return-refuses-targets-the-plan-surface-lacks`
- Deps: build-proof-bases-start-at-the-plan-surface, workers-build-on-the-plan-surface · Gate: push · Model: opus · estLines: 200 · Decision: D11
- Writes: `C/Commands/BuildCheckReturnCommand.swift`, `D/Build/TaskReturn.swift`, `TC/BuildCheckReturnCommandTests.swift`, `TD/` rule tests, `plugin/gate/Tests/Fixtures/` (captured manifests, reusing the sprint ones where they fit), the fixtures README, `plugin/docs/standards.md` (rule index row)
- Does: the parallel form of `sprint.target-outside-surface`. For a plan with a `surfaceCommit`, `check-return` compares every `Package.swift` the task branch changed with the plan surface, through `SliceManifests` and `ManifestDeclarationsReader` (no second parser), and fails `build-return.target-outside-surface` for a non-test target or product the surface lacks, a new package, or a manifest it can't read, naming each and the fix (a design conflict: the surface needs a stub target).
- Tests: a task branch adding a `…Live` target to a package the surface created fails naming it (catches rehearsal A's slice 4 shape in parallel). A branch filling only declared targets passes. A plan with no surface is unchanged. Remove the check and confirm the first test goes red.

### `ship-runs-without-design`
- Deps: every task above except `check-return-refuses-targets-the-plan-surface-lacks` · Gate: push · Model: opus · estLines: 320 · Decisions: D2, D8, D10, D13
- Writes: `P/skills/ship/SKILL.md`, `P/skills/plan/SKILL.md`, `tests/skill_commands_test.mjs` (ship and plan rows), `tests/preset_profile_skills_test.mjs` if it pins ship's steps, the fast-modes spec §3.3, §5.1, §5.2, the build executor spec §3.1 and §5.1 (the §9 corrections), `docs/index.md` only if a router row changes
- Does: §5.1. Ship reads the preset's `design_tier`; at `none`, after preflight: claim with `plan claim --spec-page`, write `<plans>/<slug>/spec-page.md` (sprint's format), `spec-page check`, ask once with `AskUserQuestion` only when it says `required`, `plan confirm`; write the surface on `surface/<slug>`, run the merge gate, `plan surface`; then `/swift-harness:plan` and `/swift-harness:build` as today. The plan skill's spec-page path skips the designSha approval and evidence steps (the confirm replaces them) and packs the decomposer with `--spec-page`. The resume list names the spec-page commands. "Never skip a step" becomes "never skip a step the preset runs". Every other tier runs as before. Generic: no app shape, prompt or preset value in the text.
- Tests: the skill contract test: every command and flag named exists. Ship's `none` steps follow the order the commands enforce. The page stays generic. `claude plugin validate --strict` passes.

### `surface-lands-on-a-fast-gate`
- Deps: every design-free ship task · Gate: push · Model: opus · estLines: 120 · Decision: D8 amended ("Design-free ship rehearsal fix decisions")
- Writes: `C/Commands/PlanSurfaceCommand.swift`, `TC/PlanSurfaceCommandTests.swift` (new tests only; existing tests byte-identical), `P/skills/ship/SKILL.md` (step 4 items 5-6 and the resume table), `tests/skill_commands_test.mjs` (ship rows), `plugin/docs/standards.md` (the `plan-surface.gate-tier` row's wording, if it names the merge gate)
- Does: `plan surface` requires the gate run to be GREEN at `fast` or above at `<sha>`, not the preset's `merge_gate`; `plan-surface.gate-tier` names `fast`. The `--preset` flag goes if nothing else needs it. Ship's step 4 runs `check --tier fast` at the surface, after `surface-check`, in the foreground.
- Tests: a GREEN `fast` run at the surface is accepted (catches the push-only rule that stopped rehearsal A); a GREEN `fast` run at another sha is `gate-stale`; a run below `fast` is `gate-tier`. The skill contract test runs ship's surface lines through the real binary. Revert the tier change and confirm the first test goes red.

### `build-gates-measure-from-the-plan-surface`
- Deps: `surface-lands-on-a-fast-gate` · Gate: push · Model: opus · estLines: 80 · Decision: "Design-free ship rehearsal fix decisions", second row
- Writes: `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `tests/skill_commands_test.mjs` (build rows), `tests/build_task_workflow_test.mjs` only if it pins these lines
- Does: when `plan.json` has `surfaceCommit`, the build skill's step 1 green-main check, every merge gate it runs on `main`, and the final `ready` gate add `--base <surfaceCommit>`; a plan without one runs exactly as today.
- Tests: the skill contract test walks a plan with a surface and asserts each of the 3 gate lines names `--base <surfaceCommit>`, and runs them through the real binary on a temp repo where the surface adds a module with no test: the green-main check is GREEN. With no surface, the lines are byte-identical to today's. Revert and confirm the walk goes red.

### `surface-wires-new-dependency-accessors`
- Deps: `build-gates-measure-from-the-plan-surface` · Gate: push · Model: opus · estLines: 140 · Decision: "Design-free ship rehearsal fix decisions", third row
- Writes: the surface stub-shape rules in `D/Surface/`, their tests, `plugin/gate/Tests/Fixtures/` (a captured surface with a wired accessor), the fixtures README, `P/skills/sprint/SKILL.md` (the accessor line), `P/skills/ship/SKILL.md` if it restates it, `tests/skill_commands_test.mjs` if it pins that line, `plugin/docs/standards.md` only if a rule's wording names the old shape
- Does: `surface-check` accepts a `DependencyValues` accessor whose getter is exactly `self[K.self]` and whose setter is exactly `self[K.self] = newValue`, for a key type declared in the same commit or already on the base; any other body in such an accessor stays `surface-check.behaviour`. The sprint skill's surface step writes new accessors that way; the old `get { .init() } set {}` stays accepted.
- Tests: the wired accessor shape is a stub (catches rehearsal A attempt 3's blocker); a getter doing anything else (`self[K.self].map`, a literal) is behaviour; the old shape still passes. Remove the new stub form and confirm its test goes red.

### `check-return-compiles-new-tests-at-the-proof-bases`
- Deps: `surface-wires-new-dependency-accessors` · Gate: push · Model: opus · estLines: 220 · Decision: "Design-free ship rehearsal fix decisions", fourth row (the user's choice)
- Writes: `C/Commands/BuildCheckReturnCommand.swift`, `D/Build/TaskReturn.swift`, the adapter that builds tests at a commit (reuse prove's compile step; no second copy), `TC/` new check-return tests, `plugin/gate/Tests/Fixtures/` if a capture is needed, `plugin/docs/standards.md` (rule index row), `P/agents/build-worker.md` only if its return text must name the new rule (then `calibrate build`)
- Does: for a plan with a `surfaceCommit`, `check-return` builds the task branch's new and changed test files at the proof base (the plan surface, plus the return's `surfaceCommit` when set) and fails `build-return.test-needs-stub` naming each test file that doesn't compile there, with the fix: commit the API as a stub, check it with `surface-check`, return it as `surfaceCommit`. A plan without a surface, or a return that changes no test, is unchanged.
- Tests: a task branch whose test calls a function the surface lacks, with no stub, fails naming the file (catches rehearsal A attempt 3's final-gate RED at the return); the same branch with a stub commit returned passes; a plan with no surface is unchanged. Remove the check and confirm the first test goes red.

### `design-free-ship-rehearsals`
- Deps: every task above · Gate: ready · Model: opus · estLines: 60 · Decision: D0, then D3
- Writes: `docs/e2e-report.md`
- Does: attended. The user runs `/swift-harness:ship <spec> --preset <a repo-local none preset>` on 2 practice prompts of different app shapes, not the last ones sprint used, in a warm starter repo, timed with `stats --build`. The report records wall time per step, every refusal and halt, the final gate's verdict, and the same prompts' sprint times for comparison. It ends with the user's D3 choice.
- Tests: both runs end with `main` at a GREEN `ready` gate proved at the plan surface, with no manual step except the spec-page confirm.

### `shim-deadline-test-holds-under-load`
- Deps: none · Gate: push · Model: opus · estLines: 60
- Writes: the `tests/*_test.mjs` file holding "a shim test past its deadline stops, fails naming the deadline, and leaves no process behind", and `plugin/bin/swiftgate` only if the root cause is in the shim
- Does: that test failed in a full push run on `main` at load 22 ("the shim test did not say it hit its deadline"; run `20260928T193538Z-6929a7c9`) and passed twice alone. Find the root cause with a timed trace, as `shim-kill-cleanup-test-holds-under-load` did for its sibling, and wait on the real artifact under a named deadline.
- Tests: the test passes 10 times in a row under bounded generated load, and a shim that never reaches its deadline message still fails by name. Revert the fix and confirm the loaded run goes red.
