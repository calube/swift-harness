# Brownfield iOS trial: validation rows on Aidoku, third attempt

This is a re-run of [the second validation trial](../2026-10-04-brownfield-ios-validation-2/README.md), made after the
fixes listed under [Fixes from the second attempt, checked](#fixes-from-the-second-attempt-checked) landed on main. It is a
one-shot `swiftgate run <spec.md>` on `Aidoku/Aidoku` at `3091ef26e593d303e34afed70bc8c5997c105f80`, in a fresh clone
made on 2026-10-04 at `trials/aidoku-ios-validation-3`. The harness ran from this branch's `plugin/bin/swiftgate`: main
at `a2fbb774`, built as source hash `efc1d8931c39af5f`.

The spec keeps the earlier feature, an opt-in "Confirm Large Downloads" setting, and changes 2 sentences. Requirement 1
asks for "a readable label" as well as an identifier. Requirement 3 puts the acceptance test in "1 test class in the
app's existing `AidokuTests` target" that "can be run on its own by its target, class and method name". The aim was to
lead the plan to an acceptance row in the `test:` form.

**Verdict: the bar is met on the letter, but the flow and state rows have results only at base.** Each of the 3
layers has a real `qa run` result, and no row passed on evidence alone. But the flow and state rows never ran against
the merged toggle:

- **Acceptance.** Met in substance. Row 4, `test: AidokuTests/LargeDownloadConfirmationTests`, read `red` at base
  ("exit 0, but no test matched"), then `pass` twice after its task merged. Its result bundle shows 4 tests run and 4
  passed.
- **Flow.** Met at base only. Rows 1 and 2 read `red` on a device at step 6, a `wait` for the new toggle's id. After
  that, `build cutoff` abandoned the toggle task although its fix had merged with a GREEN gate. So both rows read
  `waiting` at `final` (finding 1).
- **State.** Met at base only. Row 3 ran on row 2's device at base and read `red`: "The domain/default pair of
  (app.aidoku.Aidoku, Downloads.confirmLargeDownloads) does not exist". At `final` it read `waiting`, for the same
  reason as the flow rows.
- **Evidence alone.** Met: the only `pass` is the acceptance row, and it ran 4 tests.

The code side passed. All 4 code tasks merged, `final` is GREEN, and the run was truly one-shot: no resume and no human
input. But the run reports `INCOMPLETE`, because the toggle task is marked `abandoned` while its code is on the plan
branch.

## Measures

| Measure | This attempt | Second attempt | First attempt | Source |
|---|---|---|---|---|
| Clone to discovery | clone and reset under 1 s (23:40:48Z); `discover --apply` 117 ms | 2 s; 59 ms | 2 s; 82 ms | `clock.log`, `discover.run` 23:40:48.5Z |
| Launch | 23:41:05.1Z | 22:05:23.5Z | 21:08:19.2Z | `clock.log` |
| Wall time to the plan | **93 s** (1.6 min): the `plan` span ended at 23:42:38.3Z. `plan import` and `build start` ran by 23:44:10Z (185 s) | 108 s | 154 s | `span.end` `436407f5fb5bff94` |
| Wall time to the first prepared check | **284 s** (4.7 min): the validation worker wrote both flows and the state script, and `qa lint` was GREEN, at 23:45:48.9Z. Its first device red was at 23:49:36Z (511 s). `qa run --at-base` ran from 23:52:39Z to 23:57:29Z, all 4 rows red (984 s), before the first merge that has rows | 321 s; first device red 914 s; no `--at-base` | 241 s; `--at-base` at 308 s, red for a missing input | `validation-worker.jsonl` timestamps; `qa.check` events |
| Wall time to the end | **2626 s** (43.8 min), launch to exit at 00:24:51.0Z, all of it active. `build cutoff` fired at 00:21:51Z | 1875 s | 1592 s, 1289 s active | `clock.log` |
| Cost | **$3.81**: `claude-opus-5-5` $3.01 (orchestrator, validation worker), `claude-sonnet-5-5` $0.80 (build workers and the fixer). The 4 `judge` calls are extra | $4.71 | $4.67 | final `result` `total_cost_usd` 3.8092; `agent.usage` events sum to 3.8092 after ingest |
| Human input | **0**: no resume, no `AskUserQuestion` | 0 | 1 resume | `run.jsonl`: 3 `result` lines, 1 session `cf46ae44-…` |
| Halts | **3** `build.halt`: `gate-red` on `confirm-downloads-setting` (answered `retry`), then 2 `budget` halts from `build cutoff`. 1 RED merge gate went to the fixer | 0 | 2 | `events.jsonl`, `cutoff.json` |
| Validation worker | **6.4 min** (23:44:47Z to 23:51:13Z), 2 `sim up`: 195 s cold, then 34 s on the stamped build | 13 min, 4 cold `sim up` | 4 min, no `sim up` | `validation-worker.jsonl` |
| Fixer | **15.8 min** (00:03:05Z to 00:18:55Z), 7 merge-tier gates for 1 test file (finding 2) | 4 min | under 1 min | `fixer.jsonl`, span `a8fc4c68dd7813d2` |
| Warm-up | build passed in 62.2 s and test in 45.7 s, both cold, so the area is build-only at `slice` (46 s is over the 30 s budget) | build 66.1 s, test 75.1 s | build failed in 21 s | `warmup.run` 23:42:53Z |
| Load | 1-minute load average 10.3 to 392.7 during the run | 8.3 to 950 | 3.6 to 237.5 | `uptime.log` |

## Validation rows

`validation.json` holds 4 rows and 1 reason-only requirement. The writer of rows 1 to 3 is `spec-validation`. Row 4's
writer is `confirm-downloads-check`.

| Row | Requirement | Layer | Check | `--at-base`, `20261004T235239Z-4acebe48` (at `c1766cda`) | `--after confirm-downloads-check`, `20261005T000035Z-78e50883` | final `qa run`, `20261005T002359Z-7b81c6a7` (at `121d27b6`) |
|---|---|---|---|---|---|---|
| 4 | req-download-check | acceptance | `test: AidokuTests/LargeDownloadConfirmationTests` | **`red`** in 87 s: "exit 0, but no test matched `AidokuTests/LargeDownloadConfirmationTests`". The bundle has 0 tests | **`pass`** in 45 s: "exit 0". The bundle has 4 tests, 4 passed | **`pass`** in 32 s, same 4 tests |
| 1 | req-setting-toggle | flow | `qa/confirm-large-downloads-toggle.flow.json` | **`red`** in 141 s: "step 6 `wait` failed: … wait timed out for selector: id=\"Downloads.confirmLargeDownloads\". Current surface: Settings, Incognito Mode, Downloads, Total Downloads." Steps 1 to 5 `ok`. `sim verify` GREEN with 0 findings | — | `waiting` on `confirm-downloads-setting` (finding 1) |
| 2 | req-stored-value | flow | `qa/confirm-large-downloads-store.flow.json` | **`red`** in 58 s at step 6, the same `wait` | — | `waiting`, same |
| 3 | req-stored-value | state | `qa/confirm-large-downloads-store.state.sh` | **`red`** in 0.5 s, on row 2's device: exit 1, "Downloads.confirmLargeDownloads not stored in app.aidoku.Aidoku defaults: … does not exist" | — | `waiting`, same |
| — | req-prompt | none | — | reason: "needs a source with over 50 chapters and network in the simulator; the req-download-check acceptance test covers the decision the prompt follows" | | |

`qa run --after confirm-downloads-prompt` read GREEN with no row due. The at-base report reads "4 of 4 rows verified:
0 pass, 4 red". The final report reads "1 of 4 rows verified: 1 pass, 0 red, 0 unverified, 3 waiting", with verdict
`GREEN`. The run report's third line is `validation: 1 of 4 rows verified (qa run 20261005T002359Z-7b81c6a7, GREEN)`.
Both `qa.flow` events come from the at-base run.

Against the bar:

| Bar | Result |
|---|---|
| ≥ 1 acceptance row with a real `qa run` result | PASS: row 4 `red` at base for the right reason, then `pass` with 4 tests run |
| ≥ 1 flow row with a real `qa run` result | PASS on the letter: rows 1 and 2 `red` on a device at base, at the missing toggle. Neither ran after the merge |
| ≥ 1 state row with a real `qa run` result | PASS on the letter: row 3 `red` at base on a device, for the missing key. It never ran after the merge |
| No row passed on evidence alone | PASS: the only `pass` ran 4 tests |

The checks look sound against the merged code. They press `label="Settings"`, scroll to and press `label="Downloads"`,
then `wait` for `id="Downloads.confirmLargeDownloads"`, which is the key that `SettingView` sets as each toggle's
identifier. Row 2 then presses the toggle by `id=` and checks `value="1"`. That is the step that hit
`covered_by_interactive_descendants` in the second attempt, so whether it passes stays open.

## Every merge

| Task | Commits | Merge gate | Review |
|---|---|---|---|
| `confirm-downloads-contract` | `dbfdd547` | `slice` GREEN `20261004T234253Z-93e21c49` (59.1 s); lint dropped "tool isn't installed (exit 127 …)", then `discover --apply --drop Aidoku.lint` | contract |
| `confirm-downloads-prompt` | `cfb5eacf` → merge `c1766cda` | GREEN `20261004T235115Z-9e16c380` (60.1 s); prove: "no new or changed tests since dbfdd547" | diff-risk `medium` |
| `spec-validation` | none; `qa adopt` at 23:52Z, "adopted spec (3 files)", then `qa run --at-base` | — | — |
| `confirm-downloads-check` | `17491e92` → merge `303690d0` | GREEN `20261004T235743Z-1815c0e2` (163.7 s); prove: "1 of 1 changed tests fail with the change's source reverted" | diff-risk `low` |
| `confirm-downloads-setting` | `33638e67` → merge `60af5c02` | RED `20261005T000130Z-66a9b9ff` (86.7 s): its new test target didn't compile, since its slice only built. `build halt gate-red`, `build merge --undo`, then the fixer's `c93200e1` … `d96aa51c` (4 commits, 7 gates) → merge `121d27b6`, GREEN `20261005T001901Z-dcb14a2a` (162.9 s), prove base `303690d0`. Then `build cutoff` marked it `abandoned` (finding 1) | diff-risk `low` |
| `final` | `121d27b6` | GREEN `20261005T002200Z-c58fdb53` (115.3 s): "2 of 2 changed tests fail with the change's source reverted"; then `qa run` | — |

## Fixes from the second attempt, checked

| Second-attempt finding or fix on main | Now |
|---|---|
| 1, the brownfield audit made every flow red | **Fixed where it was exercised.** Both at-base `sim verify` reports are GREEN with 0 findings, against 183 last time. No flow reached its last step, so a `pass` judged by the audit is still unseen |
| 2, an Xcode area couldn't express an acceptance row | **Fixed.** The plan wrote `test: AidokuTests/LargeDownloadConfirmationTests`. `qa run` ran `xcodebuild test … -only-testing:'AidokuTests/LargeDownloadConfirmationTests' -resultBundlePath …`. At base it was red on 0 tests run despite exit 0, and after the merge it passed on 4 tests. The plan used the `<Target>/<Class>` form, not `<Class>/<method>` |
| 3, a state row waited on any red flow row | **Fixed where it was exercised.** At base, row 3 ran on row 2's device and read its own red. The post-merge path was never reached |
| 4, unknown agent-device reasons | Not exercised: every failure was the known `wait` timeout |
| 5, the worker's red runs skipped `qa run`; no `--at-base` | **Half fixed.** The orchestrator ran `qa run --at-base` and held `confirm-downloads-check` until all 4 rows were red ("It can't merge until … its `--at-base` run is done"). The worker still drove raw `agent-device batch` on its own `sim up` |
| 6, a 13-minute validation worker | **Fixed.** 6.4 min. The second `sim up` reused the stamped build: 34 s against 195 s cold |
| 7, a RED `qa run` halted nothing | Not exercised: no post-merge `qa run` was red |
| 8, prove measured against the plan base | **Fixed.** `confirm-downloads-prompt`'s merge says "no new or changed tests since dbfdd547", and the fix merge's prove base is `303690d0`, the merge's first parent |
| 9, build-only slices move the first test run to the merge | **Not fixed** (finding 3) |

## Harness findings

Ranked by how much they block the validation layer.

1. **`build cutoff` abandons a task whose merge is in and gated GREEN, and its validation rows then wait forever.**
   - The orchestrator ran `build record-gate spec --kind merge --task confirm-downloads-setting --run-id
     20261005T001901Z-dcb14a2a`, which returned `GREEN`, and in the same call ran `build cutoff`. The cutoff returned
     `abandon` for that task: "its merge gate (120 s) plus final and the report (180 s) doesn't fit in the 253 s left in
     the box". The merge gate had already run. The task was still `in-progress` only because `ledger set … done`
     hadn't run yet.
   - As a result, `qa run` at `final` read rows 1 to 3 `waiting on confirm-downloads-setting`, although
     `121d27b6` holds that task's code. No `qa run --after confirm-downloads-setting` ran. The final `qa run` verdict
     is `GREEN` with 3 of 4 rows waiting, and the run reads `INCOMPLETE` with a merged task listed as abandoned.
   - Files: the cutoff decision in `build cutoff` (it should treat a task with a merge event and a recorded GREEN
     merge gate as done), `qa run`'s `waitingOn` (it could count a task as merged by the ledger's merge event, not its
     status), and the final verdict, which counts `waiting` rows at `final` as GREEN.
   - Suggested fix: `build cutoff` marks a merged-and-gated task `done`, not `abandoned`. At `final`, a row still
     `waiting` is not GREEN.
   - Test: a ledger with a task in progress, a merge event and a GREEN merge gate, past the cutoff, yields `finish`
     for that task, not `abandon`.
