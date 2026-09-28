# Sub-project 5: interfaces note

Each wave's merged types, formats, flags and exit codes that later workers need. The orchestrator appends a
section at every merge; workers read it and never edit it. Plan: [the build executor plan](../plans/2026-09-26-build-executor-plan.md).

## Wave 1

- **Command stubs.** Groups `build`, `ledger`, `worktree` are registered in `SwiftGate.swift`. Leaf types, all
  `ParsableCommand` with a sync `run() throws`, each in its own file under `SwiftGateCLI/Commands/`:
  `BuildStartCommand` (plan, `--preset`, `--session`, `--json`), `BuildNextCommand` (plan, `--session`, `--json`),
  `BuildMergeCommand` (plan, task, `--undo`, `--session`, `--json`), `BuildCheckReturnCommand` (file,
  `--session`, `--json`), `BuildFinishCommand` (plan, `--session`, `--json`), `LedgerSetCommand` (plan, task,
  status, `--session`, `--json`). `WorktreeCommand.swift` holds `WorktreeCreateCommand` and
  `WorktreeRemoveCommand` (plan, task, `--session`, `--json`) and `WorktreeWarmCheckCommand` (`--json`). A stub
  calls `StubCommand.notImplemented(commandPath, json:)` in `SwiftGate.swift`: exit 2, `"<path>: not implemented yet"`.
  The registration test lists them in `NewSubcommandRegistrationTests.invocations`; a task that implements one
  moves its line to `implemented`.
- **Presets.** `Config.buildPresets: [String: BuildPreset]`. `BuildPreset` (`SwiftGateDomain/Build/BuildPreset.swift`):
  `designTier: BuildPreset.DesignTier` (quick|standard|deep|sketch; the `sketch` task replaces it with the shared
  `DesignTier`), `review: Review` (full|gate), `taskGate: TaskGate` (`.ledger` or `.tier(CheckTier)`),
  `mergeGate: CheckTier`, `workerModel: WorkerModel` (tagged|sonnet|opus), `onDesignConflict: OnDesignConflict`
  (amend|block), `maxParallel`, `timeBudgetMin`, `stopStartsBeforeMin: Int`. Every key is required.
  `ConfigIssue.unknownEnumValue(path:value:allowed:)` is the issue for any closed-string config value. The
  template stamps `default` and `interview`; the real-TOML test is `SwiftGateAdaptersTests/BuildPresetTemplateTests.swift`.
- **Ledger.** `TaskStatus` adds `blocked` and `abandoned`. `LedgerTask.model: TaskModel?` (`sonnet` | `opus`) and
  `.branch: String?`; absent fields are omitted, never `null`. `LedgerTransition.check(from:to:) ->
  LedgerTransition.Outcome` (`.allowed` or `.refused(reason:)`), pure. Any non-`done` status may move to
  `needs-replan`; nothing leaves `needs-replan` through `ledger set` (re-planning rewrites the ledger).
  `LedgerRender.statusLabel(_:)` is public. `plan-lint` doesn't require `model` yet.
- **For `decomposer-model-tag`:** `tests/design_agents_test.mjs` excludes `model` and `branch` from the decomposer's
  required keys (`notYetDecomposerOwned`). Remove `model` from that list when the decomposer starts writing it.
- **Merged alongside from sub-project 2 (guards).** `plan claim|release|set` and `index set` are denied to subagents
  and to a `--session` other than the calling session's own. `claim.lock.*` and `index.lock.*` can't be hand-edited.
  The PreToolUse guard denies `git checkout|restore|rm|mv` into guarded paths. Every build command that writes plan
  state (`build start|finish`, `ledger set`, `worktree create`) must take the caller's literal `--session` and be
  covered by the same subagent denial; the wave 3 tasks add that.

## Wave 2

- **Scheduler.** `BuildScheduler.next(ledger:running:preset:startedAt:now:) -> BuildScheduler.Result` in
  `D/Build/BuildScheduler.swift`, pure. `Result { toStart: [String], running: [String] (sorted), phase: BudgetPhase,
  refused: [Refusal] (sorted by task id) }`. `Refusal { taskID, reason: RefusalReason }`, with `.missingModel` so far.
  `BudgetPhase` (`D/Build/BudgetPhase.swift`) is `normal`, `noNewStarts` (JSON `"no-new-starts"`) or `cutoff`, and it's Codable.
