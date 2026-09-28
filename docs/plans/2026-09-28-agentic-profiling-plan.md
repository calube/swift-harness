# Agentic profiling: implementation plan

<!-- RESUME
Status: NOT STARTED.
Spec: docs/designs/2026-09-28-agentic-profiling-design.md (approved 2026-09-28). Decision record: [ADR 0006](../adrs/0006-profiling-wraps-xctrace-report-only-first.md).
Scope: sub-project 4. `swiftgate profile`, `profile calibrate` and `leaks`; the `xctrace`, `footprint`, `leaks` and flow adapters; the parsers, statistics, noise history and bands; SampleApp's spans, XCTMetric test and weak-reference test; the `validate` callers; an acceptance run on `examples/SampleApp`. The device lane (§11) and blocking on a band (§7) are out of scope.
Depends on sub-project 3 (docs/plans/2026-09-28-simulator-qa-plan.md) in 2 tasks only: `validate-runs-leaks-and-profile` and `profiling-acceptance-on-sample-app`. Waves 1-7 build in parallel with it.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan". Interfaces note: docs/handoffs/subproject-4-interfaces.md (the first wave's merge creates it; each wave appends).
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate, with mutate once on main per wave or per 2 waves.
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

The design leaves each of these open. The user approved all 4 rows marked "user" on 2026-09-28, as written: each run
installs the side it measures, the `profiling = base|off` preset key, `[[flows]] modules`, and host leak mode reporting
only unavailability if the probe capture fails. Each is cheap to reverse.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| What "sub-project 3's flow replay" is | §8: "each kept QA flow is an XCUITest that T3 runs". T3's `[[flows]]`, `FlowCoverage.flow(forTest:flows:)` and SampleApp's `CounterFlowUITests` exist on `main` today. Sub-project 3's plan has no flow-replay task: its kept flows are more `[[flows]]` entries and XCUITests (`qa-skill-drives-flows-to-a-verdict`) | The `FlowDriver` replays T3 flow tests, which exist now, so the flow tasks don't wait. Only 2 tasks wait on sub-project 3: `validate-runs-leaks-and-profile` on its `callers-run-simulator-qa` (the same skill files, and profiling runs after QA), and `profiling-acceptance-on-sample-app` on its `sample-app-selects-a-scenario-by-launch-argument` (the network-free `fixed-fact` fact flow) | — |
| Base and head on 1 clone (§6: "under distinct bundle ids") | A command-line `PRODUCT_BUNDLE_IDENTIFIER` override reaches every target in the scheme, the UI test runner included, so the runner and the app would share an id. Renaming a built app's bundle id breaks its signature | Each run installs the side it measures just before it records: `simctl install` for launch, and `test-without-building` for a flow, which installs its own app. Both sides pay the same install, so the delta holds, and `--attach` by name isn't needed. Amend §6's sentence in `profile-base-compares-interleaved-runs` | approved by the user 2026-09-28 |
| How a flow is recorded | A flow's XCUITest launches the app, so `--launch` can't, and `--attach` would race the launch | Time Profiler with the Hangs instrument, `--device <udid> --all-processes`, for the flow's lifetime. The parser keeps rows whose process is the app's executable (`CFBundleExecutable` of the built app). If the capture finds `--all-processes` refused on a Simulator, the worker reports a DEVIATION and attaches by name after polling for the process | — |
| What the launch scenario records | §3.2 names App Launch for `launch.duration`, and 1 Time Profiler recording per scenario | 2 recordings per run: App Launch with `--launch` (cold), and Time Profiler with `--instrument Hangs --launch --time-limit 5s`, which gives `cpu.*`, `hangs.*` and any spans | — |
| When `footprint` samples | An XCUITest terminates the app when it ends, so a sample at scenario end finds no process | `FootprintSampler` polls `footprint -p <pid> -j` every second while the scenario runs, and keeps the last good sample's `phys_footprint_peak`, a lifetime peak. No sample at all is `profile.no-evidence` for `memory.peak` | — |
| Which flows the diff reaches (§8) | `[[flows]]` entries have `name` and `reason` only; nothing maps a flow to modules | An optional `modules = [...]` on `[[flows]]`. A flow with `modules` is reached when `impact`'s changed modules meet them; one without is reached by any change to a module the app scheme links. First 3 in declaration order; the rest are named as skipped | approved by the user 2026-09-28 |
| The preset switch (§11: "the preset sets `validate = true`") | No preset has a `validate` key. Sub-project 3 added `sim_qa = "changed" \| "off"`, required like every preset key | A required preset key `profiling`, a closed enum `base` \| `off`. The template's `default` sets `base` and `interview` sets `off`. `validate` runs profiling when it's `base` and prints `validate: profiling off` otherwise. The 2 keys together are §11's switch | approved by the user 2026-09-28 |
| The `[profile]` table | §9 and §10 name `leak_check` and `budget_min`; `[harness] profile` already names a preset | `[profile] budget_min` (default 6, range 1...60) and `leak_check` (closed enum `xctest` \| `host`, default `xctest`). The table keeps the design's name; the template comment says it isn't `[harness] profile` | — |
| Verdicts | §5.1 names the enum, not its edges | Every metric is lower-is-better. `delta_pct = (head − base) / base × 100`. With a band: `within-band` inside ±band, else `regressed` or `improved`. Without: `report` inside ±10%, else `regressed` or `improved`. A base median of 0 (hangs) leaves `delta_pct` `null`; head above 0 is `regressed`. A head-only run has no base and verdict `report` | — |
| A/A samples and sessions (§7) | "20 A/A samples from at least 5 separate sessions" | A sample is 1 `profile calibrate` run's head-versus-head median delta for 1 metric; a session is 1 invocation (its run id). So a band needs 20 calibrate runs, at least 5 of them distinct invocations: each calibrate run adds 1 sample, and `--runs` sets the medians' depth, not the sample count | — |
| Leak rule ids beyond §5.2 | §9: xctest mode "reports their count"; host mode "parses the leak count and root types". §5.2 lists only `leaks.host-unavailable` | 4 more notes: `leaks.summary` (weak-reference tests found and passed, or the host count), `leaks.none-found` (no weak-reference test in the repository), `leaks.check-failed` (one failed; T1 also fails it), `leaks.host-found` (a host run found leaks; names root types) | — |
| Which tests are leak checks | §9: "a test holds a weak reference, drops the strong ones, and asserts the weak reference is `nil`" | Static, through `SwiftGateRules`' `TestFunction`: a test whose body declares a `weak var` or `weak let` and asserts that name is `nil` (`#expect(x == nil)`, `XCTAssertNil(x)`). `leaks` runs them through the T1 host runner, filtered to them | — |
| XCTMetric ids and runs | §4: `xctmetric.<test>.<metric>`; §7: read from the xcresult | `xcrun xcresulttool get test-results metrics`. The id is `xctmetric.<Class>.<method>.<identifier>`, with Xcode's metric identifier. Measure tests are the UI test methods that call `measure(metrics:`; flow recordings skip them, and a separate pass runs them once per side, base first. Each side's value is the median of its iterations | — |
| Host `leaks` success output | Survey: `leaks` failed on simulator processes on this laptop; Developer mode is the user's call | The capture records the real failure on a Simulator pid (`leaks.host-unavailable`), and a success from a tiny macOS host probe with a deliberate retain cycle. If the probe fails too, host mode ships reporting only unavailability, never a pass, and the task reports BLOCKED on the success half | approved by the user 2026-09-28 |
| A quiet machine (§10) | §10: "waits on the same process check the runbook uses"; the runbook pattern is `swiftgate-mutate-sel[f]-` | A machine-wide `FileCountingLock(name: "profile", capacity: 1)`, then waiting while `pgrep -f` finds `swiftgate-mutate-sel[f]-` or `check --tier read[y]`. The wait ends at the budget; then exit 2 naming the PIDs. Load is `getloadavg`'s 1-minute value; `noisy` when the start is above `ProcessInfo.activeProcessorCount` | — |
| Evidence kept | §6: delete the trace after export | The exported XML tables and `footprint` JSON stay under `.harness/runs/<id>/profile/` as `evidence`; the `.trace` bundle goes unless `--keep-traces` | — |
| The hang fixture | SampleApp has no hang; fixtures are never hand-written | The recorder's capture runs on a local, never-merged SampleApp branch that blocks the main thread for 2 s in the counter view's `onAppear`. The README names the branch diff | — |
| Exit codes | §5: 0, 1, 2; sub-project 3's `sim` commands use 3 for BLOCKED | `profile` and `leaks` follow §5: 0 when nothing gates (always, while report only), 2 when the command couldn't run at all | — |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and behaviour, and
  proves at it (worker brief pitfall 10), and runs `swiftgate surface-check <surface sha>` on it.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a wave,
  merge every surface commit first and prove at that merge. Mutate runs once on `main` after each wave, or once per
  2 waves when the first of the pair adds only skill or doc text.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Machine time.** This laptop saturates at 3 workers plus a gate, counted across this plan and sub-project 3's:
  run their waves interleaved, never 2 full waves at once. Live captures (`xctrace-recorder-records-and-exports-tables`,
  `flow-driver-replays-a-flow-while-recording`, `xctmetric-results-read-from-xcresult`,
  `host-leaks-adapter-reads-leaks-output`) run 1 at a time on the machine, in the foreground, on a device the harness
  creates or clones under the `sim` lock, never the pinned base device. Tests use fakes, never a real `xctrace`.
  The acceptance task runs with no worker, gate or mutate on the machine.
