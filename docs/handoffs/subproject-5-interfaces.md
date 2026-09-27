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