- **Run store.** `BuildRunStore` (`A/Build/BuildRunStore.swift`): `create(plan:presetName:preset:startedAt:git:suffix:)
  async throws(BuildRunStoreError)`, where the caller passes a random `UInt32` suffix (the domain draws no randomness), `open(plan:runID:git:)`,
  `record()`, `append(_:) async`, `events() -> BuildEventLog`, `lastMergePostCommit() throws -> String?`, which throws
  `.damagedLog` when any line is damaged. Errors: `.runExists`, `.tornTail`, `.lock`. Layout:
  `PlanStateLayout.Plan.buildRun(_:) -> BuildRunLayout` (`runFile`, `eventsFile`); lock files `events.lock.*` sit in
  the run directory. `BuildPreset` is Codable through an extension in `D/Build/BuildRun.swift`.
- **Formats.** `run.json` is `{schemaVersion: 1, runId, plan, startedAt (ISO8601), presetName, preset: {designTier,
  maxParallel, review, taskGate ("ledger" or a tier), mergeGate, workerModel, timeBudgetMin, stopStartsBeforeMin,
  onDesignConflict}}`. Each `events.jsonl` line is `{"kind":"transition","task","from","to","at"}` or
  `{"kind":"merge","task","preCommit","postCommit","at"}`, with sorted keys. `BuildEventLog.damage` holds
  `.tornLastLine(line:)` and `.undecodableLine(line:reason:)`.
- **Sketch tier.** The shared `DesignTier` (`D/Review/DesignReviewVerdict.swift`) is `quick|standard|deep|sketch`, and
  `BuildPreset.designTier` uses it. The existing frontmatter field `DesignDocument.tier: String?` is closed in
  `DesignLintEvidence`; an unknown value is `design-lint.unknown-tier` (major). `PlanLockRun.tierList` (CLI) is the shared "quick,
  standard, deep or sketch" text. `plan claim` and `plan set` accept `sketch`.
- **Follow-up (minor).** The push tier reports 19 uncovered lines in `BuildRunStore.swift`, mostly error paths. The
  `build merge` task, which uses `lastMergePostCommit`, should cover the damaged-log path it depends on.

## Wave 3

- **Worktrees.** `GitWorkspace` (`A/Build/GitWorkspace.swift`): `branchExists`, `isMerged(_:into:)`,
  `addWorktree(at:branch:from:)`, `removeWorktree(at:force:)`, `deleteBranch`, `cloneWarmBuild(_:from:into:) -> [String]`;
  errors `GitWorkspaceError` `.git` and `.clone`. `LiveGitWorkspace`, `S/FakeGitWorkspace(branches:merged:cloneFailure:)`
  with `.calls`. `TaskWorktree(commonDirectory:plan:task:)` gives `mainCheckout`, the path
  `<main parent>/<repo>-<plan>-<task>`, the branch `<plan>/<task>`, and `.base` = `main`. `WarmBuild.survey(packageDirectories:in:)`
  finds each package `.build` plus `HarnessGC.derivedDataDirectory`. `create` clones warm builds and deletes
  `ModuleCache` and `ModuleCache.noindex`; with nothing to clone it still creates the worktree cold and lists what's
  missing. Exits: 0 done, 1 not held, refused or cold (`warm-check`), 2 blocked. JSON keys: `command, plan, task,
  status (created|removed|warm|cold|not-held|refused|blocked), verdict, holder, worktree, branch, cloned, missing, message`.
- **`ledger set`.** `LedgerSetRun.run(plan:task:status:session:now:git:) async -> LedgerSetReport`. JSON keys:
  `command, plan, task, status (updated|not-held|blocked), verdict, holder, from, to, runId, message`. Exits: 0
  updated, 1 not the holder, 2 otherwise, including `no build run: run \`swiftgate build start\` first`.
- **Build loop.** `BuildClock` protocol (`now() -> Date`) and `LiveBuildClock` in `A/Build/BuildClock.swift`.
  `build start --json`: `{command, plan, runId, presetName, indexStatus}`. `build next --json`: `{runId, phase,
  toStart, running, refused:[{task, reason:"missing-model"}]}`. `build finish --json`: `{command, plan, indexStatus,
  counts, unfinished:[{task,status}], resume}`. A refusal prints `{command, plan, verdict, holder?, message}`. Exits: 1 not
  the holder, or not `planned` (start only); 2 missing `--session`, unknown preset, no run, or unreadable state.
- **Guard.** `PlanCommandGuard.sessionCommands` now includes `ledger set`, `build start`, `build finish` and
  `worktree create`. For those verbs the subagent deny message tells a build worker to return its result to the orchestrator.
