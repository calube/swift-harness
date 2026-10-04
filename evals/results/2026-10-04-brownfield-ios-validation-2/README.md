# Brownfield iOS trial: validation rows on Aidoku, second attempt

This is a re-run of [the first validation trial](../2026-10-04-brownfield-ios-validation/README.md), made after
main fixed its findings 1, 2, 3, 4, 7, 8, 11 and 12. It is a one-shot `swiftgate run <spec.md>` on `Aidoku/Aidoku`
at `3091ef26e593d303e34afed70bc8c5997c105f80`, in a fresh clone made on 2026-10-04 at
`trials/aidoku-ios-validation-2`. The harness ran from this branch's `plugin/bin/swiftgate`: main at `70e54179`,
built as source hash `c69f219c55d44fd4`.

The spec keeps the first attempt's feature, an opt-in "Confirm Large Downloads" setting. It adds 1 thing: requirement 3
is now a decision at a boundary. The decision reads the setting from the `UserDefaults` its caller passes in, and a test that
stores the setting under its real key accepts it. The aim was to lead the plan to an acceptance row.

**Verdict: the bar is NOT met.** The code side passed. All 5 tasks merged, `final` is GREEN, and the run was
one-shot: no resume and no human input. The validation layer now reaches the device, but only 1 of the 3 layers got a
real result:

- **Flow.** Met, with a caveat. Row 1 got a real `red` from `qa run` twice. Every one of its 8 steps passed. The red
  comes from `sim verify`'s accessibility audit: 183 findings, and all but 1 are on controls the app already had
  (finding 1).
- **State.** Not met. Row 3 read `unverified` at both runs, because row 1, a flow row for another requirement, was red
  (finding 3).
- **Acceptance.** Not met in substance. The plan had 1 acceptance row, and `qa run` read it `red`, but only with
  exit 126: it ran the test file's path as a shell command. The orchestrator then turned the row into a reason-only
  row (finding 2).
- **Evidence alone.** Met: no row passed.

## Measures

| Measure | This attempt | First attempt | Source |
|---|---|---|---|
| Clone to discovery | clone and reset 2 s (22:04:24Z to 22:04:26Z); `discover --apply` 59 ms | 2 s; 82 ms | `clock.log`, `discover.run` 22:04:32Z |
| Launch | 22:05:23.5Z | 21:08:19.2Z | `clock.log` |
| Wall time to the plan | **108 s** (1.8 min): the `plan` span ended at 22:07:11.2Z. `plan import` ran at 22:08:32Z (189 s), after the contract's slice | 154 s | `span.end` `a27d1130fbff0a6c` |
| Wall time to the first prepared check | **321 s** (5.4 min): the validation worker wrote both flows, `qa lint` GREEN at 22:10:34Z, and the state script by 22:10:44Z. The first red run on a device was at 22:20:37Z (914 s), and all 3 were red by 22:22:13Z (1010 s). `qa adopt` ran at 22:25:30Z (607 s). No `qa run --at-base` ran (finding 5) | 241 s to the files; `qa run --at-base` at 308 s, red for a missing input; no device run | `validation-worker.jsonl` timestamps; `build-events.jsonl` |
| Wall time to the end | **1875 s** (31.3 min), launch to exit at 22:36:38.6Z, all of it active. The cutoff never came | 1592 s, including 303 s while the session was dead; 1289 s active | `clock.log`, `run.jsonl` |
| Cost | **$4.71**: `claude-opus-5-5` $4.17 (orchestrator, validation worker, fixer), `claude-sonnet-5-5` $0.53 (build workers). The 4 `judge` calls are extra | $4.67 | final `result` `total_cost_usd` 4.7087; `agent.usage` events sum to 4.7087 after ingest |
| Human input | **0**: no resume, no `AskUserQuestion` | 1 resume | `run.jsonl`: 3 `result` lines, 1 session `d97ceed8-…` |
| Halts | **0** `build.halt`, and no session exit. 1 RED merge gate went to the fixer. The orchestrator wrote 1 "Halt:" decision into the plan: it kept the merge after a RED `qa run` (finding 7) | 2: the session exit and a `question` halt | `events.jsonl`, `run-report.txt` |
| Warm-up | build passed in 66.1 s and test in 75.1 s, both cold, so the area is build-only at `slice` (75 s is over the 30 s budget) | build failed in 21 s on plugin validation | `warmup.run` 22:07:44Z |
| Load | 1-minute load average 8.3 to 950 during the run | 3.6 to 237.5 | `uptime.log` |