- **Fixtures.** Captured from real `xcrun xctrace record` / `export --xpath`, `footprint -j`, `xcresulttool` and
  `leaks` runs against `examples/SampleApp` on the Simulator, by a script under `plugin/gate/Fixtures/profile/` (or
  `Fixtures/xcresult/`) that the README row names. Raw `xcodebuild` goes through a script, as the xcresult captures do.
  Paths become `/REPO`, UDIDs `CLONE-UDID`, PIDs `PID`.
- **Generic harness.** No task names an app shape, practice prompt or preset value beyond the template's. SampleApp's
  spans and tests are plain examples.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `R/` = `plugin/gate/Sources/SwiftGateRules/`,
  `S/` = `plugin/gate/Sources/SwiftGateTestSupport/`, `TD/` `TA/` `TC/` `TR/` =
  `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI,Rules}Tests/`, `F/` = `plugin/gate/Tests/Fixtures/`,
  `FP/` = `plugin/gate/Fixtures/profile/`, `P/` = `plugin/`, `SA/` = `examples/SampleApp/`.

### Merge points (hot files)

| File | Edited only by |
|---|---|
| `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift` | `profile-measures-launch-at-head`, then `leaks-counts-weak-reference-tests`. Sub-project 3's `sim-hold-keeps-a-simulator-slot` also registers a group: whichever merges second rebases |
| `C/Commands/ProfileCommand.swift` | `profile-measures-launch-at-head`, then `profile-base-compares-interleaved-runs`, then `profile-scenarios-replay-flows`, then `profile-calibrate-records-noise` (1 per wave) |
| `C/ProfileRun.swift`, `C/Commands/ProfileOptions.swift` | `profile-measures-launch-at-head`, then `profile-base-compares-interleaved-runs`, then `profile-scenarios-replay-flows`, then `profile-budget-stops-and-names-skipped-scenarios` |
| `C/Commands/LeaksCommand.swift` | `leaks-counts-weak-reference-tests`, then `leaks-host-mode-reports-unavailable` |
| `plugin/docs/standards.md` rule id index | at most 1 task per wave per subsection: a new "Profiling (`profile`)" (`profile-measures-launch-at-head`, then `profile-base-compares-interleaved-runs`, then `profile-scenarios-replay-flows`, then `profile-budget-stops-and-names-skipped-scenarios`), and a new "Leak evidence (`leaks`)" placed before it (`leaks-counts-weak-reference-tests`, then `leaks-host-mode-reports-unavailable`) |
| `F/README.md` | `xctrace-recorder-records-and-exports-tables`, `flow-driver-replays-a-flow-while-recording`, `xctmetric-results-read-from-xcresult`, `host-leaks-adapter-reads-leaks-output` (different waves) |
| `A/Xcodebuild.swift`, `S/FakeSimulator.swift` (`FakeXcodebuild`, `FakeXcresultReader`) | `profile-sides-build-base-and-head`, then `flow-driver-replays-a-flow-while-recording`, then `xctmetric-results-read-from-xcresult` |
| `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `D/Build/BuildPreset.swift`, `A/Config/ConfigDecoding.swift`, `P/templates/swiftgate.toml` | `profile-config-declares-budget-leaks-and-presets`. Sub-project 3's `config-declares-scenarios-qa-and-sim-qa` and `bootstrap-stamps-a-live-scenario` edit the same files: whichever merges second rebases |
| `SA/App/SampleApp.swift` | `sample-app-spans-through-a-tracing-client`. Sub-project 3's `sample-app-selects-a-scenario-by-launch-argument` edits it too: whichever merges second rebases |
| `SA/SampleApp.xcodeproj/project.pbxproj` | `sample-app-spans-through-a-tracing-client` (new files elsewhere sit in synchronized groups) |
| `SA/Packages/CounterFeature/` | `sample-app-spans-through-a-tracing-client`, then `leaks-counts-weak-reference-tests` (its tests only) |
| `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/validate/SKILL.md`, `P/skills/sprint/SKILL.md`, `P/skills/ship/SKILL.md`, `tests/skill_commands_test.mjs` | `validate-runs-leaks-and-profile`, after sub-project 3's `callers-run-simulator-qa` |

### Risks

- **Load corrupts timing.** Numbers taken beside workers are noise. `profile` marks such runs `noisy` and keeps them
  out of history, but only the acceptance run's numbers matter, and it runs alone.
- **`xctrace` export drift.** The parsers read Xcode 26.2's table schemas. The Xcode pin moving is a recapture of
  every `F/Profile/` fixture (§11), and the parsers fail naming the table and column, never with an empty result.
- **Trace size.** App Launch traces reached 73 MB in the survey. The run deletes them after export; a crash between
  record and export leaves one, which `gc` doesn't know yet. The acceptance task checks nothing is left.
- **Parallel sub-projects.** Config, `SwiftGate.swift`, `SampleApp.swift` and the skill files are shared with
  sub-project 3 (Merge points). Rebase, don't merge the other plan's branch into a task branch.
- **Skill routing.** `validate-runs-leaks-and-profile` edits skill steps, not descriptions. Tell the evals session
  before it merges anyway.

## Wave map

| Wave | Tasks | Needs sub-project 3 | Why |
|---|---|---|---|
| 1 | `profile-report-judges-base-against-head`, `xctrace-recorder-records-and-exports-tables`, `sample-app-spans-through-a-tracing-client` | no | independent foundations: the pure report and statistics, the recorder and its fixtures, the example app's spans |
| 2 | `trace-tables-parse-launch-cpu-hangs-and-memory`, `profile-config-declares-budget-leaks-and-presets`, `profile-sides-build-base-and-head` | no | the parsers need the captured tables; config and the builds need nothing |
| 3 | `flow-driver-replays-a-flow-while-recording`, `profile-waits-for-a-quiet-machine`, `profile-picks-flows-the-diff-reaches` | no | the flow driver needs the builds, the recorder and SampleApp's spans; the picker needs `[[flows]] modules` |
| 4 | `profile-measures-launch-at-head`, `span-metrics-read-signpost-intervals`, `profile-history-sets-noise-bands` | no | the first command lands with launch, its first passing input; spans need the flow capture |
| 5 | `profile-base-compares-interleaved-runs`, `leaks-counts-weak-reference-tests`, `xctmetric-results-read-from-xcresult` | no | `--base` needs the command and history; `leaks` needs `leak_check` |
| 6 | `profile-scenarios-replay-flows`, `host-leaks-adapter-reads-leaks-output` | no | flows need the driver, picker, spans and XCTMetric reader |
| 7 | `profile-budget-stops-and-names-skipped-scenarios`, `leaks-host-mode-reports-unavailable` | no | the budget has several scenarios to stop; host mode needs the adapter |
| 8 | `profile-calibrate-records-noise`, `validate-runs-leaks-and-profile` | the second: `callers-run-simulator-qa` | calibrate covers flows; the callers run after sub-project 3's QA step |
| 9 | `profiling-acceptance-on-sample-app` | yes: `sample-app-selects-a-scenario-by-launch-argument`, and wave 8 | attended-style; the orchestrator runs it unattended |

If sub-project 3 hasn't merged `callers-run-simulator-qa` when wave 7 merges, wave 8 runs `profile-calibrate-records-noise`
alone and `validate-runs-leaks-and-profile` waits.

### `profile-report-judges-base-against-head`
- Deps: none · Gate: push · Model: opus · estLines: 360
- Writes: `D/Profile/ProfileReport.swift`, `D/Profile/ProfileStatistics.swift`, `TD/ProfileStatisticsTests.swift`, `TD/ProfileReportTests.swift`
- Does: §5.1, §6, §10, and Decisions "Verdicts". `ProfileStatistics.median(_:)` (mean of the middle 2 for an even count) and `mad(_:)`; `ProfileStatistics.judge(base:head:bandPct:) -> MetricJudgement` with `delta_pct` and a closed `ProfileVerdict` (`report`, `within-band`, `regressed`, `improved`). `ProfileReport` is schema 1, `Codable` with the §5.1 keys plus `load` (`{start, end}`) and `noisy` (§10): `base` and `band_pct` are optionals that encode as `null`, an unknown key or verdict fails decoding naming itself, and `schema` other than 1 fails.
- Tests: medians of odd and even counts, and a MAD a single outlier doesn't move (catches a mean). A 22% rise with no band is `regressed` and a 9% rise is `report` (catches an off-by-one at the 10% fallback). A 22% rise within a 30% band is `within-band`. A base of 0 hangs with 1 head hang is `regressed` with `delta_pct == nil` (catches a divide by 0). A report with verdict `slower` fails decoding naming it. A head-only report encodes `"base": null`, never `""` or `0`.

### `xctrace-recorder-records-and-exports-tables`
- Deps: none · Gate: push · Model: opus · estLines: 440
- Writes: `A/Profile/TraceRecorder.swift` (protocol, `XctraceRecorder`), `A/Profile/FootprintSampler.swift`, `A/Profile/ProfileToolError.swift`, `S/FakeTraceRecorder.swift`, `TA/XctraceRecorderTests.swift`, `TA/FootprintSamplerTests.swift`, `FP/capture.sh`, `F/Profile/` (captured), `F/README.md`
- Does: §3.1, §3.2. `TraceRecorder.record(template:instruments:device:target:timeLimit:output:)` with `target` a closed enum (`.launch(appPath:arguments:)`, `.allProcesses`), and `export(trace:xpath:)` returning the raw XML bytes unmodified; `FootprintSampler.sample(pid:)` over `footprint -p <pid> -j`. Every call goes through `ProcessRunner` with a deadline; a non-zero exit is a `ProfileToolError` naming the command and stderr's first line. Capture (`FP/capture.sh`, foreground, 1 created device under the `sim` lock): build SampleApp through `swiftgate check --tier fast --app-build`, install it, record App Launch (`--launch`) and Time Profiler with `--instrument Hangs --launch --time-limit 5s`, export `--toc` and each §3.2 table by a narrow `--xpath` (`life-cycle-period`, `time-profile`, `potential-hangs`, `hang-risks`), `footprint -j` of the running app, then the hang branch (Decisions) for a non-empty `potential-hangs`, a record with an unknown template, and an export whose xpath matches nothing. The README records each command, the Xcode build and whether any permission prompt appeared.
- Tests: `export` hands back the fixture's bytes unchanged (catches a recorder rewriting evidence). The unknown-template capture is a `ProfileToolError` naming `xctrace record` and its first stderr line, never an empty trace. `.launch` passes `--launch -- <app>` and `.allProcesses` passes `--all-processes`, each with `--device <udid>` (catches a recording of the host Mac). A deadline passing kills the process and names the command. `footprint`'s captured JSON decodes through the sampler.

### `sample-app-spans-through-a-tracing-client`
- Deps: none · Gate: ready · Model: opus · estLines: 380
- Writes: `SA/Packages/TracingClient/` (`TracingClient`, `TracingClientLive`, tests), `SA/Packages/CounterFeature/Package.swift`, `SA/Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift`, `SA/Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift`, `SA/App/SampleApp.swift` (links `TracingClientLive`), `SA/SampleApp.xcodeproj/project.pbxproj`
- Does: §4 spans, standards O2 and O3. A client pair shaped like `LogClient`: `TracingClient.withSpan(_ name: StaticString, _ body:)`, a test value that records span names, and a live value in `TracingClientLive` mapping each span to an `OSSignposter` interval. `CounterFeature` spans `counter.increment`, `counter.decrement` and `counter.fact` (the fact request's effect). The app links the live module; no other file touches `OSSignposter`.
- Tests: the reducer test for increment records exactly `["counter.increment"]` on the test client (catches a span left off an action). The fact effect's span closes after a failed request as well as a successful one (catches an interval left open on the error path). The live module's test runs a span through a real `OSSignposter` and returns the body's value. `arch` and `lint` pass on SampleApp (`obs.direct-signposter` holds outside the live module).

### `trace-tables-parse-launch-cpu-hangs-and-memory`
- Deps: xctrace-recorder-records-and-exports-tables, profile-report-judges-base-against-head · Gate: push · Model: opus · estLines: 400
- Writes: `D/Profile/TraceTables.swift`, `D/Profile/FootprintSample.swift`, `TD/TraceTablesTests.swift`, `TD/FootprintSampleTests.swift`
- Does: §3.2, §4, pure. From the captured XML: `launch.duration` (ms) from `life-cycle-period`; `cpu.total` (sample count × interval) and `cpu.top` (10 heaviest symbols by self time) from `time-profile`, keeping only rows whose process is the given executable; `hangs.count` and `hangs.longest` from `potential-hangs`; `memory.peak` (MB) from `phys_footprint_peak`. xctrace's `id`/`ref` row sharing is resolved, not skipped. A missing table or column is a typed error naming it.
- Tests: the launch fixture gives 1 positive `launch.duration` (catches a unit slip, s read as ms). `cpu.top` from the fixture is sorted by self time with at most 10 entries, and rows from another process are left out (catches CPU from `launchd_sim` counted as the app's). A `ref=` row takes its referenced value (catches blank symbols). The hang fixture gives `hangs.count >= 1` and the clean one 0. A table missing its duration column fails naming it, never 0.

### `profile-config-declares-budget-leaks-and-presets`
- Deps: none · Gate: push · Model: opus · estLines: 260
- Writes: `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `D/Build/BuildPreset.swift`, `A/Config/ConfigDecoding.swift`, `P/templates/swiftgate.toml` (`profiling` in each preset, a commented `[profile]` block), their tests
- Does: §9, §10, §11, as Decisions sets them. `[profile] budget_min` (default 6, range 1...60) and `leak_check` (closed `LeakCheckMode`: `xctest` \| `host`, default `xctest`); `[[flows]] modules` (optional, non-empty module names when present); a required preset key `profiling`, a closed enum `base` \| `off`. Every failure is a `ConfigIssue` naming the key.
- Tests: a preset without `profiling` fails naming `build.presets.<name>.profiling` (catches a silent default). `leak_check = "valgrind"` fails naming the allowed values. `budget_min = 0` fails `outOfRange`. `modules = []` fails; an absent `modules` decodes as `nil`, not `[]` (pitfall 2). The template's presets decode with `default` at `base` and `interview` at `off` (catches a template that no longer loads).

