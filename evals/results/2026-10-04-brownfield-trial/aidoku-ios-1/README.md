# Brownfield trial: Aidoku/Aidoku, the first iOS app

This trial runs the brownfield profile (design §14) on an iOS app for the first time, to prove the Xcode path end to
end. The repository is `Aidoku/Aidoku` at `3091ef26e593d303e34afed70bc8c5997c105f80`: a SwiftUI and UIKit app with an
Xcode project, 14 SwiftPM dependencies and a Swift Testing target. [The trial repositories page](../../../../docs/handoffs/brownfield-trial-repos.md#ios-trial)
says why this trial uses it. The clone is fresh, made on 2026-10-04 at `trials/aidoku-ios-1`. The spec asks for a
download queue summary row: a value type, a SwiftUI row with an accessibility identifier, and a unit test. The
harness ran from this branch's `plugin/bin/swiftgate`, which is main at `99f847d0`, built as source hash
`18477dbc3f8e90ef`.

**Verdict: the one-shot run PASSES, in 29.6 minutes for $2.43, inside the 45-minute expectation.** `spec.md` went to
the plan branch `swift-harness/spec` at `835ba9da` with all 3 tasks done. The contract went through `plan import
--contract`, then came 2 merges, each with a GREEN `merge` gate that built the app, ran its tests on the simulator and
proved the new test. `final` is GREEN. The run asked the user nothing and raised no halt.

It passed because the orchestrator repaired discovery. Discover's `xcodebuild` commands omit
`-skipPackagePluginValidation`, and Aidoku builds with the SwiftLint build-tool plugin, so the first warm-up's build
and test both failed in 8 s. The orchestrator read the warm-up log, added the flag with `discover --apply --set`,
re-ran the warm-up and went on. The design allows this (§11.2: Opus fixes a failing guess), but a repository with
any package plugin will hit it (finding 1). Before that repair, 2 gates were GREEN while compiling nothing
(findings 2 and 3).

The `slice` p95 fails: 120.3 s in steady state. Each new worktree builds the app cold into its own DerivedData,
since the gate never places DerivedData (finding 5). Warm slices took 4.6 to 5.6 s. Every slice in the run ran at a
1-minute load above 100, so every slice time here is load-affected.

## Measures

| Measure | Value | Bar | Result | Source |
|---|---|---|---|---|
| Clone to first gate | 3.44 s. `git clone` and the reset to the pinned commit took 2.70 s from 17:20:38.247Z; `discover --apply` took 0.34 s (`discover.run` `ms` 207); `slice` on an empty commit took 0.41 s | under 3 min | PASS | `gate.run` `D4DF1725-…`, run `20261004T172041Z-174d70b3`, at 17:20:41.687Z |
| Findings on untouched code, empty commit | 0 | 0 | PASS | `slice-empty.json`, `ruleCounts {}` |
| Findings on untouched code, 1-line change | 0 on code, 2 nits with no line: `area.build-only` (no warm-up yet) and `baseline.summary`. GREEN only because the baseline absorbed a failing build (finding 3). The change was 1 comment line at the end of `Aidoku/Core/Downloads/Models/Download.swift` | 0 | PASS, but vacuous on the build | `slice-one-line.json`, `gate.run` `C5500B59-…`, run `20261004T172132Z-680195a9`, 139.4 s at a load of 126 to 999 |
| `slice` p95, before the warm-up | 2 probe samples: 0.2 s and 139.4 s, so p95 is 139.4 s | 30 s or less | FAIL (load-affected, cold) | runs `20261004T172041Z-174d70b3` and `20261004T172132Z-680195a9` |
| `slice` p95, during the warm-up | 0 samples. The launch's warm-up failed in 8 s (17:25:07Z to 17:25:15Z); the orchestrator's re-run went from 17:27:08Z to 17:34:39Z at a load of 151 to 411, and no gate ran in either | 30 s or less | no data | `warmup.run` `95CB18A1-…`, `CB82E048-…`, `9FD5C39A-…`, `D359BB62-…` |
| `slice` p95, steady state | 7 in-run `slice` runs: 0.1 s (BLOCKED, `--app-build`), 1.1 s (compiled nothing, finding 2), 4.6, 5.4, 5.6, 105.0 and 120.3 s. Nearest-rank p95 is 120.3 s, with or without the first 2. The 105.0 and 120.3 s samples are the first build in a new worktree; the 3 warm ones are 4.6 to 5.6 s | 30 s or less | FAIL (load-affected: 131 to 468) | see "Slice time" |
| One-shot run | Plan branch `swift-harness/spec` at `835ba9da`: the contract and 2 merges, every `merge` gate GREEN, `final` GREEN. The report says `final: GREEN` and "Unfinished tasks: none" | `spec.md` to a plan branch, every merge and `final` GREEN, 0 human input | PASS | `gate.run` `31E8E997-…`, `command = check final`, run `20261004T175029Z-80ecc488`; `build-events.jsonl`; `run-report.txt` |
| Human input | 0. No `AskUserQuestion` call; all 59 user messages in the stream are tool results. Both turns ended with `stop_reason: end_turn`; the second started on a workflow notification | 0 | PASS | `run.jsonl` (2 `result` lines, session `25c74141-d14e-4006-bd78-24e8ae77c38a`); no `build.halt` event |
| Worker writes denied | 0 wrong denials. 2 blocks, both by design: `guard.raw-xcodebuild` on the orchestrator's own `xcodebuild` check of the fixed command, and 1 `guard.reviewer-bash` | 0 | PASS | `hook.decision` `5822C5D9-6900-405A-AE78-EA2C384BFC5E` and `C8B9DF61-DEEE-472E-A7DC-C77F18233F79` |
| Gate events name this binary | 261 of 263 events carry `source.binary.sourceHash` `18477dbc3f8e90ef`. The 2 `warmup.run` events of the warm-up `run start` spawned carry no `source` (finding 10); the re-run's 2 do | every gate event | PASS for gate events; FAIL for the spawned `warmup.run` | `events.jsonl` |
| Wall time | 1777.6 s, from launch at 17:25:07.5Z to exit at 17:54:45.2Z | 45 min | PASS (29.6 min) | `run.jsonl`, the launch script's clock |

## Every merge

| Task | Commits | Task gate | Merge | Merge gate | Review |
|---|---|---|---|---|---|
| `summary-contract` | `781be0b3` | `slice` GREEN `20261004T173730Z-e09dedfe` (105.0 s, area-build 103.6 s). 2 earlier slices didn't count: `20261004T172615Z-799c3dc7` GREEN in 1.1 s with no build (finding 2), and `20261004T172627Z-43764da1` BLOCKED on `--app-build`, an owned-profile flag | committed on the plan checkout; `plan import --contract summary-contract --contract-run 20261004T173730Z-e09dedfe` made it `done` | none of its own; the first merge gate covers it | none, as a contract |
| `summary-logic` | `8bc6626d` | `slice` GREEN `20261004T174200Z-11a8b3f1` (5.6 s) | `162450e1` at 17:42:38Z | GREEN `20261004T174242Z-c6897717` (149.9 s: build 11.2 s, test 54.9 s, prove 83.5 s, `proven`) | diff-risk `low` (0.8), so the gate only |
| `summary-row` | `f1839eb0` | `slice` GREEN `20261004T174216Z-5932bd4d` (5.4 s). Its 2 earlier slices were killed by the other worker (finding 6) | `835ba9da` at 17:45:29Z | GREEN `20261004T174531Z-4a491e54` (270.7 s: build 103.2 s, test 58.8 s, prove 107.8 s, `proven`) | diff-risk `medium` (0.55): 1 test-quality reviewer, 0 findings (finding 12) |
| `final` | the plan branch at `835ba9da` | — | — | `final` GREEN `20261004T175029Z-80ecc488` (236.7 s: build 56.4 s, test 88.6 s, prove 91.0 s); prove: 1 of 1 changed test files fails with the change's source reverted | — |

The delivered change matches the spec. `DownloadQueueSummary` is a plain value type with a clamped, zero-safe
fraction. `DownloadQueueView` shows it as the first section while the queue isn't empty, with
`.accessibilityIdentifier("download-queue-summary")`, and each chapter's bar now uses the same fraction. The English
strings file gains 1 key, and `AidokuTests/DownloadQueueSummaryTests.swift` holds 7 Swift Testing tests. The clone's
`main` is untouched, with a clean status.

## Halts

None. No `build.halt` or `build.resume` event exists, and no gate went RED after the warm-up repair.

## Slice time

The repaired warm-up measured a warm test run of 107.0 s, over the 30 s budget, so every slice after it built the
app and ran no tests. The steps run in parallel, so the build sets the time.

| Slice | Task | Time | Load | `area-lint` | `area-build` |
|---|---|---|---|---|---|
| `20261004T172615Z-799c3dc7` | contract, before the warm-up repair | 1.1 s | 422 to 447 | 0.7 s | not run (finding 2) |
| `20261004T172627Z-43764da1` | contract, `--app-build` | 0.1 s, BLOCKED | 447 to 465 | — | — |
| `20261004T173730Z-e09dedfe` | contract, plan checkout's first build | 105.0 s | 151 to 468 | 0.4 s | 103.6 s |
| `20261004T173956Z-c8bc5052` | logic, dirty tree, worktree's first build | 120.3 s | 162 to 291 | 0.3 s | 119.3 s |
| `20261004T174200Z-11a8b3f1` | logic, committed | 5.6 s | 162 to 185 | 0.2 s | 5.1 s |
| `20261004T174208Z-078b987c` | row, dirty tree | 4.6 s | 131 to 162 | 0.1 s | 4.3 s |
| `20261004T174216Z-5932bd4d` | row, committed | 5.4 s | 131 to 162 | 0.1 s | 5.0 s |

The row worker's first 2 slices, `20261004T173956Z-7dce88c3` and `20261004T174159Z-189d3fcd`, left empty run
directories and no `gate.run` event: the logic worker's `pkill` killed them (findings 6 and 7). The SwiftLint step
took 0.1 to 0.7 s on the changed files.

## Xcode behaviour

- **Discover's Xcode area.** 1 area, `Aidoku`, at the root: kind `xcode`, project `Aidoku.xcodeproj`, inclusion
  `synchronized` (`Aidoku` and `AidokuTests` are both `PBXFileSystemSynchronizedRootGroup`s), schemes `["Aidoku"]`, test globs
  `**/AidokuTests/**/*.swift`. Build and lint were `found`, test `guessed`; 207 ms. The orchestrator's `--set`
  (`discover.run` `318FE8EE-…`, `edited: 2`) added `-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO` to build
  and test. `config.toml` is the config after the run.
- **Scheme and destination.** Build: `-scheme Aidoku -destination 'generic/platform=iOS Simulator'`. Test: the same
  scheme with `-destination 'platform=iOS Simulator,name=iPhone 17'`. This machine already had an `iPhone 17`
  (`AA8B08DE-…`), a device the harness didn't create, so the pin collides with it (finding 4). The brownfield config
  has no `[simulator]` table, and no gate cloned a device of its own. `xcodebuild` ran the tests on its own
  "Clone N of iPhone 17" devices; the `iPhone 17` was shut down after the run. No step touched `bxb-sim`.
- **Target membership.** The `xcode-membership` step ran on the 2 new Swift files, `DownloadQueueSummary.swift` in
  the contract slice and `DownloadQueueSummaryTests.swift` in the logic worker's slice: GREEN in 0 to 1 ms each. On
  a synchronized project a file joins its target by its folder.
- **`xcode add-file`.** Not used, and not needed: the project is a synchronized one. Nothing told the workers it exists:
  only `xcode.file-not-in-target`'s message names it (finding 15).
- **Simulator tiers.** None of the owned profile's simulator tiers ran. The `merge` and `final` tiers ran the area's
  `xcodebuild test` on the simulator (54.9, 58.8 and 88.6 s) and prove ran it again with the source reverted. No
  slice ran tests. The test step reports no counts (`testCounts: null`), so no gate shows how many tests ran
  (finding 13).
- **DerivedData.** Every `xcodebuild` wrote to the default `~/Library/Developer/Xcode/DerivedData`, 1 directory per
  tree path: the clone, the plan checkout, 2 task worktrees, 3 prove scratch trees, the 1-line probe's merge-base
  scratch tree, and 1 whose tree I couldn't name. That came to 9 directories and 15.2 GiB, and nothing cleaned
  them. Every `gate.step` records `derivedData: "none"` (finding 5).

## Other numbers

- Cost: $2.43 (the `result` line's `total_cost_usd`). After my ingest the `agent.usage` events add up to $2.43 as
  well: the orchestrator on `claude-opus-5-5` $2.09 and the 2 build workers on `claude-sonnet-5-5` $0.34. The 2
  diff-risk calls cost another $0.02, outside the session.
- API time 287.5 s, over 2 turns of 43 and 18 steps.
- Post-run ingest: before it the events summed to $2.07, without the orchestrator's last turn. I ran `swiftgate events
  ingest --session 25c74141-… --role orchestrator --build-run 20261004T173923Z-a21597fe` after the run: `56 messages
  read, 11 new`. I exported `events.jsonl` after it.
- Warm-up, from `warmup.run` events:
  - launch: build failed in 5.2 s and test failed in 2.9 s, both `cold`, on plugin validation (`warmup.log`).
  - the orchestrator's re-run: build passed in 343.1 s and test passed in 107.0 s, both marked `warm`.
- Build lock: I held a ticket from 17:25:01Z, before launch, until the launch's warm-up exited at 17:25:15Z, then a
  second from 17:30:12Z until the re-run exited at 17:34:39Z (`lock.log`). The re-run started at 17:27:08Z, so the
  lock covered only its last 4.5 minutes.
- Load: the 1-minute load average was 67 to 477 during the run, and 126 to 999 during the probes (`uptime.log`).
  Before launch the load hit 985, with others' builds running.
- Review depth: diff-risk rated logic `low` (0.8) and row `medium` (0.55). The report's "Review fallbacks" says none.

## What happened

1. `discover --apply` found 1 Xcode area with 3 commands. The empty-commit probe was GREEN in 0.2 s; the 1-line probe
   was GREEN in 139.4 s with its failing build absorbed by the baseline.
2. `swiftgate run start spec.md` copied the spec, applied discovery, started the warm-up and launched `claude`. The
   warm-up's build and test failed on SwiftLint plugin validation within 8 s.
3. The orchestrator read the spec and the queue screen itself, with no explorers, and read the warm-up log. It made
   the plan checkout, fixed both commands with `discover --apply --set`, and wrote the contract `781be0b3`: the
   `DownloadQueueSummary` type with stub bodies.
4. Its first contract slice was GREEN in 1.1 s. It said so itself ("The slice gate passed in 1 s, which means it
   didn't compile"), tried `--app-build` (BLOCKED in this profile), re-ran `swiftgate warmup`, and gated the
   contract again: GREEN at 105.0 s with the build.
5. It wrote `PLAN.md` with 3 tasks in 2 waves and 7 assumptions, ran `plan import --contract`, `build start` and
   `build next`, and launched the 2 `build-task` workflows in parallel at 17:39:31Z.
6. Both workers ran their first slice in the same Bash call as their edits, and the 120 s default timeout moved
   both to the background. The logic worker then ran `pkill -f "swiftgate check" ; pkill xcodebuild`, which killed
   the row worker's slice. Both workers committed and returned `ready-to-merge` with GREEN committed-tree slices.
7. The orchestrator merged logic, then row, each GREEN at `merge`, and ran `final`: GREEN, with the new test proven.
   It ran `build finish`, removed a stray `.harness/tmp/out.txt` so the row worktree could go, removed the plan
   checkout and wrote the report.

## Harness findings

1. **Discover's `xcodebuild` commands omit `-skipPackagePluginValidation`.**
   - Both commands carry `-skipMacroValidation` but not the plugin flag. Any project with a build-tool plugin fails
     headless with `Validate plug-in "SwiftLintBuildToolPlugin"` before it compiles (`warmup.log`). Aidoku's own CI
     passes the flag.
   - File: `plugin/gate/Sources/SwiftGateDomain/Brownfield/Discover/Readers/XcodeReader.swift` (`proposed`, the
     `build` and `test` commands).
   - Suggested fix: add `-skipPackagePluginValidation` beside `-skipMacroValidation`. Test: a captured project with
     a `XCSwiftPackageProductDependency` on a plugin yields commands with both flags.
2. **A failed warm-up test time sets the slice budget, and a change with no test files then gates nothing.**
   - The launch's warm-up recorded `testMs: 2946` for a test step that failed. The contract slice
     `20261004T172615Z-799c3dc7` read 2.9 s as fitting the 30 s budget and chose the test path. It found no changed
     tests and was GREEN in 1.1 s with no build step and no finding, on a commit that added a type.
   - Files: `plugin/gate/Sources/SwiftGateCLI/BrownfieldSliceCheck.swift` (the `warmTestMilliseconds` closure reads
     `testMilliseconds` without the `test` step's outcome) and
     `plugin/gate/Sources/SwiftGateDomain/Brownfield/Warmup.swift` (records `testMs` for a failed run).
   - Suggested fix: only a passed test step yields a warm test time; and when the test path selects no tests, run
     the build. Test: a warm-up record with a failed 3 s test makes `slice` run `area-build`.
3. **The baseline absorbs a whole-step build failure, so a gate is GREEN while nothing compiles; and the report
   keeps the stale baseline after the command changes.**
   - The 1-line probe's `area-build` was RED, failed the same way at the merge base, and `baseline.summary` absorbed
     "Aidoku build (the whole step)": GREEN. After the `--set` repair, `run-report.txt` still lists "Baseline
     failures: Aidoku build: the whole step; Aidoku test: the whole step", which the fixed commands don't have.
   - Files: `plugin/gate/Sources/SwiftGateCLI/BrownfieldSliceCheck.swift` (the baseline step) and
     `plugin/gate/Sources/SwiftGateDomain/Brownfield/BrownfieldRunReport.swift`.
   - Suggested fix: a build that fails at the base makes the gate BLOCKED with a named reason, never GREEN; and the
     report and baseline lookup skip records whose `command` isn't the config's current one.
4. **The test destination pins a device by name that this machine already has.**
   - Discover writes `name=iPhone 17` for every iOS scheme. This machine had an `iPhone 17` the harness didn't
     create, so tests ran on clones of a user device, and parallel worktrees all target the same one. The brownfield
     config has no `[simulator]` pin, and no gate clones a device of its own.
   - File: `plugin/gate/Sources/SwiftGateDomain/Brownfield/Discover/Readers/XcodeReader.swift`
     (`destination(_:generic:)`).
   - Suggested fix: a `[simulator]` pin in the brownfield config, with the gate creating its own named device per
     clone and passing `-destination id=<udid>`, as the owned profile's simulator tiers do.
5. **The gate never places DerivedData, so every new tree builds cold.**
   - The gate computes `AreaCacheEnvironment.derivedDataSeed` and never reads it. Builds went to the default DerivedData, 1
     directory per tree path: 9 directories, 15.2 GiB, never cleaned. The first build in each worktree took 103.6
     and 119.3 s against 4.3 to 5.1 s warm, which sets the slice p95.
   - Files: `plugin/gate/Sources/SwiftGateDomain/Brownfield/AreaCacheEnvironment.swift` and
     `plugin/gate/Sources/SwiftGateAdapters/Brownfield/LiveAreaCommandRunner.swift`.
   - Suggested fix: pass `-derivedDataPath` under `<git-dir>/swift-harness/` per worktree, seeded from the warm-up's
     copy (APFS `clonefile`), reuse the worktree's for prove's scratch tree, and delete it with the worktree.
6. **A worker can kill every `xcodebuild` on the machine.**
   - The logic worker ran `pkill -f "swiftgate check" ; pkill xcodebuild` at 17:42:00Z. It killed the row worker's
     foreground `--prove` slice (exit 144) and its backgrounded slice, and would kill any other session's builds.
     No guard fired (`hook.decision` `none`).
   - File: `plugin/gate/Sources/SwiftGateDomain/Hooks/Guards.swift`.
   - Suggested fix: deny `pkill` and `killall` by name, and `kill` of a process the session didn't start, for
     subagents. Test: the guard denies a worker's `pkill xcodebuild`; `kill <own background pid>` passes.
7. **An interrupted gate leaves no event.** The 2 killed slices left empty run directories and no `gate.run`.
   File: `plugin/gate/Sources/SwiftGateCLI/GateRun.swift`. Suggested fix: on SIGTERM or SIGINT, record a `gate.run`
   with an interrupted verdict before exiting.
8. **Workers run cold Xcode gates under the 120 s default Bash timeout.** Both workers ran their first slice in the
   same call as their edits; both moved to the background at 120 s, which led to finding 6. File:
   `plugin/workflows/build-task.js` (the worker prompt). Suggested fix: tell workers to run each gate in its own
   foreground call with a 600000 ms timeout.
9. **`.harness/` isn't git-excluded in a brownfield clone.** The row worker's `.harness/tmp/out.txt` showed as
   untracked, the diff-risk judge read it (`a stray .harness/tmp/out.txt file is included`), and `worktree remove`
   refused until the orchestrator deleted it. File: `plugin/gate/Sources/SwiftGateCLI/Commands/PlanImportCommand.swift`,
   which already adds `PLAN.md` to `.git/info/exclude`. Suggested fix: add `.harness/` there too.
10. **The spawned warm-up's `warmup.run` events still carry no `source.binary`** (memos-5 finding 4). File:
    `plugin/gate/Sources/SwiftGateCLI/Commands/RunCommand.swift` (`LiveWarmupSpawner`).
11. **Worker stages still return quoted span ids** (memos-5 finding 8): the row's `review:test-quality` stage
    returned `"\"3ae9bdb1d3761713\""`. File: `plugin/workflows/build-task.js`.
12. **The medium-risk review read no diff.** `guard.reviewer-bash` blocked the test-quality reviewer's 1 attempt to read the diff, a
    `git show`; it returned 0 findings 4 s later, having read only the context pack.
    File: `plugin/workflows/build-task.js` (the reviewer's prompt). Suggested fix: put the diff in the reviewer's
    prompt or in a file it can Read, and report a review that read no diff as a fallback.
13. **The Xcode test step reports no test counts, and prove can't select tests.** `final` shows `testCounts: null`,
    and prove ran the whole test command (`prove.summary`: "it has no test_files"). File:
    `plugin/gate/Sources/SwiftGateDomain/Brownfield/Discover/Readers/XcodeReader.swift`. Suggested fix: propose
    `test_files` with `-only-testing:<target>/<suite>`, and read counts from the result bundle with `xcresulttool`.
14. **Discover marks SwiftLint `found` without checking it's installed.** It read `.swiftlint.yml`; `swiftlint` wasn't
    on `PATH` until I installed it (see Deviations). File:
    `plugin/gate/Sources/SwiftGateDomain/Brownfield/Discover/Readers/SwiftPMReader.swift` (`SwiftDiscoverLint`).
    Suggested fix: mark the step
    `guessed`, or `missing` with "swiftlint not installed", when the tool isn't on `PATH`.
15. **Nothing tells the run or its workers about `swiftgate xcode add-file`.** Only `xcode.file-not-in-target`'s
    message names it. Not exercised here: the project is a synchronized one. Files: `plugin/skills/run/SKILL.md` and
    `plugin/workflows/build-task.js`. Suggested fix: 1 line in each for explicit projects.
16. **The orchestrator's wait loop could never end.** It waited on the re-run warm-up with `until … ! pgrep -f
    "swiftgate warmup"`, which matches its own shell, so the loop ran in the background until the session ended. It
    had no effect. File: `plugin/skills/run/SKILL.md`. Suggested fix: say to re-run `swiftgate warmup` in the
    foreground with a long timeout.
17. **`check-return` passes a return whose `testsAdded` is empty although the task added a test file.** The logic
    return lists `testsAdded: []` beside `AidokuTests/DownloadQueueSummaryTests.swift`. File:
    `plugin/gate/Sources/SwiftGateCLI/Commands/BuildCheckReturnCommand.swift`. Suggested fix: compare `testsAdded`
    with the added files that match the area's `test_globs`.

`report.html` has no absolute local path: `grep` finds 0 matches for `/Users/`, `/private/`, `/tmp/`,
`/var/folders` or the user name.

## Deviations

- **SwiftLint installed.** Discover proposed a SwiftLint lint step, and the machine had no `swiftlint`. I added
  `swiftlint = "0.65.1"` to the trials directory's `mise.toml`, as earlier trials did for Go tools, before the
  1-line probe. Aidoku's CI installs SwiftLint unpinned with Homebrew.
- **Second lock ticket.** The launch's warm-up exited in 8 s, so I took a second ticket for the orchestrator's
  re-run; it covered the re-run's last 4.5 minutes.
- **Post-run ingest.** I ingested the orchestrator session once after the run, as noted above.
- **`claude` on `PATH`.** As in memos-2 to memos-5: node 22's `bin` goes after `mise`'s entries.
- **Launch flags.** As in memos-5, with `spec.md` outside the clone and `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`:

  ```sh
  swiftgate run start spec.md -- -p --output-format stream-json --verbose \
    --plugin-dir <branch>/plugin --dangerously-skip-permissions
  ```
- **Probes.** I ran both probe gates on a throwaway `probe` branch with `--base main`, then deleted the branch before
  the launch.
- **Cleanup.** After recording the sizes, I deleted the 8 DerivedData directories whose trees no longer exist
  (13.0 GiB). The clone's own directory stays.
- **No patches.** I patched neither the clone nor the harness. The run removed its own worktrees; the plan branch
  stays in the clone.

## Files

| File | What |
|---|---|
| `spec.md` | the spec given to `swiftgate run`, byte-identical to the plan dir's copy |
| `discover-apply.json` | the first discovery, right after the clone |
| `slice-empty.json`, `slice-one-line.json` | the probe gates |
| `run.jsonl`, `run.stderr` | the headless session's stream-json, and `run`'s stderr |
| `events.jsonl` | `swiftgate events list` after the post-run ingest |
| `gate-history.jsonl` | the clone's `runs/history.jsonl`; the task worktrees' histories went with them |
| `gate-final.json` | the `final` gate report |
| `build-events.jsonl`, `ledger.json` | the build run's merges, gates and transitions, and the final ledger |
| `worker-journals.jsonl` | the 2 `build-task` workflows' results and logs |
| `PLAN.md`, `run-report.txt` | the orchestrator's plan, and the plan's `REPORT.md` verbatim (plain text, so the prose gate doesn't lint generated output) |
| `report.html` | `swiftgate report --html 20261004T173923Z-a21597fe`, rendered from inside the clone |
| `warmup.log`, `config.toml`, `lock.log`, `uptime.log` | the launch warm-up's log, the clone's config after the run, the build lock holder's log, and the load averages every 15 s from before the clone to the end of the run |