## Validation rows

`validation.json` as imported held 4 rows. The acceptance row was later removed, so the final file holds 3 rows
and 2 reason-only requirements.

| Row | Requirement | Layer | Check | Validation worker's red run (direct `agent-device batch`, before merge) | `--after download-check`, `20261004T221455Z-5a2478e2` | `--after download-setting`, `20261004T222811Z-0be8aeb0` | final `qa run`, `20261004T223404Z-be50ef8e` |
|---|---|---|---|---|---|---|---|
| 4 | req-check | acceptance | `AidokuTests/LargeDownloadConfirmationTests.swift` | — | **`red`**, exit 126 in 10 ms: `/bin/sh: AidokuTests/LargeDownloadConfirmationTests.swift: Permission denied`. Evidence: `qa-runs/20261004T221455Z-5a2478e2/04-req-check.acceptance.txt` | row removed; re-run `20261004T221536Z-736acf17` read "no validation row to run" | — |
| 1 | req-setting | flow | `qa/confirm-large-downloads-toggle.flow.json` | red at step 6: `wait id="settings.downloads.confirmLargeDownloads"` timed out (missing element). Steps 1 to 5 passed | — | **`red`** in 131 s. All 8 steps `ok`, through `is exists id=… value="0"`. `sim verify` RED on 183 audit findings: 103 `sim.a11y-identifier` and 80 `sim.a11y-label`. 1 of them is on the new switch: "Switch settings.downloads.confirmLargeDownloads has no readable label" | **`red`** in 68 s, same steps and findings |
| 2 | req-stored | flow | `qa/confirm-large-downloads-stored.flow.json` | red at step 5: the toggle is missing | — | `unverified` in 54 s: "agent-device batch printed unexpected output (exited(1)): unknown failure reason \"covered_by_interactive_descendants\" for COMMAND_FAILED". `flow.json` shows only step 1 with `ok: false`, and no batch output was kept (finding 4) | `unverified` in 51 s, same |
| 3 | req-stored | state | `qa/confirm-large-downloads-stored.state.sh` | red, exit 1: "expected Downloads.confirmLargeDownloads = true … found <unset>". It passed once the worker wrote `true` by hand | — | `unverified`: "not run: the flow layer has a red row" (finding 3) | `unverified`, same |
| — | req-prompt | none | — | reason: "needs a source with more than 50 chapters on the simulator" | | | |

`qa run --after download-prompt` (`20261004T221914Z-a64747f0`) read "no validation row to run". The 2 reports with
rows read `RED` with "1 of 3 rows verified: 0 pass, 1 red, 2 unverified". The run report's second line is
`validation: 1 of 3 rows verified (qa run 20261004T223404Z-be50ef8e, RED)`. Each run recorded both `qa.flow` events,
4 in all.

Against the bar:

| Bar | Result |
|---|---|
| ≥ 1 acceptance row with a real `qa run` result | FAIL in substance: 1 `red`, from exit 126 on a non-executable path, then the row was removed |
| ≥ 1 flow row with a real `qa run` result | PASS, with a caveat: row 1 `red` at both runs. It is a real device run, but the red comes from pre-existing audit findings |
| ≥ 1 state row with a real `qa run` result | FAIL: `unverified` at both runs |
| No row passed on evidence alone | PASS: no row passed |

## Every merge