### `profile-sides-build-base-and-head`
- Deps: none · Gate: push · Model: opus · estLines: 380
- Writes: `A/Profile/ProfileSides.swift`, `A/Xcodebuild.swift` (`buildForTesting`), `S/FakeSimulator.swift` (`FakeXcodebuild`), `D/Profile/ProfileBuildRequest.swift`, `D/Profile/RunSchedule.swift`, their tests
- Does: §6. `ProfileBuildRequest` is a closed argument list like `AppBuild.Request`: `build-for-testing` of the app scheme, `-skipMacroValidation`, `-onlyUsePackageVersionsFromResolvedFile`, and a derived-data path per side under the run directory. `ProfileSides` checks the base ref out in a registered scratch worktree (`ScratchWorktrees`), builds each side, and returns each side's app path, `.xctestrun` path and executable name; the scratch tree goes whether the build passes, fails or is cancelled. `RunSchedule.interleaved(runs:sides:)` is pure: base, head, base, head…, each step an install of the side it then records (Decisions).
- Tests: the 2 sides' derived-data paths differ and both requests carry `-skipMacroValidation` (catches the survey's fresh-path failure). A failed base build throws naming its log and leaves no scratch tree (catches a leaked worktree). The schedule for 3 runs is `b h b h b h`, each preceded by that side's install, and a head-only schedule has no base step. The executable name comes from the built app's `Info.plist`, not the scheme name.

