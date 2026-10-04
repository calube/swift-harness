# Brownfield iOS trial: validation rows on Aidoku

This trial runs a one-shot `swiftgate run <spec.md>` on an iOS app. It tests the validation layer end to end: the
plan's `## Validation` table, the validation task that writes checks before the code, `qa adopt`, `qa run
--at-base`, `qa run --after <task>` after each merge, and `qa run` at `final`. The repository is `Aidoku/Aidoku` at
`3091ef26e593d303e34afed70bc8c5997c105f80`, the same pin as [the first iOS trial](../2026-10-04-brownfield-trial/aidoku-ios-1/README.md).
That trial showed the app builds and tests here, so reusing it keeps the Xcode path out of the question. The clone was fresh,
made on 2026-10-04 at `trials/aidoku-ios-validation-1`. The harness ran from this branch's `plugin/bin/swiftgate`,
main at `fb55870a`, built as source hash `919158044c661cb4`.

The spec is new and tied to no practice task. It asks for an opt-in "Confirm Large Downloads" setting: a toggle in
Settings → Downloads (UI), its value in user defaults (stored data), a pure threshold rule with unit tests, and a
prompt in the chapter list.

**Verdict: the validation bar FAILS.** The code side passed. All 4 requirements merged on the plan branch, every
merge gate ended GREEN (the fixer repaired 1 RED merge), and `final` is GREEN. But no validation row ever produced a real
result:

- **Flow rows.** Both read `unverified` at every `qa run`, because `sim up` loads only `.swiftgate.toml`. The known
  risk is real (finding 1).
- **State row.** It read `red` at base for the wrong reason, a missing `QA_SIM_UDID` (finding 4). It read
  `unverified` after the merge and at `final`.
- **Acceptance rows.** The plan had none (finding 5).

Each `qa run` still reported `GREEN` (finding 3). The headless session also exited mid-build and killed a running
merge gate. I resumed it once (finding 2, Deviations).

## Measures

| Measure | Value | Source |
|---|---|---|
| Clone to discovery | `git clone` and reset: 2 s (21:07:35Z to 21:07:37Z); `discover --apply`: 82 ms | `discover-apply.json`, `discover.run` at 21:08:02.529Z |
| Launch | 21:08:19.165Z | `run.stderr`, the launch script's clock |
| Wall time to the plan | 154 s (2.6 min): the `plan` span ended at 21:10:53.2Z. `plan import` ran next and `build start` at 21:11:05Z | `span.end` `1f58ea8968737a53` |
| Wall time to the first prepared check | 241 s (4.0 min): the validation worker wrote `confirm-toggle-on.state.sh` at 21:12:20Z and both flows by 21:12:26Z. `qa adopt` and the red run `qa run --at-base` followed at 21:13:26.8Z, 308 s (5.1 min) | file times in plan state; `qa.check` `atBase: true` |
| Wall time to the end | 1592 s (26.5 min), from launch to the resumed session's exit at 21:34:51.4Z. The total includes 303 s while the session was dead (21:13:57.7Z to 21:19:00.4Z), so the active time is 1289 s (21.5 min). The time box was 45 min and the cutoff never came | `run.start`, `run.end`, `resume1.start`, `resume1.end` |
| Cost | $4.67 in all: the orchestrator on `claude-opus-5-5` (validation worker included) $3.87, build workers on `claude-sonnet-5-5` $0.71, the fixer on `claude-opus-5-5` $0.09. The 4 `judge diff-risk` calls are extra | the resumed session's `result` `total_cost_usd` 4.667, cumulative; `agent.usage` events sum to 4.667 after my ingest |
| Human input | 1 resume prompt after the headless exit (Deviations). No `AskUserQuestion` | `run.jsonl`, `resume1.jsonl` |
| Halts | 2: the session exit (finding 2) and `build.halt` `question` on `download-prompt` (finding 6), answered `retry` in 41 ms | `build.halt`/`build.resume` at 21:28:46Z |
| Load | 1-minute load average 3.6 to 237.5 during the run | `uptime.log` |

## Validation rows

`validation.json` holds 3 rows and 2 reason-only requirements. Every row's `Runs after` is `settings-toggle`, and its
`Writer` is `spec-validation`.

| Row | Requirement | Layer | Check | `--at-base`, `20261004T211326Z-e21553f8` (at the contract `07833f59`) | `--after settings-toggle`, `20261004T212821Z-79c15450` | `final`, `20261004T213430Z-5250c2ac` |
|---|---|---|---|---|---|---|
| 1 | req-setting | flow | `qa/confirm-toggle.flow.json` | `unverified`: "not run: sim up swiftgate.environment: no .swiftgate.toml in" the scratch tree | `unverified`, same reason | `unverified`, same reason |
| 2 | req-stored | flow | `qa/confirm-toggle-on.flow.json` | `unverified`, same reason | `unverified`, same reason | `unverified`, same reason |
| 3 | req-stored | state | `qa/confirm-toggle-on.state.sh` | `red`, exit 1: `QA_SIM_UDID: QA_SIM_UDID is required`. Evidence: `qa-runs/20261004T211326Z-e21553f8/03-req-stored.state.txt` | `unverified`: "flow row 2 … is unverified" | `unverified`, same reason |
| — | req-threshold | none | — | reason: "the unit tests in threshold-rule cover every branch of the pure rule" | | |
| — | req-prompt | none | — | reason: "needs an installed source with a manga over 50 chapters, which a fresh simulator lacks" | | |

`qa run --after threshold-rule` (`20261004T212105Z-f0f49ad3`) and `--after download-prompt`
(`20261004T213311Z-fea5f318`) each read "no validation row to run". Every one of the 5 `qa run` reports has verdict
`GREEN`. No `qa.flow` event exists: no flow ran. No row passed, on evidence or otherwise.

Against the task's bar:

| Bar | Result |
|---|---|
| ≥ 1 acceptance row with a result from `qa run` | FAIL: 0 acceptance rows |
| ≥ 1 flow row with a result from `qa run` | FAIL in substance: 2 rows, both `unverified` because `sim up` refused the clone |
| ≥ 1 state row with a result from `qa run` | FAIL in substance: `red` at base for a missing input, then `unverified` |
| No row passed on evidence alone | PASS: no row passed |

The checks look sound. Both flows lint GREEN against the pinned schemas, after 1 repair of a `wait` step's shape. They
press `label="Settings"` and then `label="Downloads"`, then `wait` and `is` on
`id="Downloads.confirmLargeDownloads"`. The state script reads `simctl spawn <udid> defaults read <bundle>
Downloads.confirmLargeDownloads` and wants `1`. None of them has run on a device, so whether they would pass stays
open.

## Every merge

| Task | Commits | Merge gate | Review |
|---|---|---|---|
| `spec-contract` | `07833f59` | contract `slice` GREEN `20261004T211001Z-799655b3` in 0.25 s with no build step (finding 8); a retry with `--app-build` was BLOCKED (`20261004T211014Z-b934b3f1`) | contract |
| `threshold-rule` | `316a6889`, `700c3f3e` → merge `926a84ae` | GREEN `20261004T211912Z-83101128` (107.5 s), after the first attempt was killed (finding 2) | diff-risk `low` |
| `settings-toggle` | `0d6ad80a` → merge `7145a6d0` | RED `20261004T212120Z-792f77d5` (177.2 s): its own new test failed on the simulator, since its slices were build-only. `build merge --undo`, then the fixer `96a2651a` → merge `01684ed6`, GREEN `20261004T212709Z-f3e6347a` (67.6 s) | diff-risk `low` ("no security, persistence or API risk", for a new stored setting) |
| `download-prompt` | `c0633d87` → merge `c5d44dd5` | GREEN `20261004T213157Z-70492e87` (70.5 s), after the halt and retry (finding 6) | diff-risk `medium`: 1 review stage |
| `spec-validation` | none; `qa adopt` GREEN, "adopted spec (3 files)" | — | — |
| `final` | `c5d44dd5` | GREEN `20261004T213316Z-5e50b21d` (70.1 s), then `qa run` `20261004T213430Z-5250c2ac` | — |

`run report` leads with "Unfinished tasks: none" and `final: GREEN`. It doesn't mention that `qa run` verified no
validation row; only the orchestrator's own prose did.

## Harness findings

Ranked by how much they block the validation layer.

1. **`sim up` and `qa run`'s flow path never load a brownfield config, so no flow can run in a brownfield clone.**
   - Confirmed before launch: `swiftgate sim up --json` in the fresh clone printed BLOCKED `swiftgate.environment`
     "no .swiftgate.toml in <clone>". In the run, the validation worker hit the same failure and skipped its red run
     of both flows. `qa run` then read every flow row `unverified`, both at base (in the scratch tree) and in the
     checkout.
   - Files: `plugin/gate/Sources/SwiftGateCLI/Commands/SimUpCommand.swift` and `LiveQAFlowSimulator.up` in
     `plugin/gate/Sources/SwiftGateCLI/Commands/QARunCommand.swift`. Both call `ConfigLoader().load(repositoryRoot:)`,
     not `loadProfile(repositoryRoot:commonDir:)`. `SimUp` also needs the owned `Config`'s simulator table, scheme
     and bundle id, which `BrownfieldConfig` doesn't have.
   - Suggested fix: load the profile. For a brownfield clone, build the sim settings from the `xcode` area: its
     project, its scheme and the bundle id from `-showBuildSettings`. Add a `[simulator]` table to the brownfield
     config that discover writes, which would also close the earlier trial's finding 4 (the device pinned by name).
   - Test: a temp clone with only `<common>/swift-harness/config.toml` and 1 `xcode` area gets past config loading
     in `sim up` and in `qa run`'s flow row.
2. **A headless run exits when a turn ends with only background Bash work pending, which kills that work.**
   - The orchestrator ran the first merge gate with `run_in_background` and ended its turn with "Waiting for the
     merge gate." The `-p` session exited seconds later, at 21:13:57Z. The exit killed the gate, which left an empty output
     file and no `gate.run`. The cutoff timer (`/bin/sleep 2234`, background) and a `ScheduleWakeup` died with it.
     `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` keeps the session waiting on workflows and agents, not on Bash tasks.
   - Files: `plugin/skills/run/SKILL.md`, which says to run `qa run --at-base` with `run_in_background` and keep a
     background `sleep` cutoff timer, and `plugin/skills/build/references/event-loop.md` (the timers).
   - Suggested fix: in a run, every gate and `qa run` goes in the foreground with a 600000 ms timeout, and the
     deadlines come from `run clock` and `build next`'s `timeBox` instead of a background sleep. Or `run start`
     could resume the session while the ledger still has running tasks.
   - Test: a contract row in `tests/skill_commands_test.mjs` finds no `run_in_background` on a gate or `qa run` in
     the run skill.
3. **A `qa run` whose every row is `unverified` reads `GREEN`, and so does the run.**
   - All 5 reports say `GREEN`, including `final`'s 3 of 3 `unverified`. The run report's first lines are "Unfinished
     tasks: none" and `final: GREEN`.
   - Files: the verdict in `plugin/gate/Sources/SwiftGateCLI/Commands/QARunCommand.swift` (`QAReport`) and
     `plugin/gate/Sources/SwiftGateDomain/Brownfield/BrownfieldRunReport.swift`.
   - Suggested fix: a run with rows and none verified is not `GREEN`. Make it `BLOCKED` naming the reasons, or at
     least have the report's first lines say "validation: 0 of 3 rows verified".
   - Test: a table of 1 flow row with no simulator yields a non-GREEN verdict.
4. **At base, a state row runs although its flow row didn't, and its red on a missing input counts as failing at
   base.**
   - Row 3 ran at base with no `QA_SIM_*` and exited 1 on `QA_SIM_UDID is required`. After the merge, the same row
     read `unverified`, as it should ("flow row 2 … is unverified"). The validation brief calls a check that fails on a
     missing input "not ready", but `qa run --at-base` took it as the red that proves the check.
   - File: the at-base path of `QARunPlan.execute` and `Checks.run` in
     `plugin/gate/Sources/SwiftGateCLI/Commands/QARunCommand.swift`.
   - Suggested fix: apply the flow dependency at base as well.
   - Test: at base, a state row whose flow is `unverified` reads `unverified`.
5. **The plan may carry no acceptance row.**
   - `plan-shape.md` says "Unit tests are each task's own and never get a row". The orchestrator gave the pure rule
     (req-threshold) a reason-only row, and nothing else crosses a boundary, so the table had 0 acceptance rows
     and `plan import` accepted it.
   - Files: `plugin/skills/run/references/plan-shape.md` and `SKILL.md` step 5.
   - Suggested fix: decide whether a brownfield plan needs at least 1 acceptance row, such as the contract's surface
     driven from a test. If it does, add a `plan-lint.validation-no-acceptance` rule. If not, the trial bar should
     say an acceptance row is optional.
6. **`worktree create` cuts a dependent task's worktree from a merge whose gate hasn't finished.**
   - `download-prompt` started at 21:21:12Z, 7 s after `settings-toggle` merged and while that merge's gate was
     still running. The gate went RED and was undone. `download-prompt`'s branch then carried `settings-toggle`'s
     commit, and its return failed `build-return.outside-write-set`. That led to the `question` halt and a retry
     with a rebase.
   - Files: `plugin/skills/build/references/event-loop.md` (when `build next` runs after a merge) or the base that
     `worktree create` takes.
   - Suggested fix: start no task while a merge awaits its gate, or cut worktrees from the last gated commit.
7. **A missing SwiftLint makes lint RED in 4 ms at the head and at the base, and the baseline absorbs it all run.**
   - Every gate's `area-lint` was RED in a few ms (`final`: 4 ms), and the baseline absorbed each as "Aidoku lint (the whole
     step)". So lint gated nothing, and the report lists it under "Baseline failures" instead of saying the tool is
     missing. `swiftlint` wasn't on the run's `PATH`: the trials' `mise.toml` pins it, but the launch shell doesn't
     activate mise.
   - Files: `SwiftDiscoverLint` in
     `plugin/gate/Sources/SwiftGateDomain/Brownfield/Discover/Readers/SwiftPMReader.swift`, and the baseline step in
     `plugin/gate/Sources/SwiftGateCLI/BrownfieldSliceCheck.swift`.
   - Suggested fix: treat exit 127 as `not-installed` and drop the step with that reason, and never absorb a
     whole-step failure. This extends the earlier trial's findings 3 and 14.
8. **The earlier trial's findings 1 and 2 still hold.**
   - Discover's `xcodebuild` commands still omit `-skipPackagePluginValidation`, so the warm-up failed in 21 s.
     The orchestrator fixed it with `discover --apply --set`.
   - Nothing re-ran the warm-up, so the failed 2.5 s test time stayed. The contract slice was GREEN in 0.25 s with
     no build step.
   - Files and fixes are as in that README.
9. **The run report lists stale baseline failures.** "Aidoku build: the whole step" and "Aidoku test: the whole
   step" come from the pre-`--set` commands, which no gate used afterwards. This is the earlier trial's finding 3,
   and the orchestrator flagged it itself.
10. **An absolute path reaches `report.html` through a row message.** The rendered page held
    `/Users/…/aidoku-ios-validation-1-spec` twice, in the Validation rows' `message`, which comes from `sim up`'s
    "no .swiftgate.toml in \(root.path)".
    - Files: `plugin/gate/Sources/SwiftGateDomain/RunView/RunViewValidation.swift`, whose path guard checks
      evidence paths but not messages, and the message in `SimUpCommand.swift` and `QARunCommand.swift`.
    - Suggested fix: make the message name the worktree relative to the repository, and pass messages through the
      payload guard.
11. **The orchestrator writes gate output to shared `/tmp/<slug>-*.json`.**
    - `spec-final.json` replaced another run's file of the same name, from 05:59 that day.
    - File: `plugin/skills/run/SKILL.md`. Suggested fix: say where gate JSON goes, such as `<plan-dir>` or the
      checkout's `.harness/tmp/`, or read the run's `report.json` by `runID`.
12. **The run marks the validation task `done`, and `qa adopt` reads GREEN, with no red run behind it.** The worker returned
    without running any flow on a device, and `qa adopt` copied 3 files. Only `qa run --at-base` could have caught
    it, and finding 4 hid that.
    - Files: the validation-task step in `plugin/skills/run/SKILL.md`, and `qa adopt`.
    - Suggested fix: the worker's return lists each check's recorded failure, and `qa adopt` notes any check that
      has none.

## Deviations

- **Resumed once.** After the headless exit, I resumed the same session (`claude --resume
  59187604-2ab5-4533-97ff-ef6a9f4ad76d`, with the same `--settings`, `--model`, `--plugin-dir` and `-p` flags). The
  prompt told it the session had exited, that a background Bash task doesn't keep it alive, that the exit
  killed the merge gate, and to run gates and `qa run` in the foreground and continue. Its later behaviour follows that hint, so the
  run after 21:19Z isn't one-shot.
- **Launch.** Same as the earlier trial, with `spec.md` outside the clone and
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`. I held 1 machine build slot for both sessions. No probe gates ran.

  ```sh
  swiftgate run start spec.md -- -p --output-format stream-json --verbose \
    --plugin-dir <branch>/plugin --dangerously-skip-permissions
  ```