| Task | Commits | Merge gate | Review |
|---|---|---|---|
| `contract` | `44bb1793` | `slice` GREEN `20261004T220725Z-92bf2bf0` (58.5 s): `area.build-only`, and `area.step-dropped` for lint, "its command's tool isn't installed (exit 127 …)" | contract |
| `download-check` | `813e4859`, `549d68cc` → merge `b71d5139` | GREEN `20261004T221216Z-eaf52a3b` (141.5 s); prove: the new test fails with the source reverted | diff-risk `low` |
| `download-prompt` | `c7020100` → merge `3f80ed1a` | GREEN `20261004T221601Z-5d20dcd0` (182.9 s) | diff-risk `medium`: 1 review stage (4 s) |
| `download-setting` | `6ab765a9` → merge `39afac31` | RED `20261004T221928Z-4ecfb04f` (116.8 s): its new test didn't compile, since its slice only built. `build merge --undo`, then the fixer's `01e4ba07` → merge `f7e10b00`, GREEN `20261004T222546Z-078a354c` (139.2 s) | diff-risk `low` |
| `spec-validation` | none; `qa adopt` at 22:25:30Z | — | — |
| `final` | `f7e10b00` | GREEN `20261004T223202Z-ba27a3d3` (114.2 s), then `qa run` RED | — |

## Fixes from the first attempt, checked

| First-attempt finding | Now |
|---|---|
| 1, `sim up` ignores the brownfield config | **Fixed.** The validation worker's 4 `sim up` calls were GREEN; the first, with a cold app build under load near 490, took 332 s. `qa run` held a device for rows 1 and 2 at both runs |
| 2, the headless session exits on background work | **Fixed.** Every gate and `qa run` ran in the foreground. The session stayed alive across 3 turns and exited only at the end |
| 3 and 12, all-`unverified` reads GREEN; no verified count | **Fixed.** `qa run` and the run report say "1 of 3 rows verified" and `RED`. The validation worker returned each check's recorded failure |
| 4, a state row runs at base with no device | Not exercised: no `--at-base` run. After the merge, the state row read `unverified`, but for a new reason (finding 3) |
| 7, a missing SwiftLint is absorbed | **Fixed.** The contract slice reported `area.step-dropped` "tool isn't installed (exit 127)". The orchestrator then dropped the lint step with `discover --apply --set` |
| 8, discover omits `-skipPackagePluginValidation` | **Fixed.** Discover wrote the flag, and the launch's warm-up passed on its first try |
| 10, an absolute path in `report.html` | **Not reproduced.** `report.html` has 0 matches for `/Users`, `/private`, `/var/folders` or `/tmp/`, with no redaction |
| 11, gate output in shared `/tmp` | **Fixed.** Gate and `qa run` JSON went to `<plan-dir>/out/`. The one `/tmp` write, by the validation worker, was refused by `guard.subagent-outside-checkouts` |

## Harness findings

Ranked by how much they block the validation layer.

1. **In a brownfield app, `sim verify`'s accessibility audit makes every flow red, whatever the change does.**
   - Row 1 passed all 8 steps. It still read `red` on 183 `sim.a11y-identifier` and `sim.a11y-label` findings
     against the tab bar ("Library", "Browse", "Settings" …) and the existing settings cells and switches. 1 finding
     is about the change: the new switch "has no readable label". Aidoku's `SettingView` hides every toggle's label
     the same way.
   - The orchestrator called the findings baseline and kept the merge. So in practice the red gated nothing, and a
     real regression in the flow would look the same.
   - Files: the audit rules in `sim verify` (`SimVerify`, rule ids `sim.a11y-identifier` and `sim.a11y-label`), and
     how `QAFlowRunner` turns its verdict into the row's result.
   - Suggested fix: in a brownfield profile, audit only elements that are new against the base build, or record the
     base tree's findings as a baseline the way gates do. Keep the audit as a note, not the row's result, when every
     functional step passed.
   - Test: a fixture tree with pre-existing unlabeled controls, plus 1 new labeled control, yields `pass` when the
     steps pass.
