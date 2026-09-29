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
- **`surface-check` accepts 3 more stubs** (orchestrator decision 2026-09-27, approved by the user 2026-09-28). New
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

## Fast-modes wave 5 (sprint rehearsal fixes)

- **Prove retries emptied targets.** `ProofRules.retryable(_ tests:in judgement:) -> [ChangedTest]` returns the tests
  with a compile-only or no-evidence finding, or every test on a package-level no-evidence; each is retried at the
  next `--proof-base`. `ProofRules.combine` takes a test's findings and blocked flag from the last attempt that ran
  it. With no proof base left, `target '…' referenced in product '…' is empty` is `prove.compile-only`, never
  BLOCKED. Fixture: `SwiftTest/emptied-target`.
- **Sprint pages under plan state.** `PlanStateGuard.Target.sprintPage` (lock scope `.none`): a main session may
  write a `.md` file directly under `<plans>/sprints/`; a subagent never may, even with a lock or the override.
  Anything else under `sprints/` is denied. `PlanStateLayout.sprintsDirectoryName = "sprints"`; `layout.plan(_:)`
  throws `.invalidPlanName` for it in any letter case, and `KnownIdSources` skips the directory.
  `plugin/docs/hooks.md` doesn't mention sprint pages yet.
- **Slice gates measure from the surface.** `RunHistoryRecord.base: String?`: history JSON key `base`, the sha
  `--base` resolved to, left out when unresolved and `nil` on older lines. `GateRun.execute(..., base: String?)`.
  `sprint slice` requires `record.base == surfaceCommit`, after the stale check, else `sprint.gate-base` (exit 1).
  `finish` still takes a `ready` run at `--base main`. The skill's "Gate run ids" example still says `--base main`.
- **Gates.** Integration push + prove RED twice on load-only tests at load 70-178 (seed and build-check tests on a
  60 s `git` timeout, then `MutationOrphanTests.timeoutTakesTheProcessTreeDown` and the shim tests). Every one
  passed re-run alone; standalone prove GREEN (run 20260928T164005Z-aaa5df2c) at proof base `416348d`. Merged as a
  fast-forward to the integration branch.

## Fast-modes waves 6 and 7 (sprint rehearsal fixes)

- **T3 never clones a booted base.** `SimulatorSelection.provision(from:)` returns
  `SimulatorProvision.clone(baseUDID:)` only when the base's state is `Shutdown`, else
  `.create(deviceType:runtime:)`, made with `Simctl.create(name:deviceType:runtime:)` under the same lock, name and
  orphan sweep as a clone. A booted base is never shut down. `SimulatorSelectionError.baseDeviceTypeUnknown(udid:state:)`,
  `SimctlError.timedOut(command:deadline:)`. Config `[simulator] simctl_timeout_seconds`: default 180, range
  30...1800, else `outOfRange "30...1800"`; boot and install keep 300 s. The test fake is `FakeSimctl`, and it refuses
  to clone a booted device. No new rule id: `t3.no-evidence`.
- **Surfaces may extend a manifest.** `SurfaceStubForm.extendsManifest`: in an existing `Package.swift`, array
  literals that only gain dependencies, products, targets or target names are stubs.
  `SurfaceBehaviour.changesManifest(excerpt:)` covers every other manifest change, as `surface-check.behaviour`
  (declaration `package`, not waivable). A new manifest still judges nothing.
- **Shim kill-cleanup test.** It waits for the cold build's own lock on disk, under a 30 s deadline it names when it
  runs out, then 20 s for the reap check. The root cause was a fixed 20 s deadline racing `shim_test.sh`'s rsync of
  the gate package at load 150.
- **Sprint skill.** Slice gates run `--base <surface>`; only preflight's push gate and `finish`'s `ready` gate take
  `--base main`. The `ready` gate runs in the foreground. `<spec-file>` may sit outside the repository. A new
  `@Dependency` accessor stubs as `get { .init() }` / `set {}`. `plugin/docs/hooks.md` lists the sprint page row.
- **Gates.** Integration push + prove GREEN (run 20260928T171856Z-96f22392), 14 of 14 proven at proof base `aaf4733`.

## Fast-modes wave 9 (design-free ship foundations)

- **Presets may skip design.** `BuildPreset.designTier: BuildPreset.DesignStep` is `.design(DesignTier)` or `.none`,
  with shorthands `.quick`, `.standard`, `.deep`, `.sketch`; its raw value is `"none"` or the tier name. Config
  `design_tier = "none"` needs `on_design_conflict = "block"`, else `outOfRange` at
  `build.presets.<name>.on_design_conflict`, naming `design_tier`. run.json writes `preset.designTier` as `"none"`.
  `plan claim --tier none` and `plan set --tier none` exit 2 and write nothing.