- **SwiftLint not installed** for this run (finding 7). The earlier trial put it on `PATH`; this one didn't.
- **Post-run ingest.** `swiftgate events ingest --session 59187604-… --role orchestrator --build-run
  20261004T211105Z-547ce60a`: 8 new messages. I exported `events.jsonl` after it.
- **`report.html` redaction.** `swiftgate report --html 20261004T211105Z-547ce60a` wrote 2 copies of the checkout's
  absolute path (finding 10). I replaced each with `[checkout]` with `sed`; nothing else changed (96 bytes). `grep`
  then finds 0 matches for `/Users`, `/private`, `/var/folders`, `/tmp/` or the user name.
- **No patches** to the clone or the harness.
- **Cleanup.**
  - I deleted the clone and its 7 DerivedData directories (13.5 GiB). The run's own worktrees were already gone.
  - I removed this run's 10 `/tmp/spec-*.json` files.
  - The run created no simulator, `agent-device` session or sim lease: `sim up` never got past config loading.
    `xcodebuild` ran tests on its own clones of `iPhone 17`, and none of them remains. I touched no other
    simulator.

## Files

| File | What |
|---|---|
| `spec.md` | the spec given to `swiftgate run`, byte-identical to the plan dir's copy |
| `discover-apply.json` | the first discovery, right after the clone |
| `run.jsonl`, `run.stderr` | the first headless session's stream-json, up to its exit, and `run`'s stderr |
| `resume1.jsonl`, `resume1.stderr` | the resumed session's stream-json |
| `events.jsonl` | `swiftgate events list` after the ingest: 430 events, including 9 `qa.check` and 0 `qa.flow` |
| `PLAN.md`, `plan.json`, `validation.json`, `ledger.json` | the plan with its `## Validation`, its import, the validation table `qa run` reads, and the final ledger |
| `qa/` | the 3 adopted checks: 2 flow steps files and the state script |
| `qa-runs/<runID>/` | every `qa run`'s `report.json`, and the at-base state row's output |
| `build-events.jsonl`, `returns/` | the build run's transitions, merges, gates, return checks and undo, and each task's return |
| `gate-history.jsonl`, `gate-final.json`, `gate-merge-settings-toggle-red.json` | the clone's gate history, the `final` report, and the RED merge gate's report |
| `run-report.txt` | the plan's `REPORT.md` verbatim |
| `report.html` | the build run's page, with the redaction above |
| `warmup.log`, `config.toml`, `uptime.log` | the launch warm-up's log, the clone's config after the run, and load averages every 15 s |