2. **An `xcode` area can't express an acceptance row that `qa run` will run.**
   - `plan-shape.md` says an acceptance check "is a test in the area's framework". The orchestrator put the test file
     in `Check`, and `plan import` accepted it. `qa run` ran it with `/bin/sh` and got exit 126.
   - The orchestrator then tried `xcodebuild test … -only-testing:AidokuTests/LargeDownloadConfirmationTests`. The
     `guard.raw-xcodebuild` hook refused the Bash call, though the call only wrote that text into `PLAN.md` through a
     heredoc. It then made the row reason-only, citing the merge gate's prove.
   - Files: the acceptance branch of `Checks.run` in `plugin/gate/Sources/SwiftGateCLI/Commands/QARunCommand.swift`;
     the validation rules in `plan import`; `plugin/skills/run/references/plan-shape.md`; and the raw-xcodebuild
     matcher in the guard hook.
   - Suggested fix: for an `xcode` area, run a test-path `Check` through the area's test command, limited to that
     test, under `swiftgate`'s DerivedData and simulator lock. Or `plan import` rejects a `Check` that is a source
     file. The guard should match commands it would execute, not heredoc text.
   - Test: a validation row whose `Check` is `AidokuTests/X.swift` either imports and runs as the area's test limited
     to `X`, or fails `plan import` naming the line.
3. **A state row waits on any red flow row, not on its own requirement's flow.**
   - Row 3 (req-stored) read "not run: the flow layer has a red row". The red row was row 1 (req-setting). Its own
     flow, row 2, was `unverified`, so `qa run` would have skipped the row either way. But the reason it gives is wrong,
     and row 1 would still have blocked a green row 2.
   - `plan-shape.md` says a state row "runs straight after a `flow` row for the same requirement and `Runs after`
     tasks".
   - File: the flow-to-state dependency in `QARunPlan.execute`, `QARunCommand.swift`.
   - Test: flow row A red, flow row B pass, state row for B's requirement → the state row runs.
4. **An agent-device failure reason swiftgate doesn't know turns a row `unverified` and loses the evidence.**
   - Row 2 failed with `covered_by_interactive_descendants`, from agent-device 0.21.18. The likely cause is step 6:
     pressing the toggle by `id=`, where the SwiftUI accessibility node covers an interactive `UISwitch`. The worker's
     pre-merge red stopped at step 5, so step 6 never ran before the merge.
   - The row kept no `batch.json`. Its `flow.json` shows step 1 with `ok: false`, which is wrong. The failure
     happened twice, in the same way.
   - Files: the batch output parser behind `BatchFlowRunner` and `LiveQAFlowSimulator`.
   - Suggested fix: map an unknown `COMMAND_FAILED` reason to `red` at the step it names, with the message. Always
     save the raw batch output.
   - Test: a captured batch output with an unknown reason yields `red` at its step, and the row keeps `batch.json`.
5. **The validation worker's red runs skip `qa run`, and the orchestrator skipped `qa run --at-base`.**
   - The worker drove each flow with raw `agent-device batch` on its own `sim up`, not with `qa run` or
     `sim verify`. So the audit red (finding 1) and the press failure (finding 4) first showed only after the merge.
   - The orchestrator's summary says: "I didn't run the step that confirms each check fails before its task merges."
     By the time `qa adopt` took the checks, 2 tasks had merged.
   - Files: `plugin/skills/qa/references/validation-worker.md`, and the validation-task and at-base steps in
     `plugin/skills/run/SKILL.md`.
   - Suggested fix: the worker records its red run through `qa run --at-base` (or `sim verify`), so the run uses the
     same judge as after the merge.