### `flow-driver-replays-a-flow-while-recording`
- Deps: profile-sides-build-base-and-head, xctrace-recorder-records-and-exports-tables, sample-app-spans-through-a-tracing-client · Gate: push · Model: opus · estLines: 440
- Writes: `A/Profile/FlowDriver.swift` (protocol, live), `A/Xcodebuild.swift` (`testWithoutBuilding`), `S/FakeSimulator.swift` (`FakeXcodebuild`), `S/FakeFlowDriver.swift`, `R/Profile/FlowTestDiscovery.swift`, `TA/FlowDriverTests.swift`, `TR/FlowTestDiscoveryTests.swift`, `FP/capture-flow.sh`, `F/Profile/flow/` (captured), `F/README.md`
- Does: §8, and Decisions "How a flow is recorded". `FlowTestDiscovery` lists a flow's UI test methods from the app's UI test sources through `TestFunction` and `FlowCoverage.flow(forTest:flows:)`, splitting out the methods that call `measure(metrics:`. `FlowDriver.replay(flow:side:device:)` runs `xcodebuild test-without-building -xctestrun <side> -destination id=<udid> -only-testing <ids>` while the recorder records `--all-processes`, stops the recording when the test exits, and reports the test's exit. A flow with no UI test is a typed "no driver" result naming the flow. Capture (`FP/capture-flow.sh`, foreground): SampleApp's `counter` flow on a created device, then `export --xpath` of `time-profile` and `os-signpost-interval`.
- Tests: `counter` maps to `CounterFlowUITests/testIncrementAndDecrementUpdateTheDisplayedCount()`, and a method calling `measure(metrics:` lands in the measure list, not the replay list (catches a performance test recorded as a flow). The request carries every discovered id as `-only-testing` and the clone's UDID (catches a replay of the whole suite). The recording stops after the test exits and before export, also when the test fails. A flow with no test is "no driver", never an empty success. The captured `os-signpost-interval` holds a `counter.increment` row.

