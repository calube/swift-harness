# Brownfield profile: interfaces

What each wave of [the brownfield plan](../plans/2026-10-03-brownfield-profile-plan.md) built, for the tasks that
follow. Each wave appends a section. Paths use the plan's abbreviations (`D/`, `A/`, `C/`, `B/`, `F/`).

## Wave 1

**Config and state.**
- `BrownfieldConfig { brownfield, areas, allow, buildPresets }`, `BrownfieldArea(proposed:)`.
- `BrownfieldConfigSchema.config(from:)` reads it, `BrownfieldConfigTOML.render` writes it, and
  `TOMLConfigDecoder().decodeBrownfield` decodes a file.
- `BrownfieldStateLayout(commonDir:gitDir:)` names `.config`, `.settings`, `.discoverDirty`, `.discoverLast`,
  `.baseline(tree:)`, `.warmup(tree:)`, `.plan(slug:)` and `.scratchDirectory`.
- `StateRoot { .tree(URL) | .gitDir(URL) }` has `.directory`, `.url(_:)` and `.displayPath(_:)`; `RunLayout`
  paths are relative to it, and `RunLayout.treePath(_:)` gives the `.harness/…` form.
- `StateRootResolver.resolve(worktree:)` decides by file existence only, and
  `StateRootResolver.commonConfigFile = "swift-harness/config.toml"`. Brownfield scratch trees live in
  `<git-dir>/swift-harness/scratch/`.

**Vocabularies.** `AreaLanguage`, `AreaKind`, `XcodeInclusion`, `AreaPack`, `AreaStep`, `Confidence`,
`RepositoryProfile`, `BrownfieldRuleID`. `CheckTier` gains `.slice`, `.merge` and `.final`, with `.profile` and
`.strength`.

**Discover.**
- `TrackedTreeSnapshot(paths:read:)` and `(files:)`.
- `EcosystemReader.areas(in:)` and `EcosystemReaders.all`, where each reader starts as a stub that returns no
  areas.
- `ProposedArea`, `Sourced<V>`, `DiscoverProposal`, `DiscoverRunEvent(proposal:milliseconds:edited:)`.

**Runner and tiers.**
- `AreaCommandRunning.run(_:)` returns `AreaCommandOutcome`: `.passed`, `.failed(exit:tail:junit:)`,
  `.crashed(signal:tail:)` or `.timedOut(tail:)`.
- `BrownfieldSliceCheck.run(root:base:context:)` and `BrownfieldMergeCheck.run(root:tier:base:context:)` return
  BLOCKED `swiftgate.not-run` until their tasks land. A task may add a defaulted dependencies parameter in its
  own file.

**Events and hooks.** `WarmupRunEvent`, `GateStepTiming(area:)`, `GateRunEvent(baselineCount:)`, and
`HookSettings.render(hooksJSON:pluginRoot:) -> Data?`, which returns `nil` until its task lands.

**Commands.**
- `discover`, `claude`, `warmup`, `xcode`, `allow` and `plan import` are registered as stubs that exit 2.
- `run` is a group whose default subcommand is `start`, so both `run <spec>` and `run report <slug>` work.
- `review = "classified"` and `task_proof = "prove"` parse in brownfield configs only, and the `sonnet` and
  `opus` aliases parse in owned ones only.

**Jev classification.**
- `DiffRisk.classify(_:sensitive:ask:)` returns `.sensitive(path:glob:)` or `.judged(DiffRiskLevel)`.
- `FindingSeverity.classify(_:diff:ask:)` returns a `Severity`.
- Both fail with `JudgeClassificationError.noAnswer` or `.unreadable`, and never fall back to a default level.
- `sensitive` is `[String]` globs. A caller passes `BrownfieldConfig.brownfield.sensitive`.