6. **The validation worker took 13 minutes.** It ran from 22:09:21Z to 22:22:33Z, with 4 `sim up` calls and a cold
   app build each time. Its checks were ready only after `download-check` and `download-prompt` had merged. No row
   was due on those 2 merges, so the delay cost nothing here, but on a plan whose first merge has rows it would.
   Reusing 1 device across the 3 red runs (`sim hold`) would save about 3 builds.
7. **A RED `qa run` halts nothing.** After `--after download-setting` read RED, the orchestrator kept the merge on
   its own judgement. It wrote a "Halt:" bullet into `## Assumptions`, but the run recorded no `build.halt` and
   queued no fixer. That may be right here (finding 1), but no rule says what a validation red should do.
   - Files: `## After each merge` in `plugin/skills/build/references/event-loop.md`.
8. **Prove at merge measures against the plan base, not the merge's first parent.** Every `prove.result` has
   `proofBase` `3091ef26`. `download-prompt`'s merge reported "1 of 1 changed tests fail with the change's source
   reverted", though that task changed no test: the test was `download-check`'s. Low impact, but the count is wrong.
9. **Build-only slices move the first test run to the merge.** The warm test is 75 s, over the 30 s budget, so
   `download-setting`'s slice only built. Its new test failed to compile at the merge, which cost 1 RED gate, an undo
   and a 4-minute fixer. This is the same pattern as the first attempt's `settings-toggle`.

## Deviations

- **None in the run itself.** It was one-shot with no resume and no prompt after launch. I patched neither the
  clone nor the harness.
- **Launch.** As in the first attempt: `spec.md` outside the clone, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, and
  1 machine build slot held for the session.

  ```sh
  swiftgate run start spec.md -- -p --output-format stream-json --verbose \
    --plugin-dir <branch>/plugin --dangerously-skip-permissions
  ```
- **SwiftLint not installed**, as in the first attempt, so the run tested the fix for finding 7.
- **Post-run ingest.** `swiftgate events ingest --session d97ceed8-… --role orchestrator --build-run
  20261004T220851Z-be64ead3` read 22 new messages. I exported `events.jsonl` after it.
- **`report.html`** is `swiftgate report --html 20261004T220851Z-be64ead3`, unedited.
- **Cleanup.**
  - I deleted the clone and its 12 DerivedData directories (22.4 GiB), each matched to the clone by its
    `WorkspacePath`. The run's worktrees were already gone.
  - The run made 8 simulator clones: 4 by the worker's `sim up`, and 1 per flow row in each of the 2 `qa run`s. None remains, and no
    `agent-device` session or sim lease remains. The simulator list matches the one taken before the run.
  - I touched no other simulator.

## Files

| File | What |
|---|---|
| `spec.md` | the spec, byte-identical to the plan dir's copy |
| `discover-apply.json`, `config.toml`, `warmup.log` | the first discovery, the clone's config after the run (lint dropped), and the launch warm-up's log |
| `run.jsonl`, `run.stderr`, `clock.log` | the session's stream-json, `run`'s stderr, and my launch clock |
| `validation-worker.jsonl` | the validation worker's transcript, with its red runs and return |
| `events.jsonl` | `swiftgate events list` after the ingest: 420 events, including 7 `qa.check` and 4 `qa.flow` |
| `PLAN.md`, `plan.json`, `validation.json`, `ledger.json` | the final plan, its import, the validation table, and the ledger |
| `qa/` | the 3 adopted checks |
| `qa-runs/<runID>/` | every `qa run`'s `report.json` and row evidence (steps, `flow.json`, `sim/report.json`, step screenshots and trees; no `.xcresult` or build log) |
| `gates/` | each slice, merge and `final` gate report, and each `qa run`'s JSON, from `<plan-dir>/out/` |
| `build-events.jsonl`, `returns/`, `gate-history.jsonl` | the build run's transitions, merges, undo and gates; each task's return; the clone's gate history |
| `run-report.txt` | the plan's `REPORT.md` verbatim |
| `report.html` | the build run's page |
| `uptime.log` | load averages every 15 s |