### `profile-waits-for-a-quiet-machine`
- Deps: profile-report-judges-base-against-head · Gate: push · Model: opus · estLines: 300
- Writes: `A/Profile/QuietMachine.swift`, `D/Profile/LoadWindow.swift`, `TA/QuietMachineTests.swift`, `TD/LoadWindowTests.swift`
- Does: §10, and Decisions "A quiet machine". `QuietMachine.acquire(deadline:)` takes the capacity-1 `profile` lock, then waits while `pgrep -f` finds a mutate-self or ready-tier process, and returns a lease; past the deadline it throws naming the PIDs. `LoadWindow` samples the 1-minute load average at start and end and says `noisy` when the start exceeds the active core count.
- Tests: with a real `FileCountingLock` in a temp directory, a second acquirer waits until the first releases (§10 "1 profile run at a time", catches 2 profiles at once). A fake `pgrep` reporting a ready tier holds the wait until it's gone; with it never gone, the deadline error names its PID. A holder of the `sim` lock doesn't hold `profile`, and the reverse (pitfall 5 cross case). Load 20 on 16 cores is `noisy`, and 12 isn't. The `pgrep` patterns keep their bracket, so the waiter never matches its own command line.

### `profile-picks-flows-the-diff-reaches`
- Deps: profile-config-declares-budget-leaks-and-presets · Gate: push · Model: opus · estLines: 220
- Writes: `D/Profile/FlowPicker.swift`, `TD/FlowPickerTests.swift`
- Does: §8, as Decisions sets it. Pure: from `impact`'s changed modules, the module graph and `[[flows]]`, the flows reached, capped at 3 in declaration order, and the reached ones left out, named. A flow with `modules` is reached when they meet the changed modules; one without is reached by a change to any module the app scheme links. No changed module reaches no flow.
- Tests: 4 reached flows pick the first 3 and name the fourth as skipped (catches an uncapped pick). A flow scoped to `CounterFeature` isn't reached by a `GameEngine` change, and an unscoped flow is. A docs-only diff picks nothing.

