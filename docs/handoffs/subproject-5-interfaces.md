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