2. **The fixer used the full merge gate as its compile loop: 7 gates in 15.8 minutes for 1 test file.**
   - The setting task's new test failed in 3 ways in turn: a missing `import AidokuRunner`, a `.toggle` matched
     without its payload, and then a runtime miss because `Settings.downloadSettings` wraps its toggles in a `.group`.
     The fixer found each one by running `swiftgate check --tier merge`. Each run took 80 to 160 s and included prove,
     which ran the whole test command once more, so 9 prove scratch trees and their DerivedData were left behind.
     Then the orchestrator ran the merge gate once more (163 s).
   - This cost is what pushed the task past `noNewStartsAt` and into finding 1.
   - Files: `plugin/agents/build-fixer.md` and its gate guidance. Suggested fix: the fixer iterates on a compile or
     test failure with `check --tier slice` (or a narrower test run through swiftgate) and runs the merge tier once,
     at the end.
3. **Build-only slices still move the first test compile to the merge, for the third attempt running.**
   - The warm test took 45.7 s, over the 30 s `slice_budget_s`, so the setting task's slice built the app target
     only. Its test target never compiled until the merge gate, which went RED.
   - This happened in attempt 1 (`settings-toggle`), attempt 2 (`download-setting`) and now `confirm-downloads-setting`.
     It cost 1 RED gate, 1 undo, and the fixer in finding 2.
   - Files: the build-only step in `plugin/gate/Sources/SwiftGateCLI/BrownfieldSliceCheck.swift`. Suggested fix: a
     build-only xcode slice runs `build-for-testing` instead of `build`, so the test target compiles at the slice. The
     build cost is about the same, and no test runs.