### `profile-measures-launch-at-head`
- Deps: trace-tables-parse-launch-cpu-hangs-and-memory, profile-config-declares-budget-leaks-and-presets, profile-sides-build-base-and-head, profile-waits-for-a-quiet-machine · Gate: push · Model: opus · estLines: 480
- Writes: `C/Commands/ProfileCommand.swift`, `C/Commands/ProfileOptions.swift`, `C/ProfileRun.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `A/Profile/ProfileRunStore.swift`, `TC/ProfileCommandTests.swift`, `plugin/docs/standards.md` (new "Profiling (`profile`)" subsection)
- Does: §5 `swiftgate profile [--runs <n>] [--keep-traces] [--json]` with no `--base`: head alone, launch scenario only. Acquire the quiet machine, take a clone (`SimulatorClones.withClone`), build head, then per run install and record the 2 launch recordings (Decisions), sample `footprint`, export, parse. Write `.harness/runs/<id>/profile.json` (schema 1, `host` from `sysctl hw.model`, `Xcodebuild.version()` and `[simulator]`), exported evidence under `profile/`, a history line like any run; delete each `.trace` unless `--keep-traces`. Print 1 line per scenario, under 1 KB. Findings `profile.capture-failed` (scenario, template, stderr's first line), `profile.no-evidence`, `profile.summary`, all notes. Exit 0, or 2 when it couldn't build, get a clone or a quiet machine.
- Tests: with fakes, 3 runs give 6 recordings and a `profile.json` whose metrics carry `"base": null` and verdict `report`, decoded with an unknown key rejected. A failed App Launch record is `profile.capture-failed` naming the template, and the other metrics still report (catches 1 failure blanking the run). No `.trace` is left without `--keep-traces`, and one is with it. A build failure exits 2. The printed summary is under 1 KB. Each rule id is in the index, and `profile` is registered.

### `span-metrics-read-signpost-intervals`
- Deps: flow-driver-replays-a-flow-while-recording, profile-report-judges-base-against-head · Gate: push · Model: opus · estLines: 240
- Writes: `D/Profile/SpanIntervals.swift`, `TD/SpanIntervalsTests.swift`
- Does: §4 `span.<name>`, pure. From the captured `os-signpost-interval` table, the intervals whose process is the app's executable, grouped by name, each a list of durations in ms whose median becomes `span.<name>`. Intervals from system subsystems are left out. Zero app intervals is an explicit empty result the command turns into `profile.no-spans`.
- Tests: the flow fixture yields `span.counter.increment` with 2 durations, from the flow's 2 taps (catches merging names). A system interval in the same table isn't a span (catches UIKit's signposts counted as the app's). An interval with no end row is left out and counted, never read as 0 ms.

### `profile-history-sets-noise-bands`
- Deps: profile-report-judges-base-against-head · Gate: push · Model: opus · estLines: 360
- Writes: `D/Profile/HostKey.swift`, `D/Profile/ProfileHistoryLine.swift`, `D/Profile/NoiseBand.swift`, `A/Profile/ProfileHistoryStore.swift`, their tests
- Does: §7, and Decisions "A/A samples". `HostKey` hashes the Mac model, Xcode version, simulator device and OS. A history line (`schema` 1, `hostKey`, `runID`, `kind` `aa` \| `ab`, `metric`, `scenario`, side medians, `delta_pct`, `at`) appends to `$(git rev-parse --git-common-dir)/swift-harness/profile/<host-key>.jsonl` under a lock with fsync. `NoiseBand.band(for:in:)` is the 95th percentile of `|delta_pct|` over `aa` lines once there are 20 from at least 5 run ids, else `nil`. A line that doesn't decode is skipped and named in a note (pitfall 4). Noisy runs are never written.
- Tests: 19 A/A samples give no band, and 20 from 4 run ids give none (catches a band from 1 long session). 20 from 5 run ids give the 95th percentile. `ab` lines never feed a band. A different Xcode version gives a different key and file (catches bands shared across hosts). A corrupt line is named, not dropped silently. The store is tested against a temp repository's common dir, never this checkout's (pitfall 7).

### `profile-base-compares-interleaved-runs`
- Deps: profile-measures-launch-at-head, profile-history-sets-noise-bands · Gate: push · Model: opus · estLines: 420
- Writes: `C/Commands/ProfileCommand.swift` (`--base`), `C/Commands/ProfileOptions.swift`, `C/ProfileRun.swift`, `TC/ProfileBaseTests.swift`, `plugin/docs/standards.md` (1 "Profiling" row), `docs/designs/2026-09-28-agentic-profiling-design.md` (§6's install sentence, Decisions)
- Does: §5 `profile --base <ref>`, §6, §7. Builds both sides, runs the interleaved schedule, and judges each metric with its band from history (`band_pct`, `null` until set). A metric whose verdict is `regressed` adds a `profile.regressed` note naming the metric, both medians and the band or the 10% fallback. The CLI prints a line per metric whose delta passes 10%. Appends `ab` lines unless the run was noisy. Still exit 0 on a regression.
- Tests: the fake recorder sees base, head, base, head in order (catches all base runs first). A 22% `launch.duration` rise with no band is `regressed` with a `profile.regressed` note, and exit 0 (catches a report-only gate that blocks). With 20 A/A lines setting a 30% band the same rise is `within-band` and no note. A noisy run writes no history line. The id is in the index.

### `leaks-counts-weak-reference-tests`
- Deps: profile-config-declares-budget-leaks-and-presets · Gate: push · Model: opus · estLines: 400
- Writes: `R/Profile/WeakReferenceTestDiscovery.swift`, `C/Commands/LeaksCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `TR/WeakReferenceTestDiscoveryTests.swift`, `TC/LeaksCommandTests.swift`, `P/docs/testing-playbook.md` (the weak-reference pattern), `SA/Packages/CounterFeature/Tests/CounterCoreTests/` (a store-release test), `plugin/docs/standards.md` (new "Leak evidence (`leaks`)" subsection)
- Does: §9 default mode. `swiftgate leaks [--mode xctest|host]`, defaulting to `[profile] leak_check`. In `xctest` mode it finds weak-reference tests (Decisions), runs them through the T1 host runner filtered to them, and reports `leaks.summary` (found, passed), `leaks.none-found`, or `leaks.check-failed` naming the test, all notes. The playbook gains the pattern for stores and live clients; SampleApp gains 1 test that a released `Store` of `CounterFeature` leaves its weak reference `nil`. Until host mode lands, `--mode` accepts `xctest` only, and `host` fails as an unknown value naming the allowed one.
- Tests: a test with `weak var` and `#expect(x == nil)` is found; one with a `weak var` and no nil assertion isn't (catches counting any weak variable). SampleApp's store test passes, and with a retain cycle added to it on a scratch copy it fails (pitfall 6). A repository with none gets `leaks.none-found`, never a quiet `GREEN`. Each id is in the index, and `leaks` is registered.