- **Spec page check.** `swiftgate spec-page check <page> --spec <spec-file> [--json]`: exit 0 GREEN, 1 RED, 2 BLOCKED.
  JSON keys `command`, `verdict`, `message`, `confirm` (`required` | `skippable`), `pageSha`,
  `slices[{number,id,test,tier,line,quote}]`, `findings`. Rules `spec-page.format`, `spec-page.too-long`,
  `spec-page.quote-not-in-spec` (major) and `spec-page.summary` (nit). Slice ids are `slice-<n>-<kebab test name>`;
  `Tier: T2.` or `Tier: T3.` goes before `Spec:`. A quote passes with different whitespace or whole words dropped at
  either end; curly quotes, a change of case or a cut word fail. Fixtures in `Tests/Fixtures/spec-page/*.txt`.
- **Plan state records a spec page.** plan.json: `"source":"specPage"`, `"specPage":{"path":"spec-page.md","pageSha"?}`,
  top-level `"approval":{"pageSha","by":"user"|"spec-quotes","at"}` and `"surfaceCommit"?`. A design plan writes no
  `source` key. API: `plan.designSource`, `plan.specPageSource`, `PlanFile.seedSpecPage(slug:)`,
  `PlanStateStore.specPageFile(_:)`. Guard cases `PlanRecord.Design.specPage` and `WrittenDesign.specPage`; a plan's
  kind can't change. `plan claim --spec-page` with `--design` or `--tier`, and `plan set --tier` on a spec-page plan,
  exit 2. `plan-lint`, `design-render` and `design-diff --chain` refuse a spec-page plan for now, naming it; later
  waves replace those refusals. Old tests that read `design`, `designSha`, `approval`, `clarifyChain` or `tier` compile
  through test-only read-throughs in `PlanFileDesignFields.swift` (one per test target).
- **Gates.** Integration push + prove GREEN (run 20260928T205246Z-95d9410c), 53 of 53 proven at the merged surface
  `c569933`. The first run went RED on 5 old tests edited only for the new API; the fix restored them byte-identical.

## Fast-modes wave 10 (confirm, packs and ledger for spec pages)

- **Confirming the page.** `swiftgate plan confirm <slug> --by user|spec-quotes --spec <file> --session <id> [--json]`,
  as the plan's lock holder. Exit 0 recorded; 1 for `plan-confirm.page-red`, `plan-confirm.needs-user` or not held;
  2 for a design plan, an unknown `--by`, or anything unreadable. JSON keys `command`, `plan`, `status`
  (`confirmed` | `refused` | `not-held` | `blocked`), `verdict`, `rule`, `holder`, `by`, `confirm`, `pageSha`,
  `findings`, `message`; every key is present, absent values are null. Success writes `specPage.pageSha` and top-level
  `approval {pageSha, by, at}`, and sets the index entry to `approved`, keeping its resume note.
- **Context packs.** `context-pack --role decomposer|worker --spec-page <path>`: exactly 1 of `--design` and
  `--spec-page`, else exit 2; `--spec-page` on another role exits 2. A malformed page or an unknown `covers` id exits 1.
  Pack lines `<slice id>: T<n>`. Domain: `SpecPageSource`, `SpecPageDecomposerInputs`, `SpecPageWorkerInputs`,
  `ContextPackRoleInputs.specPageDecomposer` and `.specPageWorker`, `ContextPackError.unknownSliceID(_:page:)`,
  `SpecPageWriteSet.resolve(_:graph:page:packageDirectories:)`. `design-decomposer.md` has a spec-page section;
  calibration re-ran GREEN (23 cases).
- **Ledger page.** `design-render --ledger` for a spec-page plan exits 2 when the page is unconfirmed (naming
  `swiftgate plan confirm <slug>`), unreadable, not UTF-8, doesn't parse, or its sha differs from `approval.pageSha`.
  `--json` writes `pageSha` in place of `designSha`. The section is "Slice × task coverage", with rows carrying
  `data-slice`. `LedgerRender.Source` is `.design(DesignDocument, designSha:)` or `.specPage(SpecPage, pageSha:)`.
- **Spec page parser.** A CRLF page parses: lines split on every newline. The mutation survivors from the wave before
  have killing tests in `SpecPageEdgeTests.swift`.
- **Gates.** Integration push + prove GREEN (run 20260928T221246Z-5849051e), 28 of 28 proven at the merged surface
  `11786a6`. Wave 9's mutate on main was BLOCKED once (its baseline failed a load-sensitive test while 3 workers built),
  then RED on 4 survivors under the build lock (run 20260928T205737Z-fd2c99ed), fixed in `bd27a93`.

## Fast-modes wave 11 (plan-lint and the build side for spec pages)

- **plan-lint on a spec-page plan.** `swiftgate plan-lint <slug>` exits 0 or 1; 2 when the page is unconfirmed (the
  message names `swiftgate plan confirm <slug>`), unreadable, not UTF-8 or malformed. Every slice id is a coverage item
  (`plan-lint.uncovered-requirement`), `tests` ids must be slice ids (`plan-lint.unknown-test`), and a `Tier: T3`
  slice under a `fast` task is `gate-too-weak`. `plan-lint.spec-page-moved` (major) fires when the page's sha differs
  from the approval; the file is the page's absolute path, and the moved page is still linted as it stands. Slices
  count toward `max_tests_per_task`. Domain: `PlanLintGraph.allFindings(specPage:pagePath:ledger:ledgerPath:graph:workerPacks:bounds:)`.
  `design-decomposer.md` names the new rule; design calibration re-ran GREEN.