4. **The validation worker still drives raw `agent-device batch` for its red runs.**
   - Both of its device runs were `agent-device batch` on its own `sim up`, then `sim snap`, `down` and `verify`, not
     `qa run --at-base`. This mattered less this time, because the orchestrator then ran `qa run --at-base` before any
     row-bearing merge. But the worker spent 2 `sim up` calls on a red that `qa run --at-base` repeated 2 minutes later.
   - File: `plugin/skills/qa/references/validation-worker.md`.
5. **The report page shows only the last `qa run`, so the only flow and state results are hidden.**
   - `report.html`'s validation view holds the final run's 4 rows: 1 pass and 3 waiting. The at-base reds with their
     steps and device evidence, the only flow and state results of the run, don't appear on the page.
   - Files: `plugin/gate/Sources/SwiftGateDomain/RunView/RunViewValidation.swift` and `RunViewBuilder.swift`.
     Suggested fix: show each row's last result that isn't `waiting`, or the at-base result beside the latest.
6. **A passing `test:` row says only "exit 0", and its bundle isn't evidence.**
   - The pass reads "exit 0", and its evidence is only the `.txt` output. The `.xcresult`, which shows 4 tests run, is
     on disk but not listed. The red at base says "no test matched", so the count is read. It just isn't reported on
     a pass.
   - File: the acceptance branch of `Checks.run` in `QARunCommand.swift`. Suggested fix: "exit 0, 4 tests passed",
     and list the bundle.
