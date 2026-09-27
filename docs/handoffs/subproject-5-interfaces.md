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
