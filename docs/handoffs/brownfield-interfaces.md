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
