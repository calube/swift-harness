# Brownfield profile: implementation plan

<!-- RESUME
Status: FROZEN at the harness freeze (2026-10-05). main is at the freeze tag `harness-freeze-2026-10-05`, and all 7 practice apps pass the brownfield one-shot. Results and the open follow-ups, none started: docs/handoffs/2026-10-05-practice-app-results.md. No wave is in flight and none is next.
History (before the freeze): `discover`, `run`, the `slice`, `merge` and `final` tiers, the warm-up and the run
skill shipped, and the brownfield profile then ran the self-healing loop over the practice apps. Of the 3 planned trial
repositories only memos ran (evals/results/2026-10-04-brownfield-*); git log is the record of which tasks merged.
Interfaces up to the freeze: docs/handoffs/brownfield-interfaces.md.
Spec: docs/designs/2026-10-03-brownfield-profile-design.md (approved 2026-10-03, 16 user decisions). Read its RESUME
header, §3, §5, §8 and §17.
Scope: the per-clone state root and config under the git common dir; `swiftgate discover` and `discover --apply`
with fixtures captured from real public repositories; hooks through `swiftgate claude`; the neutral rules and the
area rules; the area command runner, the baseline, prove over `test_files` with crash isolation, and the `slice`,
`merge` and `final` tiers; the parallel warm-up; the Xcode membership check, the generate helper and
`swiftgate xcode add-file`; `swiftgate run <spec.md>`, `plan import`, the `brownfield` preset, the run skill and the
end-of-run report; Jev `diff-risk` and `finding-severity`; the `discover.run` and `warmup.run` events and the area
fields; the 3-repository trial.
Out of scope: span events and any run viewer (a separate design owns `swiftgate events span`; see "Seam for the
run viewer"), packs beyond keeping today's rule ids behind `packs`, mutation per task, simulator QA outside iOS areas.
Time box (user, 2026-10-03): the whole harness in about 24 hours, beside the run viewer design. Wave 2 runs as a
rolling pool; see "How to work this plan".
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan".
Interfaces note: docs/handoffs/brownfield-interfaces.md (the first wave's merge creates it; each wave appends).
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate.
Progress: git log. Update this header if work resumes after the freeze.
-->

## Decisions made while planning

Rows marked "user, 2026-10-03" restate the design's §17 decisions where the plan leans on them. The other rows are
the plan's own choices within them, for the orchestrator to confirm or overturn at the first wave merge.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| A separate config type | `Config` requires `xcode`, `app_scheme` and `packages`, and 22 call sites read them | `BrownfieldConfig` is its own type in `D/Config/`, with its own schema reader and TOML renderer. `Config` and every owned-repository consumer stay unchanged. `ConfigLoader` gains `loadProfile(repositoryRoot:commonDir:) -> LoadedConfig?`, where `LoadedConfig` is `owned(Config)` or `brownfield(BrownfieldConfig)`; `load` keeps its signature | — |
| Closed vocabularies | worker brief pitfall 1 | `AreaLanguage`, `AreaKind`, `XcodeInclusion`, `AreaPack`, `Confidence` (`found`, `guessed`, `orchestrator`) and `AreaStep` (`test`, `test_files`, `lint`, `build`, `e2e`, `generate`) are closed enums. An unknown value fails decoding and names itself | — |
| Tiers on `CheckTier` | the ledger's `gate`, `[build.presets] merge_gate` and `task_gate` are all `CheckTier` | `CheckTier` gains `slice`, `merge` and `final`. In an owned repository they fail config naming the profile; in a brownfield repository, `fast`, `push` and `ready` fail the same way | — |
| How Opus fixes a guess | §5.3 says only `discover --apply` writes `config.toml`; §11.2 says Opus fixes a failing guess | `discover --apply --set <area>.<step>=<command>` and `--drop <area>.<step>`. Each set value carries source `orchestrator`; a drop becomes `missing` with the reason given by `--reason`. `discover.run`'s `edited` counts them | — |
| How an allow entry lands | §17 decision 9 puts `[[allow]]` in `config.toml`, which only `discover --apply` writes | `swiftgate allow <rule> <path>:<line> --reason <text>` hashes the line and writes through the same config writer and lock as `discover --apply`. A rediscovery keeps every entry | — |
| Keys the schema lacks | §9 `final` runs "UI and end-to-end commands discovery found"; §11.5 reads "paths the config marks sensitive" | `[[areas]] e2e` (optional command) and `[brownfield] sensitive` (globs, default empty) | — |
| JUnit detection | §7: "reads JUnit XML when the runner writes it" | A `{junit}` placeholder in `test` or `test_files` expands to a path under the git dir. Discover adds it for runners whose captured run proves the flag. Without it the outcome is the exit status and the last 40 lines | — |
| Area failure ids | §7 makes a failing command a finding but names no id | `area.test-failed`, `area.build-failed` and `area.lint-failed` (major, unless the baseline holds them); `area.step-dropped` and `area.build-only` (nit, the report lines §5.3 and §9 ask for); `baseline.summary` (nit). `neutral.not-proven` replaces `prove.not-proven` in this profile; prove's other ids (`prove.compile-only`, `prove.crashed`, `prove.no-evidence`) keep their meaning | — |
| Rule ids land in the contract | `RuleIndexTests` checks the index against a registered list in both directions, and 6 tasks would append to it in parallel | `brownfield-contract` declares every new id in 1 closed enum, registers it, and adds every index row. Each check task ships its captured fixture and may edit only its own rows' text. A check task can't merge without its fixture | orchestrator |
| Schemes without a build | §5.1: no build, 5 s for 10,000 files | Discover reads shared `.xcscheme` files and the project's target list from tracked files. It never runs `xcodebuild -list`; the warm-up's build proves the scheme | — |
| How `run` drives agents | §11.1 gives Opus the plan; §11.6 calls it `swiftgate run` | `swiftgate run <spec.md>` prepares the clone (spec copy, clock, `discover --apply`, detached warm-up, plan dir, plan branch) and starts `claude --settings <common>/swift-harness/settings.json --model claude-opus-5-5` on the run skill. The skill is the orchestrator's procedure: explorers, `PLAN.md`, contract commit, `plan import`, build loop, `final`, report | — |
| `PLAN.md` shape | §11.4 names `plan import` but no format | Task sections in this plan's shape: `### <task-id>`, then a one-line goal, `- Deps: … · Gate: … · Model: … · estLines: …`, `- Why:` (1-2 sentences and the design § it implements), `- Scope:`, `- Acceptance:` (the tests that fail first and the gate), `- Out of scope:`, `- Writes:`, `- Does:`, `- Tests:`. `plan import` carries the goal, Why, Scope, Acceptance and Out of scope into `plan.json` as each task's `brief`, which the run viewer's task drawer reads (user, 2026-10-03). An `## Assumptions` section holds 1 bullet per reading. `plan import` writes `ledger.json` and a `plan.json` with `design_tier = none` and no approval chain | — |
| Pinned model ids | §13 `worker_model = "claude-sonnet-5-5"` | `WorkerModel` gains `claudeSonnet55 = "claude-sonnet-5-5"` and `claudeOpus55 = "claude-opus-5-5"`; `build-task.js` accepts both. An alias stays valid for owned repositories only | — |
| Dirty files | §10: "workers never stage them" | Discover writes `<common>/swift-harness/discover/dirty.json`. A PreToolUse guard denies `git add` or `git commit -a` that would stage one, naming it | — |
| Write sets in a run | §11.3 derives them from the target graph | The run skill tells Opus which commands give the graph per kind. No new swiftgate command | — |
| Review without Jev | §11.5 needs a `diff-risk` answer | When Jev can't answer, `classified` review runs at `medium` and the report says so. Never silent | — |
| Trial repositories | `docs/handoffs/brownfield-trial-repos.md`; §17 decision 13 | `mozilla/glean`, `usememos/memos` and `koel/koel` as proposed, with `getsentry/sentry-cocoa` and `wagtail/wagtail` as alternates. An area whose toolchain this machine can't install (an Android SDK for glean's Kotlin bindings) goes build-only or is dropped with a report line, as §5.3 says, and doesn't fail the trial | orchestrator, 2026-10-03 |
| Fixtures from real repositories | CLAUDE.md, user, 2026-10-03 | Every discover fixture is a pinned public repository at a commit: its `git ls-files` and the bytes of each signal file. Every runner and lint fixture is a real run's output. "Fixture repositories" lists the candidates | user, 2026-10-03 |
| Trial repositories | §17 decision 13 | `trial-repos-are-proposed` proposes 3 and 2 alternates; the orchestrator picks and records the pick in this table. No trial repository is a fixture repository, so each stays unfamiliar to the code | orchestrator |
| The minimum to pass | §14 | "Minimum and trailing" lists the tasks the pass bar needs. Trailing tasks run in the same waves when the pool has room | orchestrator |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and behaviour, and
  proves at it (worker brief pitfall 10), and runs `swiftgate surface-check <surface sha>` on it.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a batch,
  merge every surface commit first and prove at that merge. Mutate runs once on `main` after waves 2 and 3.
- **Rolling pool.** Wave 2 has 16 tasks whose write sets are disjoint and whose deps are all in wave 1. The
  orchestrator runs them as a pool of up to 5 workers, starting in the listed order (critical path first), and
  merges finished branches in batches of up to 5. Builds stay serialised through the build lock's ticket queue.
  Wave 3 starts a task as soon as its deps merge; it doesn't wait for the rest of wave 2.
- **Speed mode (user, 2026-10-03).** A gate whose only failure is the node walk tests' 60 s timeout (issue #8) is
  accepted; the commit body names the run id. Don't wait for load to drop.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Network.** Only the capture tasks, `trial-repos-are-proposed` and the trial tasks touch the network: `git clone`,
  `gh api` and package installs into scratch directories under `$TMPDIR`. No test reaches the network. The Jev
  capture reads `TYPESAFE_API_KEY` from the Keychain inside the command, as the runbook says.
- **Generic harness.** No task names a product, an app shape, a practice prompt, or a favoured stack. Fixtures and
  trials span several ecosystems, and none dominates.
- **Tests never touch shared state.** Every test that writes brownfield state does it in a temp clone with its own
  git dir; none resolves this checkout's common dir.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `S/` = `plugin/gate/Sources/SwiftGateTestSupport/`,
  `TD/` `TA/` `TC/` = `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI}Tests/`, `F/` = `plugin/gate/Tests/Fixtures/`,
  `P/` = `plugin/`, `B/` = `D/Brownfield/`.

### Merge points (hot files)

| File | Edited only by |
|---|---|
| `D/Config/ConfigSchema.swift`, `D/Config/ConfigIssue.swift`, `D/Build/BuildPreset.swift` | `brownfield-contract` |
| `D/Check.swift` and every exhaustive `CheckTier` switch | `brownfield-contract` |
| `D/Events/HarnessEvent.swift`, `D/Events/GateEvents.swift`, `D/Events/TranscriptUsage.swift` | `brownfield-contract`. The run viewer plan's span kind edits `HarnessEvent.swift` too: whichever merges second rebases |
| `C/SwiftGate.swift`, `C/Commands/PlanCommand.swift`, `TC/NewSubcommandRegistrationTests.swift` | `brownfield-contract` (every new command registered as a stub) |
| `P/docs/standards.md` rule id index, `TC/RuleIndexTests.swift` | `brownfield-contract` (every row and the registration); a check task edits only its own rows' text |
| `C/Commands/CheckCommand.swift` | `brownfield-contract` (routes the 3 tiers to `C/BrownfieldCheck.swift`) |
| `C/BrownfieldSliceCheck.swift`, `C/BrownfieldMergeCheck.swift` | created as stubs by `brownfield-contract`, then filled by `slice-tier-gates-each-task` and `merge-and-final-tiers-gate-the-plan` |
| `B/Discover/Readers/<Kind>Reader.swift` | created as stubs by `brownfield-contract`, then filled by its reader task only |
| `C/Commands/<New>Command.swift` | created as a stub by `brownfield-contract`, then filled by the 1 task that owns the command (see each task's Writes) |
| `RunLayout` and the `.harness` literals | `state-root-seam` only. A later task that adds a path adds it through `StateRoot` |
| `A/Config/ConfigLoader.swift`, `D/Doctor/Doctor.swift`, `A/HookSupport.swift`, `D/Hooks/Guards.swift` | `config-loads-and-hooks-follow` (after `state-root-seam`) |
| `C/Hooks/StopHook.swift` | `slice-tier-gates-each-task` (the Stop hook runs `slice` once `slice` passes; pitfall 3) |
| `C/ChangedTestChecks.swift` | nobody. Brownfield prove is new code in `C/BrownfieldProve.swift` |
| `A/ScratchWorktrees.swift` | `state-root-seam` (the scratch parent under the git dir) |
| `P/workflows/build-task.js`, `tests/build_task_workflow_test.mjs`, `C/Commands/Build*Command.swift` | `executor-takes-the-brownfield-preset` |
| `F/README.md` | each capture task appends its own section; keep both sides on conflict |
| `F/Discover/`, `F/Xcode/`, `F/AreaRuns/`, `F/NeutralDiffs/` | their capture task only. A consumer that needs another case asks the orchestrator for a capture round, never hand-writes one |
| `docs/index.md`, `README.md`, `docs/capabilities.md`, `P/docs/telemetry.md`, `P/docs/testing-playbook.md` | `trial-repos-are-proposed` (1 index row), then `docs-describe-the-brownfield-profile` |

### Rule id index rows

`brownfield-contract` adds a "Brownfield profile (`check --tier slice|merge|final`, `discover`, `xcode`)" subsection
with these ids, each row citing its design section: `neutral.not-proven`, `neutral.no-assertion`,
`neutral.unsafe-shortcut`, `neutral.lint` (§6); `xcode.file-not-in-target` (§8); `area.test-failed`,
`area.build-failed`, `area.lint-failed`, `area.step-dropped`, `area.build-only` (§7, §9); `baseline.summary` (§10).
`doctor.config-conflict` joins the existing `doctor.*` row (§4). A new `ConfigIssue` reports under `swiftgate.config`.

### Seam for the run viewer

The run viewer design, drafted in parallel, adds span events through `swiftgate events span`. This plan designs no
span and reserves no span kind. It reserves these brownfield events, which `brownfield-contract` declares:

- `discover.run`: `ms`, `areas`, `languages`, `found`, `guessed`, `missing`, `edited`.
- `warmup.run`, 1 per area and step: `area`, `step` (`generate`, `build`, `test`), `ms`, `cache` (`cold` or `warm`),
  `outcome` (`passed`, `failed`, `dropped`, `not-installed`).
- `gate.step` gains `area?` and the steps `area-test`, `area-lint`, `area-build`, `neutral`, `baseline`,
  `xcode-membership`; `gate.run` gains `baselineCount`.
- `AgentRole` gains `explorer` and `classifier`; `judge.decision` gains the question sets `diff-risk` and
  `finding-severity`.

Marked seam: every phase boundary of a run is 1 named function, listed in the task that writes it under "Span seam"
(`DiscoverCommand.apply`, `Warmup.run(area:)`, `BrownfieldSliceCheck.run`, `BrownfieldMergeCheck.run`,
`RunCommand.prepare`, `RunReport.write`). Each task reports those names in NOTES FOR NEXT WAVES. The run viewer
plan wraps them; no task here calls `events span`.

### Minimum and trailing

The pass bar (§14) needs clone to first gate under 3 minutes, 0 findings on untouched code, a `slice` gate of 30 s
or less at p95, and 1 one-shot run per repository with every merge and `final` GREEN and 0 human input.

| Class | Tasks |
|---|---|
| Minimum | `brownfield-contract`, `state-root-seam`, `discover-fixtures-are-captured`, `area-outputs-are-captured`, `neutral-diffs-are-captured`, `trial-repos-are-proposed`, `discover-applies-a-proposal`, the 3 reader tasks for the trial's ecosystems, `config-loads-and-hooks-follow`, `neutral-rules-flag-added-lines`, `lint-output-maps-to-added-lines`, `area-commands-run`, `baseline-absorbs-known-failures`, `prove-runs-area-tests`, `plan-import-derives-the-ledger`, `executor-takes-the-brownfield-preset`, `run-skill-orchestrates-the-run`, `run-report-closes-the-run`, `slice-tier-gates-each-task`, `merge-and-final-tiers-gate-the-plan`, `warmup-fills-the-stores`, `run-prepares-and-launches`, the 3 trial tasks |
| Minimum when a trial repository has an Xcode area | `xcode-fixtures-are-captured`, `discover-reads-swift-and-xcode`, `xcode-membership-is-read`, `xcode-projects-regenerate` |
| Trailing | `jev-classifies-diff-risk-and-severity` (review falls back to `medium` with a report line), `xcode-add-file-edits-explicit-projects`, `docs-describe-the-brownfield-profile`, the discover cache key (inside `discover-applies-a-proposal`, last commit), `swiftgate allow` (inside `neutral-rules-flag-added-lines`, last commit), packs |

A trailing part sits in the last commit of its task where it shares a task, so the orchestrator can merge the
commit before it under time pressure and track the rest as a follow-up.

### Fixture repositories

`discover-fixtures-are-captured` checks each candidate is public, permissively licensed and holds more than 1
language, then pins 1 or 2 per row at a commit. Rows span ecosystems on purpose; no row is the default.

| Signal | Candidates |
|---|---|
| SwiftPM and an explicit Xcode project | `mozilla-mobile/firefox-ios` (Swift, JavaScript, Python), `wordpress-mobile/WordPress-iOS` (Swift, Objective-C, Ruby) |
| XcodeGen `project.yml` | `element-hq/element-x-ios` (Swift, Python, Ruby tooling), `yonaskolb/XcodeGen` (its own spec fixtures) |
| Tuist `Project.swift` | `tuist/tuist` (Swift, Elixir, TypeScript) |
| Synchronized folders | the first public result of `gh search code PBXFileSystemSynchronizedRootGroup` with a second language, pinned |
| Gradle and Xcode together | `touchlab/KaMPKit` (Kotlin, Swift) |
| Cargo and node workspaces | `vercel/turborepo` (Rust, TypeScript, pnpm), `tauri-apps/tauri` (Rust, TypeScript) |
| Cargo and Python | `astral-sh/ruff` (Rust, Python), `pola-rs/polars` (Rust, Python) |
| Go and node | `pocketbase/pocketbase` (Go, JavaScript), `go-gitea/gitea` (Go, TypeScript) |
| Gradle or Maven and node | `square/okhttp` (Kotlin, Java), `jhipster/jhipster-sample-app` (Java on Maven, TypeScript) |
| Python and node | `streamlit/streamlit` (Python, TypeScript), `zulip/zulip` (Python, TypeScript) |
| Ruby and node | `mastodon/mastodon` (Ruby, TypeScript), `discourse/discourse` (Ruby, JavaScript) |
| CMake, Python and SwiftPM | `ggml-org/llama.cpp` (C++, Python, `Package.swift`) |
| Elixir and node | `plausible/analytics` (Elixir, JavaScript) |

The trial pool is disjoint from this list. `trial-repos-are-proposed` starts from repositories such as
`mozilla/glean` (Rust, Kotlin, Swift, Python), `signalapp/libsignal` (Rust, Swift, Java, TypeScript),
`photoprism/photoprism` (Go, JavaScript), `getsentry/sentry-cocoa` (Objective-C, Swift, Python tooling) and
`home-assistant/iOS` (Swift, Ruby tooling), and may replace any of them.

### Risks

| Risk | Where | Mitigation |
|---|---|---|
| The warm-up runs every area at full speed (§17 decision 14) while workers' gates run, and load-sensitive tests flake (issue #8, `RepositoryScriptTests.workflowScript` and the node walk tests) | trial tasks; any gate on the same machine | Harness tests use a fake runner for the warm-up and never start a real one. A trial task holds the build lock's ticket for its warm-up, so no merge gate overlaps it. The orchestrator runs at most 1 trial at a time while a wave gate runs. A gate whose only failure is issue #8 follows the speed-mode rule above |
| Warm-up and workers compete inside 1 trial run | `run-prepares-and-launches`, the trial tasks | The warm-up keeps full speed by decision; `warmup.run` and `gate.step` record each step's time, so the trial report shows the cost. If `slice` misses 30 s at p95 only during the warm-up, the report says so and the trial records both numbers |
| Xcode generate in a scratch worktree when the repository commits its generated project | `xcode-projects-regenerate`, `warmup-fills-the-stores` | The scratch worktree sits under `<git-dir>/swift-harness/scratch/`, so the user's tree shows no diff. DerivedData is keyed by path, so a seed built in the scratch tree may not help a worker's tree: `gate.step` measures cold and warm cost per area, and the trial reports whether the seed saved time |
| A generator version other than the repository's rewrites the whole project | `xcode-projects-regenerate` | Read the pin from the repository (`Mintfile`, `.mise.toml`, `.tool-versions`, `Package.resolved` of a tools package). With no pin, or a different version installed, report it in `warmup.run` and in the report; never commit a regenerated project from a mismatched version |
| Tuist, Go, Cargo and Gradle aren't installed on this machine | capture tasks | Install into scratch with `mise` or each project's wrapper (`./gradlew`). A tool that can't be installed leaves its row with only the not-installed fixture, and the capture README says so |
| A JVM area's smallest test run can't fit 30 s (daemon start) | `slice-tier-gates-each-task` | The build-only rule of §17 decision 10 covers it; the trial measures it |
| A fixture repository changes or vanishes | capture tasks | Fixtures copy the signal files and listing at a pinned commit, so tests never fetch |
| The contract task is the head of every chain | `brownfield-contract` | It holds declarations, stubs and the config schema only; behaviour sits in wave 2. The orchestrator starts it first and reviews its report before anything else |
| 16 parallel wave 2 tasks exhaust memory | the pool | At most 5 workers at once, the build lock serialises builds, and the watchdog reports free memory under 25% |
| Span events from the run viewer collide with `HarnessEventKind` | `brownfield-contract` | Whichever merges second rebases; the kinds are additive |
| Discover misses the 5 s budget on a large tree | `discover-applies-a-proposal` | `git ls-files -z` once, reads only signal files, and a test times the largest captured fixture |

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `brownfield-contract`, `state-root-seam`, `discover-fixtures-are-captured`, `xcode-fixtures-are-captured`, `area-outputs-are-captured`, `neutral-diffs-are-captured`, `trial-repos-are-proposed`, `jev-classifies-diff-risk-and-severity` | the contract every later task compiles against, the state seam, real fixtures and the trial pick; disjoint files |
| 2 (pool) | `area-commands-run`, `neutral-rules-flag-added-lines`, `prove-runs-area-tests`, `baseline-absorbs-known-failures`, `discover-applies-a-proposal`, `config-loads-and-hooks-follow`, `lint-output-maps-to-added-lines`, `plan-import-derives-the-ledger`, `executor-takes-the-brownfield-preset`, `discover-reads-node-python-and-ruby`, `discover-reads-jvm-go-cargo-and-command`, `discover-reads-swift-and-xcode`, `xcode-membership-is-read`, `xcode-projects-regenerate`, `run-skill-orchestrates-the-run`, `run-report-closes-the-run` | each needs only the contract, the seam and its fixtures; every write set is its own files or a stub the contract made for it |
| 3 | `slice-tier-gates-each-task`, `merge-and-final-tiers-gate-the-plan`, `warmup-fills-the-stores`, `run-prepares-and-launches`, `xcode-add-file-edits-explicit-projects` | the tiers compose the runner, prove, baseline and rules; the warm-up needs the runner, baseline and generator; `run` needs discover and the warm-up command |
| 4 | `trial-first-repository`, `trial-second-repository`, `trial-third-repository`, `docs-describe-the-brownfield-profile` | the trial needs every path; the docs state what merged and what the trial measured |

Critical path: `brownfield-contract` → `area-commands-run` → `slice-tier-gates-each-task` and
`merge-and-final-tiers-gate-the-plan` → `run-prepares-and-launches` → the first trial. About 4 worker lengths plus 4
merge gates.

### `brownfield-contract`
- Deps: none · Gate: push · Model: opus · estLines: 900 · Bar: minimum
- Writes: `D/Config/BrownfieldConfig.swift`, `D/Config/BrownfieldConfigSchema.swift`, `D/Config/BrownfieldConfigTOML.swift`, `D/Config/ConfigSchema.swift` (the preset reader's new values), `D/Config/ConfigIssue.swift`, `D/Build/BuildPreset.swift`, `D/Check.swift` and each exhaustive `CheckTier` switch (`D/Plan/PlanLintCoverage.swift`, `C/Commands/ReviewCommands.swift`, `A/MutationRunner.swift`, `D/Plan/CheckTierCodable.swift`), `D/Events/HarnessEvent.swift`, `D/Events/BrownfieldEvents.swift`, `D/Events/GateEvents.swift`, `D/Events/TranscriptUsage.swift`, `B/BrownfieldRuleID.swift`, `B/BrownfieldStateLayout.swift`, `B/HookSettings.swift` (stub), `B/Discover/TrackedTreeSnapshot.swift`, `B/Discover/DiscoverProposal.swift`, `B/Discover/EcosystemReader.swift`, `B/Discover/Readers/{SwiftPM,Xcode,Node,Python,Ruby,JVM,Go,Cargo,Command}Reader.swift` (stubs), `B/AreaRun.swift`, `A/Brownfield/AreaCommandRunning.swift` (protocol only), `C/BrownfieldCheck.swift`, `C/BrownfieldSliceCheck.swift` and `C/BrownfieldMergeCheck.swift` (stubs), `C/Commands/CheckCommand.swift` (routing only), stubs `C/Commands/{Discover,Claude,Run,RunReport,Warmup,Xcode,Allow,PlanImport}Command.swift` (`run report` registered under `run`), `C/SwiftGate.swift`, `C/Commands/PlanCommand.swift`, `P/docs/standards.md` (the rows above), `TC/RuleIndexTests.swift`, `TC/NewSubcommandRegistrationTests.swift`, `TD/BrownfieldConfigTests.swift`, `TD/BrownfieldEventsTests.swift`, `TD/BrownfieldPresetTests.swift`
- Does: design §3, §4 (paths), §5.3, §12, §13. Surface commit: every type, enum case, protocol and stub command, with today's behaviour unchanged. A stub command parses its documented flags and exits through `StubCommand.notImplemented`. A stub reader returns no areas. `BrownfieldSliceCheck.run` and `BrownfieldMergeCheck.run` return BLOCKED `swiftgate.not-run` naming the tier. `HookSettings.render` returns `nil`. Then behaviour: `BrownfieldConfigSchema` reads `schema = 1`, `[harness] profile = "brownfield"`, `[brownfield]` (`discovered_at`, `slice_budget_s`, `time_budget_min`, `sensitive`), `[[areas]]` with `[areas.xcode]`, `[[allow]]` and `[build.presets.brownfield]`. `BrownfieldConfigTOML.render` is its inverse. `BrownfieldStateLayout` names every §4 path from a common dir and a git dir. `DiscoverProposal` holds each value with its source path and `Confidence`. `TrackedTreeSnapshot {paths, read(path) -> Data?}` is a value. `EcosystemReader` is `func areas(in: TrackedTreeSnapshot) -> [ProposedArea]`, pure. `AreaCommandRunning.run(_ request: AreaCommandRequest) async -> AreaCommandOutcome`, where the outcome is `passed`, `failed(exit, tail, junit?)`, `crashed(signal, tail)` or `timedOut(tail)`. The preset reader accepts `review = "classified"`, `task_gate = "slice"`, `merge_gate = "merge"`, `task_proof = "prove"`, `stall_min` and the 2 pinned ids. The event payloads and `AgentRole` cases of "Seam for the run viewer". `CheckCommand` routes `slice`, `merge` and `final` to `BrownfieldCheck`.
- Span seam: none (declarations only).
- Tests, each failing before its code: a config with every key round-trips through render and read byte for byte (catches a renderer that drops `[[allow]]` or `[areas.xcode]`). `language = "perl"` fails naming `areas[0].language` and the allowed list (catches an open string). `kind = "xcode"` with no `[areas.xcode]` fails naming the area. An `[[allow]]` with no `reason` fails. 2 areas with 1 name fail. `slice_budget_s = 0` fails. `task_gate = "slice"` in an owned `.swiftgate.toml` fails naming the profile, and `task_gate = "push"` in a brownfield config fails the same way (catches tiers leaking across profiles). `worker_model = "claude-sonnet-5-5"` decodes as the pinned case and `"sonnet-5"` fails. A `warmup.run` payload with `cache = "lukewarm"` fails decoding. Each new `GateStep` raw value matches §12. `check --tier slice` in a temp brownfield clone exits BLOCKED with `swiftgate.not-run` (catches a stub tier that passes). Every stub command exits 2 (registration test). The rule index test passes with the new rows.

### `state-root-seam`
- Deps: none · Gate: push · Model: opus · estLines: 450 · Bar: minimum
- Writes: `D/RunLayout.swift`, `D/StateRoot.swift`, `A/StateRootResolver.swift`, every source file holding a `.harness` code literal (39 literals; comments in files the contract owns stay), `A/ScratchWorktrees.swift` (scratch parent), `A/Events/EventCopyUp.swift`, `TD/StateRootTests.swift`, `TA/StateRootResolverTests.swift`
- Does: design §4. Surface commit: `StateRoot` with `.tree(URL)` (today's `<worktree>/.harness`) and `.gitDir(URL)` (`<git-dir>/swift-harness`), and `RunLayout` paths relative to it, with every caller still passing `.tree`. Then: `StateRootResolver.resolve(worktree:)` returns `.tree` when the worktree has a committed `.swiftgate.toml`, `.gitDir` when `<common>/swift-harness/config.toml` exists, and `.tree` otherwise, by file existence only. It parses nothing, so it needs no brownfield type. Every literal resolves through the root. A brownfield scratch tree goes under `<git-dir>/swift-harness/scratch/`. Worktree removal copies events up to `<common>/swift-harness/events/imported/<storeID>/` in a brownfield clone.
- Span seam: none.
- Tests: in a temp clone with a committed `.swiftgate.toml`, a gate run writes `.harness/runs/<id>/report.json` exactly as today (catches a regression for owned repositories). In a temp clone with only `<common>/swift-harness/config.toml`, a hook state write, a run report and an event all land under `<git-dir>/swift-harness/`, and `git status --porcelain` prints nothing (catches 1 literal left behind: the test walks the tree for any new file). A linked worktree of that clone writes under its own git dir, not the main one. A scratch tree in that clone sits under the git dir. A source scan finds no `".harness` code literal outside `RunLayout` (catches the next literal).

### `discover-fixtures-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 60 (fixture bytes aside) · Bar: minimum · Needs: network
- Writes: `F/Discover/<owner>-<repo>/{SOURCE,ls-files.txt,tree/<path>}`, `F/README.md` (a "Discover" section)
- Does: design §5.1. For each pinned row of "Fixture repositories": `git clone --filter=blob:none --no-checkout <url> "$TMPDIR/<repo>" && git -C … checkout <sha>`, then `git -C … ls-files -z | tr '\0' '\n' > ls-files.txt`, and copy each signal file §5.1 names (build files, workspace files, lint configs, `Makefile`, `justfile`, `bin/*` names, `.github/workflows/*`, `.gitlab-ci.yml`, `.xcscheme` files, tool pins) into `tree/` at its tracked path. `SOURCE` holds the URL, commit, date and command. No file is edited after capture. Add 1 negative case: in 1 SwiftPM and 1 node fixture clone, run the repository's own build or install once so an untracked `.build/` and `node_modules/` exist, then capture `ls-files.txt` plus `git status --porcelain --ignored`.
- Tests: none of its own (fixture task). The reader tasks consume every directory; a directory no test reads fails that wave's review.

### `xcode-fixtures-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 60 · Bar: minimum when a trial repository has an Xcode area · Needs: network
- Writes: `F/Xcode/<case>/…`, `F/README.md` (an "Xcode" section)
- Does: design §8. Capture 1 real `project.pbxproj` per inclusion kind (synchronized, XcodeGen output, Tuist output, explicit) from the fixture repositories; `xcodegen generate` run on a captured `project.yml` with the pinned XcodeGen, keeping the generated `project.pbxproj` and the tool's stdout; `plutil -lint` on a valid and a truncated project; `xcodebuild -list -json` on a captured project. Record XcodeGen's version. Tuist isn't installed here: install it into scratch with `mise`, or capture only the not-installed message and say so.
- Tests: none of its own. `discover-reads-swift-and-xcode`, `xcode-membership-is-read`, `xcode-projects-regenerate` and `xcode-add-file-edits-explicit-projects` consume every file.

### `area-outputs-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 60 · Bar: minimum · Needs: network
- Writes: `F/AreaRuns/<ecosystem>/<case>/{command,exit,stdout,stderr,junit.xml?}`, `F/README.md` (an "Area runs" section)
- Does: design §7, §9. In scratch clones of fixture repositories, run each ecosystem's real test runner on 1 passing test, 1 failing test and 1 crashing test (a test that calls `abort()` or `os.Exit`, or an equivalent the runner reports as a crash), with JUnit output where the runner supports it (`pytest --junitxml`, `jest --reporters=jest-junit`, Gradle's `build/test-results`, Maven Surefire, `go test -json`, `cargo test`, `swift test --xunit-output`, `rspec --format RspecJunitFormatter` when present). Run each repository's own linter on 1 file with a finding, keeping its native output format: ESLint, Ruff or Flake8, RuboCop, golangci-lint, Clippy, ktlint or Detekt, SwiftLint. Record each tool's version. A tool this machine lacks goes in through `mise` or the project's wrapper; one that can't is listed as missing.
- Tests: none of its own. `area-commands-run`, `lint-output-maps-to-added-lines`, `prove-runs-area-tests` and `baseline-absorbs-known-failures` consume every case.

### `neutral-diffs-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 40 · Bar: minimum · Needs: network
- Writes: `F/NeutralDiffs/<language>/<case>.diff` and `<case>.SOURCE`, `F/README.md` (a "Neutral diffs" section)
- Does: design §6. Find real commits in public repositories (`git log -S'<token>' --format=%H` in a fixture clone, or `gh search commits`) that add each token family per language: `try!`, `as!`, `fatalError`, `@unchecked Sendable`, `nonisolated(unsafe)`, Kotlin `!!`, TypeScript `as any` and `@ts-ignore`, a lint suppression per linter, a skipped or focused test per runner (`it.only`, `xit`, `@pytest.mark.skip`, `t.Skip`, `#[ignore]`, `@Disabled`, `.disabled`). Also commits that add a test with no assertion, and commits that add a test with assertions, per language. Save `git show --format= <sha> -- <path>`. Include a false-positive set: the same tokens inside strings and comments, from real commits.
- Tests: none of its own. `neutral-rules-flag-added-lines` consumes every case.

### `trial-repos-are-proposed`
- Deps: none · Gate: push · Model: opus · estLines: 120 · Bar: minimum · Needs: network
- Writes: `docs/handoffs/brownfield-trial-repos.md`, `docs/index.md` (adds that file to the brownfield row)
- Does: design §14, §17 decision 13. Check candidates with `gh api repos/<r>` and `gh api repos/<r>/languages`: public, an OSI license, more than 1 language with at least 10% of bytes each, a CI workflow, tests that run without secrets or paid services, and a clone under 1 GB. None may appear in "Fixture repositories". Across the 3: at least 4 distinct ecosystems, at least 1 Swift area, and no language pair repeated. For each candidate record the URL, the commit, the languages, the CI test commands, an estimate of the warm build, and 1 candidate change of real size for its `spec.md` (written by the trial task, not here). Propose 3 and 2 alternates. The orchestrator picks, records the pick in the decisions table, and commits it.
- Tests: none (a research task). The docs-lint test passes with the new index row.

### `jev-classifies-diff-risk-and-severity`
- Deps: none · Gate: push · Model: opus · estLines: 300 · Bar: trailing · Needs: user (key)
- Writes: `D/Judge/QuestionSets/DiffRisk.swift`, `D/Judge/QuestionSets/FindingSeverity.swift`, the question set registry, `F/Judge/jev-request-diff-risk-*.json` and `F/Judge/jev-request-finding-severity-*.json` with their captured `.reply.json` and `.status`, `F/README.md` (the "Jev" section), `TD/DiffRiskQuestionTests.swift`
- Does: design §11.5, §12. `diff-risk@1` answers `low`, `medium` or `high` for a diff, and is `high` for any path in `[brownfield] sensitive`. `finding-severity@1` answers `blocking`, `major`, `minor` or `nit` for 1 review finding. Both go through the existing cascade to Claude and record `judge.decision` with their set ids. Capture 2 replies per set with the `curl` command the Jev plan recorded.
- Tests: a captured reply decodes to each level (catches a level read from the wrong key). A sensitive path rates `high` whatever Jev answers (catches the override applied after the cascade). An unreachable backend gives no answer and an error, never `low` (catches a silent default).

### `area-commands-run`
- Deps: brownfield-contract, state-root-seam, area-outputs-are-captured · Gate: push · Model: opus · estLines: 450 · Bar: minimum
- Writes: `A/Brownfield/LiveAreaCommandRunner.swift`, `B/AreaCommandExpansion.swift`, `B/AreaOutcomeReading.swift`, `B/AreaCacheEnvironment.swift`, `S/FakeAreaCommandRunner.swift`, `TD/AreaCommandExpansionTests.swift`, `TA/LiveAreaCommandRunnerTests.swift`
- Does: design §7, §9 (caches). Surface commit: the live runner and the fake, returning `failed` with an empty tail. Then: `{files}`, `{tests}` and `{junit}` expand with shell quoting; a command without `{tests}` runs whole and the outcome says so. The runner runs the command through `/bin/sh -c` in the area root, with a deadline, kills the process group on timeout, and reads JUnit when `{junit}` was given, else the exit status and the last 40 lines. A signal exit is `crashed`. `AreaCacheEnvironment` points each ecosystem's package cache at a shared directory under the common dir only when the repository doesn't pin its own, and gives each area a DerivedData seed path under the common dir.
- Span seam: `LiveAreaCommandRunner.run`.
- Tests: a path holding a space and a `'` expands to 1 argument (catches unquoted expansion). Each captured JUnit file decodes to its pass and fail counts. Each captured crash reads as `crashed` (catches a signal read as a plain failure). A command that sleeps past its deadline ends as `timedOut` and leaves no child process (catches an orphaned process group: the test checks with `kill -0`). A repository with its own `.npmrc` cache setting keeps it.

### `neutral-rules-flag-added-lines`
- Deps: brownfield-contract, neutral-diffs-are-captured · Gate: push · Model: opus · estLines: 500 · Bar: minimum
- Writes: `B/Neutral/AssertionTable.swift`, `B/Neutral/UnsafeShortcutTable.swift`, `B/Neutral/NeutralRules.swift`, `B/Neutral/AllowMatching.swift`, `C/Commands/AllowCommand.swift` (last commit), `TD/NeutralRulesTests.swift`, `TC/AllowCommandTests.swift`
- Does: design §6, §17 decision 9. Pure over `AddedLines`. `neutral.no-assertion`: a changed test whose body holds no entry of the per-language assertion table, or only a tautology, is a candidate; the result says whether it needs the judge cascade, which the slice tier calls. `neutral.unsafe-shortcut`: the per-language token table on added lines, skipping strings and comments with a per-language lexer that handles quotes and comment markers, not a parser. An `[[allow]]` entry matches by rule, path and the SHA-256 of the line's text; an inline `swiftgate:allow <rule> — <reason>` still counts. Last commit: `swiftgate allow` writes an entry through the config writer under its lock.
- Span seam: none.
- Tests: each captured diff yields exactly the findings its README entry names; the false-positive set yields none (catches a token match inside a string or comment). A moved line with the same text keeps its allow; an edited line loses it (catches a line-number key). A bare allow is still `swiftgate.allow-missing-reason`. `swiftgate allow` in a temp brownfield clone adds 1 entry and keeps every other key (catches a writer that rewrites the areas).

### `prove-runs-area-tests`
- Deps: brownfield-contract, state-root-seam, area-outputs-are-captured · Gate: push · Model: opus · estLines: 450 · Bar: minimum
- Writes: `C/BrownfieldProve.swift`, `B/Prove/ChangedTestIDs.swift`, `B/Prove/ProveVerdict.swift`, `TD/ChangedTestIDsTests.swift`, `TC/BrownfieldProveTests.swift`
- Does: design §9, §17 decision 5. `ChangedTestIDs` maps changed test files to the ids `{tests}` takes per kind: file paths for node and python, `-run '^(TestA|TestB)$'` names for go, test function names for cargo, class names for jvm, the existing Swift discovery for swiftpm. Prove makes a scratch tree at the task head with the task's non-test changes reverted, runs `test_files` through `AreaCommandRunning`, and reports `neutral.not-proven` for a test that passes there. After `crashed`, it reruns each test alone. Without `test_files` it runs `test` whole and says so.
- Span seam: `BrownfieldProve.run`.
- Tests, with the fake runner and a temp clone: a test that passes with the source reverted is `neutral.not-proven` (catches prove reading the head run). A crash on 1 of 3 tests reruns each alone and marks only the crasher `prove.crashed` (catches siblings marked crashed). Go, cargo, node, python and jvm changed files map to the ids their captured runs accept. Removing the revert step turns the first test green; restore it (pitfall 6).

### `baseline-absorbs-known-failures`
- Deps: brownfield-contract, state-root-seam, area-outputs-are-captured · Gate: push · Model: opus · estLines: 350 · Bar: minimum
- Writes: `B/Baseline.swift`, `A/Brownfield/BaselineStore.swift`, `TD/BaselineTests.swift`, `TA/BaselineStoreTests.swift`
- Does: design §10. `baseline/<tree>.json` keyed by the merge base's tree id holds each failing step and test id. A gate that sees a failure looks it up, else reruns that step at the merge base in a scratch tree through `AreaCommandRunning` and records the answer. A failure present at both trees is absorbed and counted; the store writes under a lock, by atomic rename.
- Span seam: `BaselineStore.lookupOrRerun`.
- Tests: a failure at both trees is absorbed and counted in `baselineCount`; a failure only at the head stays (catches a baseline that hides new failures). 8 concurrent writers each record 1 entry and the file holds 8 (catches a write outside the lock). A corrupt file is a non-gating finding naming it and a rerun, never a silent empty set (pitfall 4).

### `discover-applies-a-proposal`
- Deps: brownfield-contract, state-root-seam, discover-fixtures-are-captured · Gate: push · Model: opus · estLines: 550 · Bar: minimum (the cache key trails, in the last commit)
- Writes: `B/Discover/Discover.swift`, `B/Discover/CICommandMining.swift`, `B/Discover/ProposalTable.swift`, `A/Brownfield/GitTrackedTree.swift`, `A/Brownfield/BrownfieldConfigWriter.swift`, `C/Commands/DiscoverCommand.swift`, `TD/DiscoverTests.swift`, `TC/DiscoverCommandTests.swift`
- Does: design §5. `GitTrackedTree` builds a `TrackedTreeSnapshot` from `git ls-files -z` and reads signal files lazily. `Discover.propose` runs every `EcosystemReader`, then mines CI workflows, `Makefile`, `justfile` and `bin/*` for commands, which outrank a reader's guess for the same area and step. `discover` prints §5.2's table. `discover --apply` writes `config.toml`, `settings.json` (through `HookSettings.render`), `discover/dirty.json` and `discover/last.json` under the common dir with a lock and atomic renames, and emits `discover.run`. `--set` and `--drop` follow the decisions table. Last commit: the cache key over each build file's bytes and the listing of the directories it names.
- Span seam: `DiscoverCommand.apply`.
- Tests: the untracked `.build/` and `node_modules/` fixture yields no area for either (catches a filesystem walk). A CI command for an area outranks the reader's guess, and the table names the workflow as the source. `--apply` in a temp clone writes nothing that `git status --porcelain --ignored` shows inside the tree (catches state in the tree). `--set web.lint=…` records source `orchestrator` and `edited = 1`. The largest captured fixture proposes in under 5 s. A changed directory listing misses the cache (catches the stale-manifest false RED §16 lists).

### `discover-reads-node-python-and-ruby`
- Deps: brownfield-contract, discover-fixtures-are-captured · Gate: push · Model: opus · estLines: 350 · Bar: minimum when the trial needs them
- Writes: `B/Discover/Readers/NodeReader.swift`, `B/Discover/Readers/PythonReader.swift`, `B/Discover/Readers/RubyReader.swift`, `TD/DiscoverNodePythonRubyTests.swift`
- Does: design §5.1. Node: an area per workspace package (npm, pnpm and yarn workspace files), its `test`, `lint` and `build` scripts, the package manager from its lockfile. Python: an area per `pyproject.toml` or `setup.cfg` project, pytest with a file filter, the configured linter. Ruby: an area per `Gemfile` root, RSpec or Minitest, RuboCop when configured.
- Tests: each captured fixture of these ecosystems yields the areas, commands and confidences its README entry names (catches a reader tuned to 1 repository: every fixture runs). A `package.json` with no `test` script yields `missing: test`, not a guessed `npm test`.

### `discover-reads-jvm-go-cargo-and-command`
- Deps: brownfield-contract, discover-fixtures-are-captured · Gate: push · Model: opus · estLines: 350 · Bar: minimum when the trial needs them
- Writes: `B/Discover/Readers/JVMReader.swift`, `B/Discover/Readers/GoReader.swift`, `B/Discover/Readers/CargoReader.swift`, `B/Discover/Readers/CommandReader.swift`, `TD/DiscoverJVMGoCargoTests.swift`
- Does: design §5.1. JVM: an area per Gradle or Maven module, the wrapper when present, the test task with a filter, the configured linter. Go: an area per `go.mod`, `go test ./...` with `-run`, golangci-lint when configured. Cargo: an area per workspace member, `cargo test` with a name filter, Clippy. Command: `mix.exs`, `CMakeLists.txt` and other build files become an area whose commands come only from CI mining.
- Tests: each captured fixture of these ecosystems yields its named areas and commands. A Gradle build without a wrapper says so in the source column.

### `discover-reads-swift-and-xcode`
- Deps: brownfield-contract, discover-fixtures-are-captured, xcode-fixtures-are-captured · Gate: push · Model: opus · estLines: 400 · Bar: minimum when a trial repository has an Xcode area
- Writes: `B/Discover/Readers/SwiftPMReader.swift`, `B/Discover/Readers/XcodeReader.swift`, `TD/DiscoverSwiftXcodeTests.swift`
- Does: design §5.1, §8. SwiftPM: an area per `Package.swift`, `swift test --package-path` with `--filter`. Xcode: an area per project or workspace, schemes from shared `.xcscheme` files, test targets, and the inclusion kind: `project.yml` is XcodeGen, `Project.swift` is Tuist, a `PBXFileSystemSynchronizedRootGroup` is synchronized, else explicit. Whether the generated project is tracked goes into the proposal, for the warm-up.
- Tests: each captured Xcode fixture yields its inclusion kind (catches a Tuist manifest read as SwiftPM). A tracked generated project is recorded as tracked. A package inside an Xcode workspace is 1 area, not 2.

### `config-loads-and-hooks-follow`
- Deps: brownfield-contract, state-root-seam · Gate: push · Model: opus · estLines: 400 · Bar: minimum
- Writes: `A/Config/ConfigLoader.swift`, `D/Doctor/Doctor.swift`, `B/HookSettings.swift` (fills the stub), `A/HookSupport.swift`, `D/Hooks/Guards.swift` (the dirty-file guard), `C/Commands/ClaudeCommand.swift`, `TA/ConfigLoaderProfileTests.swift`, `TD/HookSettingsTests.swift`, `TD/DirtyFileGuardTests.swift`, `TC/ClaudeCommandTests.swift`
- Does: design §4, §10, §17 decisions 1 and 12. `ConfigLoader.loadProfile` reads a committed `.swiftgate.toml` first and `<common>/swift-harness/config.toml` next; both together is `doctor.config-conflict` (major). Doctor in a brownfield clone skips the shim, SwiftLint and Xcode pin checks of an owned repository. `HookSettings.render(hooksJSON:pluginRoot:)` turns `plugin/hooks/hooks.json` into a settings file with the same 4 events and absolute commands. Hooks find the brownfield config, and their state goes under the state root. The commit-msg comments check doesn't run in this profile. `swiftgate claude [args…]` execs `claude --settings <common>/swift-harness/settings.json` with the args passed through. The guard denies staging a path in `dirty.json`.
- Span seam: none.
- Tests: a clone with both configs fails doctor with `doctor.config-conflict` naming both paths. The rendered settings name exactly the 4 events of `hooks.json` (catches an event dropped when `hooks.json` gains one: the test reads the real file). A `git add <dirty path>` command is denied and `git add <other>` passes (pitfall 5's cross case). `swiftgate claude` with a fake `claude` on `PATH` receives `--settings` and the passed args in order.

### `lint-output-maps-to-added-lines`
- Deps: brownfield-contract, area-outputs-are-captured · Gate: push · Model: opus · estLines: 300 · Bar: minimum
- Writes: `B/Neutral/LintOutputParser.swift`, `TD/LintOutputParserTests.swift`
- Does: design §6 `neutral.lint`. Parse each captured linter format into `(path, line, message, rule?)`, normalise paths to the repository root, and keep findings on added lines only. An unparseable line keeps its text in a non-gating note, never silently dropped (pitfall 4).
- Tests: each captured lint output yields the findings its README entry names, by path and line. A finding on an untouched line of a changed file is dropped (catches whole-file lint findings). A format the parser doesn't know surfaces as a note naming the area.

### `plan-import-derives-the-ledger`
- Deps: brownfield-contract · Gate: push · Model: opus · estLines: 350 · Bar: minimum
- Writes: `B/LivePlan.swift`, `C/Commands/PlanImportCommand.swift`, `TD/LivePlanTests.swift`, `TC/PlanImportCommandTests.swift`
- Does: design §11.4. Parse `PLAN.md` in the shape the decisions table fixes, with `## Assumptions`. `plan import <slug>` writes `ledger.json` and `plan.json` under `<common>/swift-harness/plans/<slug>/` through the existing writers, creates the root `PLAN.md` symlink, and adds it to `.git/info/exclude` once.
- Span seam: none.
- Tests: a plan with 3 tasks and 2 waves imports to the ledger the executor reads (catches a dropped dep). A task with no `Writes` fails naming the task. A gate of `push` fails in this profile. Importing twice adds the exclude line once. `git status --porcelain` shows nothing after import (catches the symlink left unexcluded).

### `executor-takes-the-brownfield-preset`
- Deps: brownfield-contract · Gate: push · Model: opus · estLines: 350 · Bar: minimum
- Writes: `P/workflows/build-task.js`, `tests/build_task_workflow_test.mjs`, `C/Commands/BuildStartCommand.swift`, `C/Commands/BuildNextCommand.swift`, `C/Commands/BuildRecordGateCommand.swift`, `D/Build/BuildScheduler.swift`, `TC/BuildBrownfieldPresetTests.swift`
- Does: design §13. `build start --preset brownfield` in a brownfield clone reads the preset from `config.toml`; any other preset there, or `brownfield` in an owned repository, fails naming the profile. `build-task.js` accepts the pinned ids, `taskProof: "prove"` (prove without mutate) and `review: "classified"`; `stall_min` reaches the stall watch.
- Span seam: none.
- Tests: `--preset default` in a brownfield clone fails naming the profile (catches §16's silent default). The workflow rejects `model: "sonnet"` under the brownfield preset and accepts `claude-sonnet-5-5`. A `prove` task gate passes `--prove` and never `--mutate`.

### `xcode-membership-is-read`
- Deps: brownfield-contract, xcode-fixtures-are-captured · Gate: push · Model: opus · estLines: 450 · Bar: minimum when a trial repository has an Xcode area
- Writes: `D/Xcode/PBXProject.swift`, `D/Xcode/TargetMembership.swift`, `TD/PBXProjectTests.swift`, `TD/TargetMembershipTests.swift`
- Does: design §8. Parse a `project.pbxproj` (old-style plist) into objects, groups, build files, Sources phases and synchronized root groups with their exception sets. `TargetMembership.targets(compiling:)` answers for a path. `xcode.file-not-in-target` fires for a new Swift file under a source root that no target compiles. Pure domain, no Foundation IO.
- Tests: each captured project answers membership for 3 known files (catches a parser that only reads explicit lists). A file under a synchronized folder's exception set is not compiled (catches exceptions ignored). A new file under a source root with no target is a finding; a new file in a test target's folder is not.

### `xcode-projects-regenerate`
- Deps: brownfield-contract, state-root-seam, xcode-fixtures-are-captured · Gate: push · Model: opus · estLines: 300 · Bar: minimum when a trial repository has an Xcode area
- Writes: `A/Xcode/XcodeGenerator.swift`, `TA/XcodeGeneratorTests.swift`
- Does: design §8, §11.2. Read the generator pin from the repository. Run the pinned `xcodegen generate` or `tuist generate`; when the generated project is tracked, generate in a scratch tree under the git dir, else in place. A missing or mismatched generator returns `notInstalled` or `versionMismatch` with both versions, never a silent run.
- Span seam: `XcodeGenerator.generate`.
- Tests: with a fake process runner replaying the captured XcodeGen output, a tracked project generates in a scratch path under the git dir and the user's tree has no diff (catches a generate in place). A missing tool returns `notInstalled`, matching the captured message. A version mismatch names both.

### `run-skill-orchestrates-the-run`
- Deps: brownfield-contract · Gate: push · Model: opus · estLines: 300 · Bar: minimum
- Writes: `P/skills/run/SKILL.md`, `P/skills/run/references/plan-shape.md`, `P/agents/brownfield-explorer.md`, `P/skills/bootstrap/SKILL.md` (the brownfield branch runs `discover --apply`, writes nothing into the tree), `tests/skill_commands_test.mjs` (new rows), `tests/run_skill_test.mjs`
- Does: design §11. The orchestrator procedure: read `spec.md`; pick areas; 1 explorer per area with a 3-minute soft and 4-minute hard deadline and a 300-word return; draft the plan skeleton while explorers run; read warm-up times and mark build-only areas; fix failing guesses with `discover --apply --set` or `--drop`; write `PLAN.md` with `## Assumptions`; land the contract commit on the plan branch; `plan import`; build with `--preset brownfield`; `check --tier final`; `run report`. It never asks the user. Explorer and worker models are pinned ids. Every commit lands on the plan branch in worktrees under the git dir; no `--no-verify`.
- Span seam: none (prose).
- Tests: every `swiftgate` command the skill names exists (the skill commands test). The skill holds no question to the user and no `--no-verify` (catches an approval step). The explorer agent's frontmatter pins `claude-sonnet-5-5`.

### `run-report-closes-the-run`
- Deps: brownfield-contract · Gate: push · Model: opus · estLines: 300 · Bar: minimum
- Writes: `B/RunReport.swift`, `C/Commands/RunReportCommand.swift` (fills the stub), `TD/RunReportTests.swift`
- Does: design §11.6. Render the report from the plan dir, `baseline/<tree>.json`, the warm-up times and the gate runs: the assumptions, the baseline failures, the build-only areas, the dropped steps, the review fallback lines, and the plan branch to merge. Write it to the plan dir and print it.
- Span seam: `RunReport.write`.
- Tests: a plan dir with 2 assumptions, 1 baseline failure and 1 build-only area renders each in its section (catches a dropped section). A missing baseline file is a line saying so, not an empty section.

### `slice-tier-gates-each-task`
- Deps: area-commands-run, neutral-rules-flag-added-lines, lint-output-maps-to-added-lines, prove-runs-area-tests, baseline-absorbs-known-failures, config-loads-and-hooks-follow, xcode-membership-is-read · Gate: push · Model: opus · estLines: 500 · Bar: minimum
- Writes: `C/BrownfieldSliceCheck.swift`, `C/Hooks/StopHook.swift`, `TC/BrownfieldSliceCheckTests.swift`
- Does: design §9, §17 decision 10. For each touched area: neutral rules and lint on changed files; the area's changed tests at the task head; prove; the baseline for every failure; `xcode.file-not-in-target`; the judge cascade for `neutral.no-assertion` candidates. An area whose warm test time doesn't fit `slice_budget_s` builds only and reports `area.build-only`, and its tests move to `merge`. Each step is a `gate.step` with `area`; `gate.run` carries `baselineCount`. The Stop hook runs `slice` in a brownfield clone.
- Span seam: `BrownfieldSliceCheck.run`.
- Tests, with fakes in a temp clone: an empty commit and a 1-line change produce 0 findings on untouched code (the §14 measure). A failing test the baseline holds doesn't gate and counts once. An area whose warm time is 45 s runs build only and says so. A slice over fakes that answer at once completes under 30 s (catches a serial walk over areas: 3 areas with 5 s fakes finish in under 10 s).

### `merge-and-final-tiers-gate-the-plan`
- Deps: area-commands-run, baseline-absorbs-known-failures, prove-runs-area-tests, config-loads-and-hooks-follow · Gate: push · Model: opus · estLines: 400 · Bar: minimum
- Writes: `C/BrownfieldMergeCheck.swift`, `TC/BrownfieldMergeCheckTests.swift`
- Does: design §9. `merge`: every touched area's `test`, `lint` and `build` against the baseline, plus the tests and prove that `slice` moved here. `final`: `merge` for every area plus each area's `e2e`. Each step is a `gate.step` with `area`.
- Span seam: `BrownfieldMergeCheck.run`.
- Tests: a build-only area's moved tests run and prove at `merge` (catches tests that `slice` moved and nobody ran). `final` runs every area even when the plan touched 1. A dropped step reports `area.step-dropped` and never gates.

### `warmup-fills-the-stores`
- Deps: area-commands-run, baseline-absorbs-known-failures, xcode-projects-regenerate, discover-applies-a-proposal · Gate: push · Model: opus · estLines: 400 · Bar: minimum
- Writes: `B/Warmup.swift`, `C/Commands/WarmupCommand.swift`, `A/Brownfield/WarmupTimesStore.swift`, `TD/WarmupTests.swift`, `TC/WarmupCommandTests.swift`
- Does: design §11.2, §17 decision 14. `swiftgate warmup [--areas a,b]` runs every area in parallel at full speed: `generate` for XcodeGen and Tuist, then `build`, then `test`, at the base tree, with build output under the git dir or ignored paths. It writes warm test times and cold cost to `<common>/swift-harness/warmup/<tree>.json`, fills the baseline from the test run, and emits 1 `warmup.run` per area and step. It waits for nothing and runs to the end.
- Span seam: `Warmup.run(area:)`.
- Tests, with fakes: 3 areas start together (catches a serial warm-up: start times within 1 s). A failing guessed command records `failed` and the other areas finish. After the run, `git status --porcelain --ignored` in the temp clone shows no new path outside ignored ones. A second run on the same tree reads `cache = warm`.

### `run-prepares-and-launches`
- Deps: discover-applies-a-proposal, warmup-fills-the-stores, plan-import-derives-the-ledger, config-loads-and-hooks-follow · Gate: push · Model: opus · estLines: 400 · Bar: minimum
- Writes: `C/Commands/RunCommand.swift`, `B/RunClock.swift`, `TC/RunCommandTests.swift`
- Does: design §11.6, §17 decisions 15 and 16. `swiftgate run <spec.md>`: read the spec by path; copy an untracked spec under the plan dir; start the clock in the plan dir; `discover --apply`; spawn `swiftgate warmup` detached with its log under the git dir; create the plan branch at `HEAD`; launch `claude --settings … --model claude-opus-5-5` on the run skill with the slug. The user's checked-out branch never moves.
- Span seam: `RunCommand.prepare`.
- Tests, with a fake `claude` and fake warm-up in a temp clone: the tree is clean after `run` and the checked-out branch's sha is unchanged (catches a commit on the user's branch). An untracked spec is copied, a tracked one is read in place. The clock's start time precedes discover's event. The warm-up starts before `claude` launches.

### `xcode-add-file-edits-explicit-projects`
- Deps: xcode-membership-is-read, xcode-projects-regenerate · Gate: push · Model: opus · estLines: 400 · Bar: trailing
- Writes: `D/Xcode/PBXProjectEdit.swift`, `A/Xcode/XcodeProjectFiles.swift`, `C/Commands/XcodeCommand.swift`, `TD/PBXProjectEditTests.swift`, `TC/XcodeAddFileCommandTests.swift`
- Does: design §8. `swiftgate xcode add-file <path> --target <t>` adds a file reference, a build file, a group child and a Sources phase entry with ids derived from the path and target, then checks with `plutil -lint` and `xcodebuild -list`. For XcodeGen and Tuist it calls the generator; for synchronized folders it does nothing and says so. It never moves groups, renames targets or changes build settings.
- Tests: adding a file to a captured explicit project makes `TargetMembership` answer that target, and every other object's bytes are unchanged (catches a rewrite of the whole file). Adding the same file twice is a no-op. The ids are the same on 2 runs.

### `trial-first-repository`, `trial-second-repository`, `trial-third-repository`
- Deps: every minimum task · Gate: push · Model: opus · estLines: 40 each (results aside) · Bar: minimum · Needs: network
- Writes: `evals/results/<date>-brownfield-trial/<repo>/` (spec, run log, events export, report, measures)
- Does: design §14. Fresh clone of the picked repository at its recorded commit. Write a `spec.md` for the change `trial-repos-are-proposed` named, outside the clone. Measure clone to first `gate.run`. Run `slice` on an empty commit and on a 1-line change: 0 findings. Run `swiftgate run spec.md` headless with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, and record every merge, `final`, the `slice` p95 from `gate.run`, and the absence of any user prompt in the session. Hold the build lock ticket during the warm-up. A failure is a finding for the orchestrator, not a reason to patch the clone.
- Tests: none (an evaluation). The results README states each §14 measure with its source event.

### `docs-describe-the-brownfield-profile`
- Deps: the trial tasks · Gate: push · Model: opus · estLines: 250 · Bar: trailing
- Writes: `P/docs/brownfield.md`, `P/docs/telemetry.md`, `P/docs/testing-playbook.md` (the 3 tiers), `docs/index.md`, `README.md`, `docs/capabilities.md`, `docs/handoffs/brownfield-interfaces.md` (final section)
- Does: describe what merged and what the trial measured; the design follows the code where they differ.
- Tests: the docs-lint and prose gates pass on the added lines.