**Fixtures** (each section of `F/README.md` has its capture command):
- `F/Discover/<owner>-<repo>/`: 13 public repositories, with negative cases under `after-build/`.
- `F/Xcode/{synchronized,explicit,xcodegen,tuist}/`.
- `F/AreaRuns/<ecosystem>/<case>/`: 8 ecosystems; each case has a pass, a fail, a crash and a lint run, plus
  `change.diff`.
- `F/NeutralDiffs/<language>/`: 47 diffs in 8 languages, including `fp-*` false positives.

**Gate builds.** Every `swift test` the SwiftPM adapter runs sets `SWIFT_DRIVER_DSYMUTIL_EXEC=/usr/bin/true`.

**Open follow-up for wave 2.** Plugin skills, agents and `review.js` still spell `.harness/…`, including the
`task-status.json` path workers write. `executor-takes-the-brownfield-preset` resolves them through the state
root.

## Waves 2 and 3

**Runner and outcomes.**
- `LiveAreaCommandRunner(processRunner:)` runs `/bin/sh` in the area root and kills the process group on timeout.
- `AreaCommandOutcome.crashed(signal:)` takes `Int32?`.
- `AreaCommandExpansion.prepare(area:step:repositoryRoot:files:tests:junitPath:deadline:environment:)`.
- `AreaOutcomeReading.outcome(end:output:junit:)` and `AreaCacheEnvironment.make(area:layout:tree:)`.

**Rules and lint.**
- `NeutralRules.check(_:added:allow:)` returns `{findings, judgeCandidates, allowances}`; then
  `NeutralRules.noAssertionFinding(for:)`.
- `AllowMatching.lineSHA(_:)`. `swiftgate allow` writes through `BrownfieldConfigWriter` (lock `config.lock`), the
  only config writer.
- `LintOutputParser.read(_:added:)` returns `{findings, notes}`.

**Prove and baseline.**
- `BrownfieldProve.run(root:base:config:junitDirectory:dependencies:)` and `ChangedTestIDs`.
- `BaselineStore(layout:runner:scratch:lock:lockTimeout:).lookupOrRerun(_:base:)` returns a `BaselineVerdict`.

**Discover.**
- `Discover.propose`, `DiscoverEdit.parse`, `Discover.applying`, `CICommandMining.commands`.
- Mined and read commands run from the area root.
- `last.json` is a `DiscoverRecord`. `dirty.json` is `{head, paths}`, and `DirtyFileGuard` reads it.

**Config and hooks.**
- `ConfigLoader().loadProfile(repositoryRoot:commonDir:)` returns `.owned` or `.brownfield`.
- `ProjectRoot.locateProfile(from:)`. `HookRunner.brownfieldEvents` covers SessionStart, PreToolUse and Stop; Stop
  runs `slice`.

**Xcode.**
- `PBXProject(parsing:)`, `TargetMembership(project:projectPath:).newFileFindings(_:inclusion:)`.
- `XcodeGenerator(runner:repositoryRoot:layout:).generate(_:) { … }` generates in a scratch tree when the project
  is tracked.

**Tiers and warm-up.**
- `BrownfieldSliceCheck` and `BrownfieldMergeCheck.run(root:tier:base:context:dependencies:)` are live.
- `swiftgate warmup [--areas] [--json]` writes `warmup/<tree>.json`, which both tiers read for build-only decisions.

**Plan, executor and report.**
- `plan import <slug>` goes through `LivePlanParser`; `plan.json` gains a `livePlan` source with task briefs.
- In a brownfield clone, `build worktree create` and `build merge` use the plan branch `swift-harness/<slug>`:
  worktrees at `<repo>-<slug>-<task>` and merges in the plan checkout `<repo>-<slug>`, both beside the clone
  and outside the git dir. `TaskWorktree.planCheckout(commonDirectory:plan:)` names the plan checkout.
- `swiftgate run report <slug>` writes `REPORT.md`.
- The run skill is `plugin/skills/run/SKILL.md`, with a `brownfield-explorer` agent on `claude-sonnet-5-5`.