- **Known duplication, fixed next by `plan-state-writes-share-one-store`:** `ledger set` and `worktree create` each
  rewrite `ledger.json` with their own code, and neither takes a lock around the read-modify-write. The latest-run lookup
  exists in both `LedgerSetRun.latestRunID(in:)` and `build next`.

## Wave 3b and wave 4 (part)

- **Ledger writes.** `LedgerWriter(plan: PlanStateLayout.Plan, lock:, timeout:)` in `A/PlanState/LedgerWriter.swift`:
  `.update(task:_:) async throws(LedgerWriterError) -> LedgerWriter.Change { before, after }`, where `LedgerEdit` is
  `.status(TaskStatus)` or `.branch(String)`. It re-reads the ledger inside the lock and writes with an atomic replace.
  Errors: `.lock`, `.ledger(PlanStateStoreError)`, `.unknownTask`, `.refusedTransition(task:reason:)`, `.io`. The
  lock files are `<plan dir>/ledger.lock.*`. Every ledger write goes through it.
- **Newest run.** `BuildRunStore.latest(plan:git:) async throws(BuildRunStoreError) -> BuildRunStore?` is the only
  lookup (it skips directories and files that aren't valid run ids). `LedgerSetRun.noBuildRun` is the shared message.
- **Task returns.** `TaskReturn`, `TaskReturnJSON`, `TaskReturnCheck.findings(_:evidence:)` and `TaskReturnEvidence`
  are in `D/Build/TaskReturn.swift`. Every key is required, and `gate`, `review` and `designConflict` may be `null`. An
  unknown key throws `TaskReturnDecodingError`. `review.findings` is `[ReviewFinding]` (the review contract), and
  `review.mode` is `BuildPreset.Review`. The command is `build check-return <file> --plan <slug> [--session <id>] --json`,
  printing `{command, plan, task, verdict, findings:[{rule,message}], warnings, message}`. Exits: 0 pass, 1 any finding,
  2 unreadable input. The task gate is the preset's tier, or the ledger's gate under `ledger`. Rules are
  `build-return.` plus `branch-missing`, `no-commits`, `commit-missing`, `commit-off-branch`, `gate-missing`,
  `gate-run-missing`, `gate-verdict-mismatch`, `gate-tier-mismatch`, `gate-not-green`, `gate-below-task-gate`,
  `gate-red-outcome-is-green`, `review-missing`, `design-conflict-outcome`, `design-conflict-unrecorded`,
  `design-conflict-unreturned` or `design-conflict-mismatch`.
- **Dependency notes.** `context-pack --role worker --build-run <run-id>` adds each dependency's `notes`, verbatim.
  Returns are stored at `<plan dir>/build/<run-id>/returns/<task-id>.json`: the build skill writes them there after
  `check-return` passes. A missing, malformed or mismatched return exits 1. `ContextPackTaskReturn.notes` decodes
  only `{task, notes}`. The build skill task should switch it to `TaskReturn`.
- **Lesson.** The consolidation worker quoted a GREEN run id that belonged to another worktree; its own only run was
  T0 RED. The orchestrator now reads each worker's `.harness/runs/history.jsonl` before merging. A second lesson:
  2 branches merged cleanly and still failed to compile together (a removed function used by the other). Only the
  push tier on merged main catches that, so it runs after every merge batch.

## Wave 4 (rest) and wave 5 (part)

- **Merge.** The command is `build merge <plan> <task> [--fix] [--undo] --session <id> [--json]`, with the flow in
  `A/Build/MergeRunner.swift` (`MergeRunner`, `LiveMergeRunner`, `S/FakeMergeRunner`). Exits: 0 merged or undone; 1
  conflicted, refused or not held; 2 blocked. JSON keys: `command, plan, task, status (merged|undone|conflicted|refused|not-held|blocked),
  verdict, holder?, runId?, branch?, mainCheckout?, mainCheck (at-last-merge|no-merge-yet)?, preCommit?, postCommit?,
  fixWorktree?, fixBranch?, conflictedFiles?, message`. The fix branch is `<plan>/fix-<task>`, in worktree
  `<main parent>/<repo>-<plan>-fix-<task>`. `--fix` merges the fix branch. `--undo` resets `main` to the pre commit
  of this task's latest merge, and only while `main` is still at that merge's post commit.
- **Events.** `BuildEvent` gains `undo`: `{"kind":"undo","task","fromCommit","toCommit","at"}`. Older logs still
  decode. `lastMergePostCommit()` is the commit `main` should be at: the newest merge's post commit, or a later
  undo's `toCommit`. Stats count an undo's time toward wall time.
- **check-return `--fix`** checks a fixer's return against `<plan>/fix-<task>` and the preset's `mergeGate`.
- **Guard.** `ledger.lock.*` (plan dir) and `events.lock.*` (`plans/<plan>/build/<run>/`) can't be hand-edited.
  `build merge` isn't in `sessionCommands` yet; the build-skill task adds it.
- **Agents.** `swift-harness:build-worker` takes task id, plan slug, worktree path, branch, write set, task gate tier,
  `test-…` ids and context pack path, plus the earlier attempt's findings on a fix pass. It has no fixed model, so the
  workflow passes the task's. It always returns `"review": null`: `build-task.js` MUST fill `review`, or `check-return`
  fails with `build-return.review-missing`. `swift-harness:build-fixer` (opus) takes the plan slug, task id, fix
  worktree path, fix branch, whether the merge conflicted or went red, both `TaskReturn`s and the merge gate tier. It
  returns `ready-to-merge` or `gate-red`.
- **Stats.** `swiftgate stats --build <run-id> --plan <slug> [--json]`. `BuildMetrics.compute(record:log:) -> Report`
  in `D/Build/BuildMetrics.swift`. JSON keys: `command, verdict, plan, runId, presetName, budgetMinutes, overBudget,
  totalWallMilliseconds, tasks:[{task,status,startedAt,endedAt,wallMilliseconds}], mergeCount, merges, damage, message`.
  `LedgerRender.Input.buildMetrics` adds a duration chip per task.
- **Gate note.** After these merges, the push tier on `c21179b` (which includes sub-project 2's mutate fix) was RED
  only on load: 35 `git` 30-second timeouts plus 2 kill-timing tests, at load average 28–38. All 134 tests in the 16
  affected suites pass alone. The full push tier gets re-run when load drops.

## Wave 6 (part)

- **Workflow.** `plugin/workflows/build-task.js` takes `args = {task, plan, worktree (absolute), branch (== "<plan>/<task>"),
  writeSet (non-empty), taskGate: fast|push|ready, tests, contextPack, model: sonnet|opus, review: "full"|"gate",
  reviewers?}`. `reviewers` is a non-empty subset of `verifier` and `test-quality`, and is allowed only with `full`.
  Unknown keys throw `build-task: …`. The pipeline runs the worker, then the reviewers (`full` only), then at most 1
  fix pass with a fresh worker. It returns exactly the `TaskReturn` keys, and `review` is always `{mode, findings}`.
  Blocking findings are `blocker` or `major`. `commits` and `testsAdded` combine both attempts; `notes` come from the
  last worker. A reviewer failure yields `review-blocked` with no fix pass. If the fix-pass worker returns nothing
  usable, the workflow THROWS, and the build skill must treat a null or failed workflow as a halt for that task.
  The reviewers have no Bash, so they're given the commits and branch and read the changed files.
- **Self-test seeds.** These live in `plugin/gate/Fixtures/seeds/{build-next,ledger-set,build-check-return,build-merge,build-presets}/`.
  `SelfTest.run(harnessRoot:sampleApp:buildChecks:)`, where `BuildSeedChecks` (`.live`) has `schedule`, `setStatus`,
  `checkReturn`, `merge` and `loadConfig`. Labels: `build-next.unmerged-dependency|write-set-overlap|missing-model|not-started`,
  `ledger-set.refused-transition`, `build-return.*`, `build-merge.<reason>`, `config.<kind>(<path>)`.
- **Merge reason.** `build merge --json` gains a closed `reason` key: `main-moved`, `dirty-checkout`, `not-on-main`,
  `not-held`, `conflicted`, `undo-refused`, `branch-missing` or `already-merged`. It's omitted when the merge succeeds.
- **Gate.** The push tier is GREEN on merged main (run 20260927T065928Z-fd0f5501, 1670 tests).

## Wave 6 (rest) and wave 8 (spec corrections)

- **Calibration.** `swiftgate calibrate build` runs `build-worker` and `build-fixer` against labelled seeds in
  `plugin/gate/Fixtures/calibrate-build/`. Worker seeds hold `base/`, `accept/`, `solution/`, `context.md`,
  `input.md` and `label.json`; fixer seeds add `main/` and `task/`. Label keys are `schemaVersion`, `outcome`, `gate`,
  `writeSet` and `tests` (`"<classname>/<name>"`), and unknown keys are rejected. The pass record is
  `calibrate-build/last-pass.json`, keyed by the content hash of both agent files. The push tier requires a fresh
  pass when either agent changes (`calibration-freshness.*`, one summary for both suites). Shared calibration code
  lives in `A/Calibration/CalibrationSeeds.swift` and `CalibrationRecord.swift`. Rules: `calibrate-build.{passed,
  label-missed,seed-defect,usage,invalid-label,missing-*,unknown-agent,uncalibrated-agent}`. One real run took 114 s
  and cost $0.15.
- **Spec corrections.** The Foundation map row 5, the sub-project 2 spec's §5.7 status row and its §8.1 tiers now
  point at this spec (commit f54e3cd).
- **Gate.** The push tier is GREEN on merged main (run 20260927T075754Z-5ea8766d, 1681 tests). Main also has
  sub-project 2's latency fix: hook budgets now measure the hook's own CPU time, so timing flakes should be rare.

## Waves 7–9

- **`/swift-harness:build`** (`plugin/skills/build/SKILL.md` + `references/event-loop.md`) runs the §3.2 loop.
  Returns are written with the Write tool to `<plans>/<slug>/build/<run>/returns/<task>.json`, only after
  `check-return` passes; the guard lets the plan's lock holder write in the plan directory, so there's no `--store`
  flag. A design conflict runs `ledger set … blocked` on every matching or dependent pending task (`LedgerTransition`
  now allows `pending → blocked`). After `build merge --fix` it runs `worktree remove <plan> <task> --fix`. The
  cutoff timer is a background `/bin/sleep`. A build resumes through `build next` while the index says `building`.
  `build merge` is in `PlanCommandGuard.sessionCommands`, and the `--undo` test cites spec §8.3. Context-pack
  dependency notes decode the full `TaskReturn`. `build-task.js` has no field for a retry note, so to retry you
  edit the design or plan first.
- **`/swift-harness:ship <spec-file> --preset <name>`** (`plugin/skills/ship/SKILL.md`). Preflight halts on: an unknown
  preset, a red `doctor`, not being on `main` or a dirty tree, or a cold `warm-check` (it then says to run
  `swift build --package-path <dir>` once in the main checkout). Then design at the preset tier, plan, build, and a
  report with the ledger link and `stats --build`. At any halt it names the remaining commands to resume with.
- **Sketch design path** (`plugin/skills/design/references/review-publish-amend.md`, "Sketch approval"). It asks
  `Approve design <slug> at designSha <sha>?` with `AskUserQuestion`; a headless session uses the headless shape
  and records only the user's answer. The answer and its `answer` claim are checked by `evidence check`. A sketch
  merges locally with no PR question. The design skill's `description:` now names `--tier sketch`. The evals
  session re-ran routing: design and plan held-out 1.00, tdd 1.00, and no wrong loads into ship or build. Recall
  for ship and build themselves is unmeasured.
- **Decomposer tag.** The decomposer tags every task `model: sonnet|opus`, the plan skill requires it, and
  `plan-lint.missing-model` (major) flags a task without it.
- **Rehearsal fixture.** The app is `evals/apps/interview-starter/`: SwiftUI iOS 18, TCA 1.26.2 with SampleApp's pins,
  an `AppFeature` and an `APIClient`/`APIClientLive` pair (`APIError`: `offline`, `badStatus(Int)`, `undecodable`),
  and its own `.swiftgate.toml`. Its push tier is 19 s warm and 79 s cold; the simulator build and launch flow takes
  95 s. The README has the warm-up steps. The specs are `specs/{1-list-detail,2-favorites-search,3-offline-sync}.md`.
  The root `.swiftgate.toml` excludes `evals/apps`, so root gates skip the starter.
- **Gate.** The push tier is GREEN on main with every task through wave 9 merged (run 20260927T084051Z-60569a67, 1696 tests).

## Speed wave 1

- **`task_proof`** is a required key of every `[build.presets.<name>]` table: `per-task` | `final`
  (`BuildPreset.TaskProof`, raw values as written; run.json key `preset.taskProof`, and a run.json without it reads
  as `per-task`). The template stamps `default` = `per-task` and `interview` = `final`. Under `final`, `build-task.js`
  (arg `taskProof`, required) tells the worker `check --tier <taskGate> --base main` without `--prove --mutate`, and
  `check-return` computes `proofRequired: !fix && taskProof == .perTask`. The build's final `ready` gate proves and
  mutates every merged task once. A repo whose `.swiftgate.toml` predates the key fails config loading until it adds
  a `task_proof` line to each preset.
- **Fail-fast `check`.** A RED T0 skips T1 and everything after it; a RED T1 skips prove (it already skipped mutate).
  Each skip is a `swiftgate.not-run` nit. After a RED T0: "T1 not run: T0 is RED", then "reach/stress/prove not run:
  T0 is RED" (ready) or "prove not run: T0 is RED" (`--prove`), then the same for mutate, judge, T2 and T3. After a
  RED T1: "prove not run: T1 is RED". Only RED counts: a BLOCKED tier still runs what
  follows. The push doc gates still run.
- **Fixer returns.** `TaskReturnEvidence.reviewRequired` (default true); `check-return --fix` passes `!fix`, so a
  fixer's `review: null` passes and a worker's green return still needs its review. The surface-commit proof-base
  check applies only when `proofRequired` is true.
- **Gate-run provenance.** Every `GateRun.execute` command records `headCommit` (full sha) in `history.jsonl` and
  `report.json`, absent when unknown; `RecordedRunReport.decode` reads it. T0-only `StaticCheckRun` commands record
  none.
- **`worktree remove`** copies the worktree's `.harness/runs/<id>/` into `<main checkout>/.harness/runs/<id>/` before
  removing it; it copies no history lines. `--json` adds `keptRuns: [id]` and `unkeptRuns: [{runId, reason}]`; a
  failed copy still removes the worktree, exits 0 and names the lost runs in `message`.
- **Merge gate lesson.** Parallel surfaced branches prove together only at a merge of all their surface commits.
- **Gate.** Integration push + prove GREEN (run 20260927T231704Z-cb69701e, 23 of 23 new tests proven); push GREEN on
  merged main (20260927T232100Z-bc6eec17); mutate GREEN, 16 of 16 killed (20260927T232331Z-47cd38d8).

## Speed wave 2

- **Repository profile.** `[harness] profile = "<name>"` in `.swiftgate.toml` names one of the file's
  `[build.presets.<name>]` tables; optional, and a repo with no `[harness]` table resolves to `default`. `bootstrap
  --profile <name>` stamps it into a new config (`default` without the flag) and advises, without rewriting, when an
  existing config names another. Config loading accepts a profile that names no preset, so hooks and gates never
  depend on it; `swiftgate doctor` fails it as `doctor.profile` (major). The build and ship skills resolve `<preset>`
  from `--preset`, then the profile, then `default`, and stop on a name with no preset table. A profile only selects a
  preset: hooks, test-first rules and the merge gate don't change.
- **Worker packs carry standards.** `context-pack --role worker` derives module kinds from the task's write set and
  the repo's module graph, and packs each touched kind's standards anchors (from the repo's standards doc, else the
  plugin's). It refuses `--module-kind` for the worker role. A write-set entry outside every module (a doc, manifest
  or fixture) adds no kind; a write set with no module entry gets a standards section saying so. A config naming a
  kind outside `ModuleKind.allCases` is the error `context-pack.module-kind-unknown` (CLI error text, not a gate
  finding).
- **Task gate steps.** `CheckExtraStep` (closed, raw values `prove`, `mutate`, `impact`, `coverage`, `app-build`).
  `check --impact` and `--coverage` run push's impact and diff-coverage rules below push; `--app-build` compiles the
  app scheme for a generic simulator through the xcodebuild adapter and judges the result bundle's build results:
  `app-build.error` (RED, at file and line), `app-build.blocked` (a failed build with no readable results),
  `app-build.container` (more than one root app container, RED), `app-build.summary`; a repo with no app container
  notes the step not run. A RED T0 skips coverage and app-build, a RED T1 skips app-build, each with a
  `swiftgate.not-run` note. Plain `check --tier fast` runs none of them. `build-task.js` passes
  `TASK_GATE_STEPS = '--impact --coverage --app-build'` to the worker under both `task_proof` modes.
- **Calibration.** The build calibration record was re-run for the new worker prompt inputs.
- **Gate.** Integration push + prove GREEN at proof base `002f4ae` (run 20260928T004518Z-a6412b52, 34 of 34 new
  tests proven, 1848 passed); push GREEN on merged main (20260928T004921Z-29fbdfb9); mutate GREEN, every mutant
  killed (20260928T005205Z-44c7bf80, 37 min at `--jobs 2` under worker load).

## Speed wave 3 and fast-modes wave 1

- **The budget keeps the app compiling.** `BuildScheduler.RequiredTask(taskID:appPath:)` and
  `BuildScheduler.RequiredTasks(ledger:packageDirectories:)` (`.empty` for a ledger with no repository; `task(_:)`
  looks 1 up). A task counts as required when a write-set entry is a `.swift` path outside every `packages`
  directory; its not-done dependencies count too, carrying that entry as their `appPath`.
  `BuildScheduler.next(…, required:)` takes the set with no default: in the no-new-starts phase only required tasks
  start, under the usual slot and overlap rules, and at cutoff nothing starts. `build next --json` adds
  `required: [{task, appPath}]` for tasks not yet done, and exits 2 when it can't read `.swiftgate.toml` or its
  `packages` globs. `LedgerRender.BuildView(…, required: .known(_) | .unknown(reason:))`: a required task's row reads
  "Required: the app target needs it to compile (<path>)", and `.unknown` prints "Tasks the app target needs are
  unknown: <reason>".
- **check-return requires the task gate's steps.** `build-return.gate-missing-step` (exit 1).
  `TaskReturnEvidence(taskGateStepsRequired:)` has no default: the CLI passes `!fix`, and `BuildCalibrationRunner`
  passes `role == .worker`. `TaskReturnCheck.taskGateSteps = [.impact, .coverage, .appBuild]`;
  `GateRun.missingSteps(of:)` returns the steps the run's tier doesn't run and its recorded history steps don't name.
  No tier counts as running `app-build`, and a run that isn't a `check --tier` run, or has no recorded steps and a
  tier that runs none of them, misses every step. All 22 `build-return.*` ids are in the rule index.
- **`swiftgate surface-check <commit> [--json]`.** Diffs the commit against its first parent and judges every added
  or changed body in its Swift files. Exit 0 GREEN, 1 on any `surface-check.behaviour` finding (major), 2 when it
  can't read the commit or its parent; `surface-check.summary` is a nit. The SwiftSyntax scan is
  `plugin/gate/Sources/SwiftGateRules/Surface/SurfaceBodyScan.swift`; the commit reader is an adapter. Beyond the
  §3.2 table and §7's empty defaults it accepts 3 shapes. An `init` may assign its own parameters or empty defaults to
  stored properties. A value may be 1 initializer call whose arguments are each an empty default or a parameter
  passed through. A change may add a bare type reference (or `Type.self`) to an existing array literal. Wave 2 broadens the accepted stub shapes.
- **Sprint state.** `<git common dir>/swift-harness/plans/sprint.json`, written under the plan index lock
  (`PlanIndexStore.lockName`) by atomic rename. `SprintStore.locate(git:)`, `read() -> SprintRun?`,
  `apply(SprintEvent) -> SprintRun`. `SprintEvent`: `start(slug:specPage:baseCommit:sliceCount:)`,
  `surface(commit:)`, `slice(_:gateRun:)`, `finish(gateRun:)`; `SprintTransition.apply` checks order first
  (start, surface, slices 1 to n, finish; a finished sprint accepts only a new start). JSON keys (`schemaVersion` 1):
  `slug`, `specPage`, `branch` (`sprint/<slug>`), `baseCommit`, `surfaceCommit?`,
  `slices[{number, status: pending|passed, gateRun?}]`, `finalGateRun?`,
  `step{name: started|surfaced|slicing|finished, slice?}`; unknown keys fail decoding. `SprintStoreError`:
  `commonDirectory`, `lock`, `transition(SprintTransitionError)`, `malformed(path:_:)`, `io(operation:path:reason:)`;
  every case leaves `sprint.json` as it was. `SprintTransitionError`: `outOfOrder(attempted:expected:)`,
  `invalidSlug`, `invalidSpecPage`, `invalidCommit`, `invalidGateRun`, `invalidSliceCount`.
- **Gate.** Integration push + prove GREEN at proof base `053723f` (run 20260928T033209Z-08328281, 57 of 57 new
  tests proven); push GREEN on merged main (20260928T033942Z-663c5f3d). Mutate over this wave and hardening wave 1
  together is RED (20260928T034623Z-e2a26931, 52 min at `--jobs 2`) on 2 survivors: `SprintStore.swift`'s
  `unlink(staging)` and a `>` boundary in `SurfaceBodyScan.swift`. The next wave fixes both.

## Fast-modes waves 2 and 3

- **`swiftgate sprint`.** `start <slug> --spec-page <spec-page> --slices <slices>` creates `sprint/<slug>` at `main`'s
  HEAD without switching to it; it needs a GREEN `check --tier push` (or above) at that HEAD in this checkout's run
  history, an existing spec page and a new branch. `surface <commit>` runs `surface-check` on the commit and refuses
  on any finding but `surface-check.summary`; the surface must be the branch's first commit, whose parent is the
  sprint's `baseCommit`. `slice <number> --gate <gate>` needs a GREEN `push` or `ready` run at the branch HEAD.
  `finish --gate <gate>` needs a GREEN `ready` run at the branch HEAD whose proof bases name the surface (full sha or
  an abbreviation of 7 or more hex digits). `status` prints the recorded run. Every command takes `--json` and acts
  only from a checkout on the sprint's branch, except `start` and `status`.
- **`finish` only fast-forwards `main`.** It moves `main` from the sprint's `baseCommit` to the branch HEAD, never
  merges or rebases, and refuses while any worktree has `main` checked out. `main` already at the branch HEAD counts
  as a finish that moved it and stopped before recording.
- **Exit codes.** 0 when the command did its step; 1 on a refusal (RED); 2 when the command can't read the sprint
  state, run history or git (BLOCKED).
- **`--json` keys.** `command`, `verdict` (`GREEN` | `RED` | `BLOCKED`), `rule` (absent when not refused), `message`,
  `next` (`start` | `surface` | `slice <n>` | `finish`), `nextCommand`, and `sprint` (absent with no recorded run):
  `slug`, `specPage`, `branch`, `baseCommit`, `surfaceCommit`, `step` (`started` | `surfaced` | `slicing` |
  `finished`), `slicesPassed`, `slices[{number, status, gateRun}]`, `finalGateRun`.
- **Refusal ids (`SprintRefusal`).** Exit 1: `sprint.out-of-order`, `sprint.invalid-slug`,
  `sprint.invalid-spec-page`, `sprint.invalid-commit`, `sprint.invalid-gate-run`, `sprint.invalid-slice-count`,
  `sprint.spec-page-missing`, `sprint.main-not-green`, `sprint.branch-exists`, `sprint.wrong-branch`,
  `sprint.surface-off-branch`, `sprint.surface-behaviour`, `sprint.gate-unknown`, `sprint.gate-tier`,
  `sprint.gate-not-ready`, `sprint.gate-red`, `sprint.gate-blocked`, `sprint.gate-stale`, `sprint.gate-proof-base`,
  `sprint.main-moved`, `sprint.not-fast-forward`, `sprint.main-checked-out`. Exit 2: `sprint.surface-unreadable`,
  `sprint.history-unreadable`, `sprint.state-malformed`, `sprint.state-locked`, `sprint.state-io`,
  `sprint.common-directory`, `sprint.git`. All 29 are in the rule id index.
- **Staging leftovers.** `SprintStoreError.stagingLeft(operation:path:reason:staging:removal:)` is a failed write
  that left its staging file beside `sprint.json` behind, unable to delete it; `leftoverStaging` names it. It reports as
  `sprint.state-io`, naming the file to delete. `sprint.json` is unchanged in every `SprintStoreError` case.
- **`surface-check` accepts 3 more stubs** (orchestrator decision 2026-09-27, pending the user's confirmation). New
  `SurfaceStubForm` cases. `throwsError`: only a `throw` of a payload-free case, an initializer call or an
  empty-payload case. `emptyPayloadCase`: an enum case the parent or the same file declares, built with each
  associated value an empty default or a parameter passed through (`.exited(0)`, `.loaded(items)`).
  `returnsUnchanged`: a parameter or a property of `self` returned as is (`value`, `self.limit`).
  `SurfaceParentIndex` gains `cases`.
- **`/swift-harness:sprint <spec-file>`.** `plugin/skills/sprint/SKILL.md`. Preflight is `## 1. Preflight`. The spec
  page is `<plans>/sprints/<slug>.md`, with `<plans>` the plan-state root under the git common dir. An API a slice
  finds missing from the surface goes in its own stub commit, checked with `swiftgate surface-check <sha>`; the
  skill never amends the recorded surface. The final `ready` gate passes `--proof-base <surface>` and then
  `--proof-base <sha>` for each extra stub, oldest first. Verified: prove 2 of 2 and `finish` moved `main`.
- **Gates.** Wave 2 integration push + prove GREEN (run 20260928T053305Z-0ba4b650, 28 of 28 proven). Push on merged
  main RED (20260928T053831Z-66eb5be1) only on the `RepositoryScriptTests.shim` load flake; that test passed when
  re-run alone. Wave 3 integration GREEN (20260928T060653Z-b0d8b1c8); push on merged main GREEN
  (20260928T061215Z-fd24c4d0). Mutate: running.