### `xctmetric-results-read-from-xcresult`
- Deps: profile-report-judges-base-against-head · Gate: ready · Model: opus · estLines: 360
- Writes: `SA/UITests/CounterFlowPerformanceUITests.swift`, `plugin/gate/Fixtures/xcresult/capture-metrics.sh`, `F/Xcresult/metrics.*` (captured), `F/README.md`, `A/XcresultReader.swift` (`readMetrics`), `S/FakeSimulator.swift` (`FakeXcresultReader`), `D/Profile/XCTMetricResults.swift`, their tests
- Does: §7, §8 XCTMetric tests, and Decisions "XCTMetric ids and runs". SampleApp gains 1 UI test in the `counter` flow that calls `measure(metrics: [XCTClockMetric(), XCTCPUMetric(application:)])` over 10 increment taps. `readMetrics` runs `xcrun xcresulttool get test-results metrics --path <bundle>`; `XCTMetricResults` parses each test's metric identifier, unit and iterations into `xctmetric.<Class>.<method>.<identifier>` with the median of its iterations. Capture: `swiftgate test --tier t3` on SampleApp, then the metrics subcommand, as `capture-ui.sh` does.
- Tests: the captured bundle yields the clock metric of `CounterFlowPerformanceUITests` in its own unit with 5 iterations (catches iterations averaged by Xcode read as 1 value). A bundle with no measure block yields none, not an error. An unknown unit fails naming it. `t3.max-flows` and `t3.unmapped-flow` still pass on SampleApp with the new test (catches a performance test outside a flow).

### `profile-scenarios-replay-flows`
- Deps: flow-driver-replays-a-flow-while-recording, profile-picks-flows-the-diff-reaches, span-metrics-read-signpost-intervals, profile-base-compares-interleaved-runs, xctmetric-results-read-from-xcresult · Gate: push · Model: opus · estLines: 440
- Writes: `C/Commands/ProfileCommand.swift` (`--scenario`), `C/ProfileRun.swift`, `TC/ProfileFlowTests.swift`, `plugin/docs/standards.md` (1 "Profiling" row)
- Does: §8. Scenarios are launch plus the `--scenario` flows, or with `--base` and no `--scenario` the flows `FlowPicker` reaches. Per run, each flow replays under the recorder with `footprint` polling, yielding `cpu.*`, `hangs.*`, `memory.peak` and `span.*`; then 1 XCTMetric pass per side for the flows' measure tests. `profile.no-spans` when a flow's recordings hold no app interval; `profile.no-evidence` naming the flow when it has no driver, while launch and XCTMetric still run.
- Tests: `--scenario counter` with fakes records the flow on both sides and reports `span.counter.increment` (catches a flow scenario that records nothing). A flow with no UI test is `profile.no-evidence` naming it and launch still reports. A flow run with no signpost rows is `profile.no-spans`. The XCTMetric pass runs once per side, base first. The id is in the index.

### `host-leaks-adapter-reads-leaks-output`
- Deps: none · Gate: push · Model: opus · estLines: 300
- Writes: `A/Profile/HostLeaks.swift`, `D/Profile/LeaksOutput.swift`, `FP/capture-leaks.sh`, `FP/leaks-probe/` (a macOS probe with a deliberate retain cycle), `F/Profile/leaks/` (captured), `F/README.md`, their tests
- Does: §9 override, and Decisions "Host `leaks` success output". `HostLeaks.check(pid:graph:)` runs `leaks <pid> --outputGraph <path>`; `LeaksOutput` parses the leak count and root types from its text. Capture: the real failure on a SampleApp pid in a created Simulator device, and a success on the host probe.
- Tests: the captured Simulator failure is an error carrying stderr's first line, never a count of 0 (catches a failure read as clean). The probe capture parses to its known leak count and root type. Output with no summary line fails naming it.