**Telemetry.**
- `events ingest` keeps the last line of a streamed message.
- `swiftgate events span start|end` prints the span id on stdout; empty stdout means telemetry is off.

**Open.**
- Brownfield telemetry writes no events until `brownfield-gates-record-and-judge` merges.
- `prove.result` is recorded for owned repositories only until `brownfield-prove-records-results` merges.

## The one-shot loop, up to the freeze

What the self-healing loop over the practice apps added between `a4814182` and the freeze tag
`harness-freeze-2026-10-05`. Results and open follow-ups: [the results page](2026-10-05-practice-app-results.md).

**Commands.**
- `swiftgate qa stage <worktree> --plan <plan> --requirement <requirement>` empties a checkout's `.harness/qa/` and
  copies in the requirement's adopted checks from plan state, for a flow repair. The orchestrator never copies a
  store file by hand.
- `swiftgate build no-repair <plan> <task> --reply --qa-run --fix-return` decides a flow row whose repair worker
  answered `no repair:`. It prints `amend-contract`, `merge-unverified`, `fix-again` or `continue`, and never
  recommends stopping the build before the cutoff.
- `build check-return` stores a task's GREEN return as `returns/<task>.json` in the plan's newest build run, where
  dependents' context packs read its notes. It stores no fixer's or failing return.
- `build halt --reason` accepts every reason the docs name: `question`, `stall`, `gate-red`, `merge-conflict`,
  `amend`, `budget`, `permission`. A return's `review-blocked` records as `question` and `design-conflict` as
  `amend`.
- `build merge` lands each task on its own green rows, credits an earlier before-merge run only on the exact tree
  it lands, and merges a task whose rows all wait on other tasks without the at-base run.

**State.**
- A `qa run` in any checkout of a clone writes to the shared store,
  `<git common dir>/swift-harness/runs/<run id>/qa/`, so a cited report path outlives the checkout. Every qa run
  lookup, `build no-repair`, `build merge` and `qa adopt --repair` read it first.
- `prove` keeps a scratch tree per linked checkout in that checkout's git dir and updates it in place; the
  warm-up pre-builds the plan checkout's tree. Removing a checkout, or the orphan sweep, removes its kept tree.
- `prove` also stores a pass under its head tree and changed tests, so `final` reuses the last merge gate's
  prove on the same head.
- Flow records keep launch, settle and capture times. A recorded qa run takes 1 snapshot per check and fills
  each check's image from the video's frame.
- Review defers a verified finding whose test needs a sibling task's code to that sibling. The return names each
  deferral, the owning task's pack quotes it, and `view.json` lists it.

**Run sessions.** The PreToolUse hook runs each orchestrator Bash call with aliases cleared, `noclobber` off and
stdin empty, and caps a foreground `timeout` at 120 s unless the call runs `swiftgate`. The write guard resolves a
`cd` chain across lines, a `cd $NAME` to a literal set earlier, and a `cd` into a directory a literal `mkdir -p`
made.

**Rule ids** (each has a row in `plugin/docs/standards.md`):
- `qa.flow-transient-state`: a warning, never gating, for a flow that waits for a state to appear and then checks
  it under a scenario that doesn't hold it.
- `a11y.input-label`: a text input with an accessibility identifier and no label, in lint and on a slice's changed
  lines.
- `test.yield-loop`: a counted `Task.yield` loop standing in for a clock.
- `plan-lint.validation-clock-unheld`: a clock-driven screen checked by a flow while the contract names no held
  scenario.
- `plan-lint.validation-obstacle-seedable`: a requirement excused from a flow by a moving or random entity while a
  brief gives the app a seed or a launch scenario.
- `guard.foreground-timeout`: the 120 s foreground cap above.
- `build-merge.at-base-unchecked`: `build merge` refused to credit a row's pass that the at-base run never took.