- **Proof bases.** `build proof-bases <slug>` lists the plan's `surfaceCommit` first, then each merged task's surface in
  merge order, each sha once (duplicates drop even with no plan surface). JSON keys unchanged. An unreadable `plan.json`
  exits 2; a missing one keeps the task surfaces and names the missing path.
- **Workers on the plan surface.** `build-task.js` requires `planSurface` (a sha matching `/^[0-9a-f]{7,40}$/`, or
  `null`; missing throws `build-task: planSurface is required`). With a sha, workers write no surface of their own and
  gate with `--proof-base <planSurface>`, adding `--proof-base <stub sha>` for a stub they commit through
  `surface-check`; their return `surfaceCommit` is that stub, never the plan surface. A design conflict's section must
  be `slices`, `surface` or `modules`. `null` keeps today's prompt and schema byte for byte. The build skill reads
  `surfaceCommit` from plan.json and packs spec-page workers with `--spec-page`. Build calibration re-ran GREEN.
- **Gates.** Integration push + prove GREEN (run 20260928T230639Z-da6e2f53), 17 of 17 proven at the merged surface
  `8fea618`. Mutate for waves 10 and 11 waits for the shim deadline fix: its flake failed mutate's unmutated baseline
  twice (runs 20260928T205530Z-a55b34f5 and 20260928T221558Z-10ce1539).

## Fast-modes wave 12 (the plan surface lands on main) and the shim deadline fix

- **Plan surface.** `swiftgate plan surface <slug> <sha> --gate <run id> --preset <name> --session <id> [--json]`, run
  from the checkout whose run history holds the gate run, as the lock holder of a confirmed spec-page plan. `--preset`
  names the preset whose `merge_gate` the gate run must meet. Exit 0 recorded, 1 refused or not held, 2 blocked. JSON
  keys `command`, `plan`, `status` (`recorded` | `refused` | `not-held` | `blocked`), `verdict`, `rule`, `holder`,
  `surfaceCommit`, `gate`, `mergeGate`, `findings`, `message`. Rules `plan-surface.not-confirmed`, `not-on-main`,
  `behaviour`, `gate-unknown`, `gate-red` (a BLOCKED gate too), `gate-stale`, `gate-tier`, `main-checked-out`,
  `already-recorded`. It fast-forwards `main` with no merge commit and records `surfaceCommit`; a run that moved `main`
  but stopped before recording records on the next call.
- **Shim test deadline.** `tests/shim_test.sh`'s `cleanup` ignores a TERM that lands once it has begun, so a shim test
  past its deadline reports it and reaps. `tests/shim_deadline_cleanup_test.mjs` waits for the deadline message under a
  named wait and carries a mid-command stall case.
- **Gates.** Integration push + prove GREEN (run 20260929T003505Z-8bb2318a), 14 of 14 proven at `2a41700` (the
  surface merged onto `main`). The first run went RED once on `RepositoryScriptTests.shim()` with empty stdout; it
  passed alone and on the re-run. Mutate for waves 10-11 (run 20260928T231822Z-da99afb4) judged every sampled mutant;
  2 sort-comparator survivors are in a fix round.

## Fast-modes wave 13 (ship runs without a design)

- **check-return and the plan surface.** For a plan with `surfaceCommit`, `build check-return` compares every
  `Package.swift` the task branch changed with the plan surface through `SliceManifests` and
  `ManifestDeclarationsReader`, and fails `build-return.target-outside-surface` (exit 1, 1 finding per manifest) for a
  non-test target or product the surface lacks, a new package, or an unreadable manifest. The message tells the worker
  to return a design conflict with section `surface`. It applies to worker and `--fix` returns. A missing plan.json adds
  a `warnings` line naming its path; an unreadable one exits 2. `TaskReturnEvidence.planSurface: PlanSurfaceManifests?`
  (`surface`, `manifests: [SliceManifest]`).
- **Ship at `design_tier = "none"`.** Ship's steps are 1 preflight, 2 claim, 3 spec page, 4 surface, 5 plan, 6 build,
  7 report. The surface gate is `check --tier <merge_gate>` with no `--base`; `plan surface` runs while the checkout is
  on `surface/<plan>`. The plan skill skips the design approval and evidence steps for a confirmed spec page and packs
  the decomposer with `--spec-page`. "Never skip a step the preset runs." The `ship` and `plan` descriptions changed:
  the evals session should re-run its routing cases for both.
- **No Artifact tool.** When a session has no Artifact tool (headless), the plan, build and ship skills report
  `.harness/design-render/<slug>-ledger.html` in place of publishing. The ledger page is a view, never a gate. The
  orchestrator added this for the headless rehearsals; the design approval page is unchanged.
- **Gates.** Integration push + prove GREEN (run 20260929T011632Z-0c492c71), 9 of 9 proven at `2e14cb0`. Mutate for
  waves 12-13 runs after the rehearsals.