### `profile-budget-stops-and-names-skipped-scenarios`
- Deps: profile-scenarios-replay-flows · Gate: push · Model: opus · estLines: 240
- Writes: `C/ProfileRun.swift`, `C/Commands/ProfileOptions.swift` (`--budget-min`), `D/Profile/ProfileBudget.swift`, `TC/ProfileBudgetTests.swift`, `plugin/docs/standards.md` (1 "Profiling" row)
- Does: §10 budget. `--budget-min` or `[profile] budget_min` (6) bounds the wall time, the quiet-machine wait included. Before each recording the run checks the budget with an injected clock; past it, it stops, reports what it measured, and adds `profile.budget-exceeded` naming each scenario and run left unmeasured.
- Tests: with an injected clock passing the budget after launch, the flow isn't recorded and the note names it (catches a run past its budget). The launch metrics measured before the stop are still in `profile.json`. `--budget-min 2` overrides the config. The id is in the index.

### `leaks-host-mode-reports-unavailable`
- Deps: leaks-counts-weak-reference-tests, host-leaks-adapter-reads-leaks-output · Gate: push · Model: opus · estLines: 260
- Writes: `C/Commands/LeaksCommand.swift`, `C/LeaksHostRun.swift`, `TC/LeaksHostTests.swift`, `plugin/docs/standards.md` (2 "Leak evidence" rows)
- Does: §9 host mode. On a clone: build and install head, launch with `simctl launch`, wait 5 s, run `HostLeaks.check`, terminate. A failure is `leaks.host-unavailable` naming the error; leaks found are `leaks.host-found` naming root types; the count goes in `leaks.summary`. All notes.
- Tests: the captured Simulator failure gives `leaks.host-unavailable` with its first stderr line and exit 0, never a quiet pass (catches the survey's failure read as 0 leaks). The probe's parsed output gives `leaks.host-found` naming its root type. The app is terminated and the clone released after a failure too. Each id is in the index.

### `profile-calibrate-records-noise`
- Deps: profile-base-compares-interleaved-runs, profile-scenarios-replay-flows, profile-history-sets-noise-bands · Gate: push · Model: opus · estLines: 260
- Writes: `C/Commands/ProfileCalibrateCommand.swift`, `C/Commands/ProfileCommand.swift` (subcommand list), `TC/ProfileCalibrateTests.swift`
- Does: §5 `profile calibrate [--scenario <name>]... [--runs <n>]`. Builds head once and runs it as both sides of the interleaved schedule, reports like `--base` with verdicts, and appends 1 `aa` line per metric unless noisy. Once a metric has a band, the next `--base` run shows `band_pct`.
- Tests: calibrate builds once, not twice (catches an A/A run that builds a scratch base). It writes `aa` lines and `--base` writes `ab`. After 20 calibrate runs over 5 run ids on fakes, `profile --base` reports a non-null `band_pct`. A noisy calibrate appends nothing.

### `validate-runs-leaks-and-profile`
- Deps: leaks-host-mode-reports-unavailable, profile-budget-stops-and-names-skipped-scenarios, profile-calibrate-records-noise, sub-project 3's `callers-run-simulator-qa` · Gate: push · Model: opus · estLines: 220
- Writes: `P/skills/validate/SKILL.md`, `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/sprint/SKILL.md`, `P/skills/ship/SKILL.md`, `tests/skill_commands_test.mjs` (their rows), `plugin/docs/standards.md` (§6 U4's "Enforced by" line)
- Does: §11. After sub-project 3's QA step, the build's `validate` stage, ship's final step and sprint's finish run `swiftgate leaks`, then `swiftgate profile --base <merge base>`, when the preset's `profiling = "base"`, and print `validate: profiling off` otherwise. `/swift-validate` adds "Profiling" and "Leaks" rows from `profile.json` and the `leaks` summary, lists every `profile.regressed` note, and lists a skipped step under "Not run". Profiling never fails the stage (§7). U4 names `span.*` metrics as the Simulator proxy, still review-enforced.
- Tests: the contract test finds each caller naming `swiftgate leaks`, `swiftgate profile --base` and the `profiling` key, after the QA step. The validate block's "Profiling" row reads keys `profile.json` has (`scenarios`, `verdict`, `delta_pct`). No caller treats a `profile` exit 0 with `regressed` as a failure.

### `profiling-acceptance-on-sample-app`
- Deps: every task above; sub-project 3's `sample-app-selects-a-scenario-by-launch-argument` · Gate: ready · Model: opus · estLines: 80
- Writes: `docs/e2e-report.md` (an "Agentic profiling" section)
- Does: attended-style; the orchestrator runs it unattended under the user's delegation, with no worker, gate or mutate on the machine. From a clean checkout of merged `main`, in `examples/SampleApp`: `profile calibrate --runs 3` 5 times; `profile --base main` on a no-change branch; then on a local, never-merged branch that adds a fixed CPU cost inside the `counter.increment` span, `profile --base main --scenario counter`, which covers the `fixed-fact` fact flow network-free; `leaks`, then `leaks --mode host`; the build's `validate` stage on that branch.
- Tests: the regression branch reports `span.counter.increment` `regressed` with a `profile.regressed` note, and exit 0. The no-change run has no `regressed` span. `span.counter.fact` is measured. `leaks` reports at least 1 weak-reference test passed. Each `profile` run fits its 6 min budget or names what it skipped. No `.trace`, clone or scratch worktree survives. The report records wall time per command, run ids, load at start and end, every finding and the host key.