7. **A RED merge gate that goes to the fixer is never recorded as a gate.**
   - `build-events.jsonl` has no `gate` event for `20261005T000130Z-66a9b9ff`, only the `gate-red` halt and the undo.
     The run-report "Every merge" view can't show the RED gate. It is in `gates/merge-setting.json` and
     `gate-history.jsonl`.
   - File: the RED-merge steps in `plugin/skills/build/references/event-loop.md`, which name `build halt` but not
     `build record-gate`.
8. **`qa lint` notes `qa.flow-ids-unknown` on every brownfield clone.** "a brownfield clone's config.toml declares no
   accessibility ids, so no `id="…"` selector was checked against the app". Discover writes no `[qa]
   accessibility_ids`, and Aidoku has no `enum AccessibilityID`, so the note can't be cleared. Low impact.
9. **A cutoff run leaves the abandoned task's worktrees.** `run checkout remove` removed the plan checkout, but
   `…-spec-confirm-downloads-setting` and `…-spec-fix-confirm-downloads-setting` stayed. I removed them in cleanup.

## Deviations

- **None in the run itself.** It was one-shot with no resume and no prompt after launch. I patched neither the
  clone nor the harness.
- **Clone source.** I cloned from the local `trials/aidoku-ios-1` (whose origin is GitHub), set `origin` back to
  `https://github.com/Aidoku/Aidoku.git`, and reset `main` to the pin. The source clone carried a remote-tracking
  branch `origin/swift-harness/spec` from the first iOS trial. I deleted it before discovery, so the run's
  `swift-harness/spec` started clean.
- **Launch.** As in the earlier attempts: `spec.md` outside the clone, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`,
  and 1 machine build slot held for the session.

  ```sh
  swiftgate run start spec.md -- -p --output-format stream-json --verbose \
    --plugin-dir <branch>/plugin --dangerously-skip-permissions
  ```
- **SwiftLint not installed**, as in both earlier attempts. The contract slice dropped lint with exit 127, and the
  orchestrator ran `discover --apply --drop Aidoku.lint`.
- **Post-run ingest.** `swiftgate events ingest --session cf46ae44-… --role orchestrator --build-run
  20261004T234410Z-daacb3fb` read 10 new messages. I exported `events.jsonl` after it.
- **`report.html`** is `swiftgate report --html 20261004T234410Z-daacb3fb`, unedited. `grep` finds 0 matches for
  `/Users`, `/private`, `/var/folders` or `/tmp/`.
- **Cleanup.**
  - I removed the 2 leftover worktrees (finding 9), the clone, and its 21 DerivedData directories (38.4 GiB), each
    matched to the clone by its `WorkspacePath`.
  - The run made 4 simulator clones: 2 from the worker's `sim up` and 2 from the at-base flow rows. None remains.
    `agent-device session list` is empty, there are no device claims, and the `sim-leases` directory is empty. The
    simulator list matches the one taken before the run.
  - I touched no other simulator, and no `agent-device` session folder but this run's logs.

## Files

| File | What |
|---|---|
| `spec.md` | the spec, byte-identical to the plan dir's copy |
| `discover-apply.json`, `config.toml`, `warmup.log` | the first discovery, the clone's config after the run (lint dropped), and the launch warm-up's log |
| `run.jsonl`, `run.stderr`, `clock.log` | the session's stream-json, `run`'s stderr, and my launch clock |
| `validation-worker.jsonl`, `fixer.jsonl` | the validation worker's transcript with its red runs, and the fixer's transcript with its 7 gates |
| `events.jsonl` | `swiftgate events list` after the ingest: 471 events, including 9 `qa.check` and 2 `qa.flow` |
| `PLAN.md`, `plan.json`, `validation.json`, `ledger.json` | the final plan, its import, the validation table, and the ledger |
| `qa/` | the 3 adopted checks |
| `qa-runs/<runID>/` | the at-base, `--after confirm-downloads-check` and final `qa run`s: `report.json`, row evidence, step screenshots and trees, and each run's `qa` events (no `.xcresult` or build log) |
| `gates/` | each slice, merge and `final` gate report, and each `qa run`'s JSON, from `<plan-dir>/out/` |
| `build-events.jsonl`, `cutoff.json`, `returns/`, `gate-history.jsonl` | the build run's transitions, merges, undo and gates; the cutoff's decision; each task's return; the clone's gate history |
| `run-report.txt` | the plan's `REPORT.md` verbatim |
| `report.html` | the build run's page |
| `uptime.log` | load averages every 15 s |
