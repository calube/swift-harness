# Brownfield trial: usememos/memos, fourth attempt

This attempt reruns the brownfield trial (design §14) on `usememos/memos` at
`0d989707f82c33f74bb852edd8965ec88fcf041b`. The clone is fresh, made on 2026-10-04 at `trials/memos-4`. It uses
the same `spec.md` as [the third attempt](../memos-3/README.md), byte for byte: a view limit on memo share links.
The harness ran from this branch's `plugin/bin/swiftgate`, which is main at `f98b1f49`.

**Verdict: the one-shot run is INCOMPLETE, with 0 merges and no `final`.** The memos-3 blocker is gone: `build
check-return` passed a brownfield `slice` return (the store task's), and passed the contract's. Two new problems
stopped the run instead:

- The web worker returned `surfaceCommit` as `"\"7c3becaa\""`, a sha wrapped in literal quotes. `check-return`
  rejected it (finding 1).
- The store worker reported a design conflict: a guard test outside its write set breaks once the first calendar
  migration exists. The brownfield preset's `on_design_conflict = "block"` recommends **stop**, and the run
  skill takes the recommended option. So the build stopped with no merge and no `final` (finding 2).

Clone to first gate passes (15.1 s). The untouched-code checks pass. The `slice` p95 fails the 30 s bar both
before the warm-up (73.5 s) and in steady state (38.2 s). The 1-minute load average stayed between 34 and 130 for
the whole run, so no gate ran under a load below 30. The run asked the user nothing, and no guard denied a worker
write.

## Measures

| Measure | Value | Bar | Result | Source |
|---|---|---|---|---|
| Clone to first gate | 15.1 s. `git clone` and the reset to the pinned commit took 13.2 s, from 14:04:22.85Z. `discover --apply` took 0.8 s (`discover.run` `ms` 424), then `slice` on an empty commit took 0.63 s | under 3 min | PASS | `gate.run` `14003082-91B8-441F-8DF0-B3D6F9FFE5F0`, run `20261004T140437Z-ec1149c7`, at 14:04:37.995Z |
| Findings on untouched code, empty commit | 0 | 0 | PASS | `slice-empty.json`, `gate.run` `14003082-…`, `ruleCounts {}` |
| Findings on untouched code, 1-line change | 0 on code. There was 1 `area.build-only` nit with no line: the warm-up hadn't measured the Go tests yet. The change was 1 comment line at the end of a Go file under `store/` | 0 | PASS | `slice-one-line.json`, `gate.run` `FF241661-…`, run `20261004T140448Z-b0dff61d`, 73.5 s cold. Its `area-lint` step on `memos` took 71.6 s and ended RED on lines the change didn't add, so it made no finding |
| `slice` p95, before the warm-up | 2 samples: 0.63 s and 73.5 s, so p95 is 73.5 s. The 1-minute load was 92 to 96 | 30 s or less | FAIL (cold probes, under load) | `gate.run` `14003082-…` and `FF241661-…`; `uptime` lines in `timing` below |
| `slice` p95, during the warm-up | 0 samples. The warm-up ran from 14:06:25Z to 14:07:12Z, and no gate ran then | 30 s or less | no data | `warmup.run` `62831126-…`, `EDF7B6C5-…`, `A174B3D8-…`, `68F409C8-…` |
| `slice` p95, steady state | 4 samples: 0.10 s (the Stop hook, empty diff), 27.6, 33.7 and 38.2 s. The nearest-rank p95 is 38.2 s, with or without the Stop hook's sample. The 1-minute load at each sample was 58, 58, 58 and 50 to 58 | 30 s or less | FAIL | `gate.run` `34A98736-…` (27.6 s, 14:11:50Z, contract in the plan checkout), `DC61E895-…` (38.2 s, 14:16:18Z, contract in its own worktree), `F7CE4F12-…` (Stop hook), `F4CDE0A2-…` (33.7 s, 14:18:34Z, the web task). See "Slice time" below |
| `slice` p95, steady state, load below 30 | 0 samples. The lowest 1-minute load in the run was 33.95 at 14:12:29Z, when no gate ran | 30 s or less | no data | `uptime.log` |
| One-shot run | Contract commit `6fc0cb61` on `swift-harness/spec`. 0 merges: all 3 feature tasks are blocked. No `final` ran; the report says `final: not recorded`, and the run view still shows the build run as `running` | `spec.md` to a plan branch, every merge and `final` GREEN, 0 human input | FAIL (INCOMPLETE) | `run-report.txt`, `ledger.json`, `build-events.jsonl`; no `gate.run` with `command = check final` exists |
| Human input | 0. The session made no `AskUserQuestion` call; the name appears only in skill text it read. The stream holds no user message other than tool results. Each of its 4 turns ended with `stop_reason: end_turn`; turns 2 to 4 started on workflow and background-task notifications | 0 | PASS | `run.jsonl` (4 `result` lines, session `a7e1495d-74fe-474b-baf4-ad95d6f7bc65`); `build.halt` `6D09B64D-…` and `09B29326-…`, `build.resume` `F1C1BD47-…` and `0D63B09C-…` |
| Worker writes denied | 0. The only blocks were 2 `guard.reviewer-bash`, by design | 0 | PASS | `hook.decision` `B2CB13D7-…` and `9A232093-…` |

## Every merge

None. The contract went to `done` in the ledger through `ledger set` (pending, then in-progress, then done) after
the orchestrator landed it, and no task reached `build merge`. The task branches still hold the work:

| Task | Branch, commits | Task gate | Ledger |
|---|---|---|---|
| `share-view-limit-contract` | `swift-harness/spec` `6fc0cb61` | `slice` GREEN `20261004T141123Z-945b3a7e` (27.6 s) and `20261004T141540Z-be184a1a` (38.2 s); `merge` GREEN `20261004T141215Z-31ad3958` (147.1 s, `gate-merge-contract.json`) | done. Its return is hand-built by the orchestrator, and `check-return` passed it (finding 3) |
| `share-view-limit-store` | `spec/share-view-limit-store` `8daa17c7` | none: the worker returned `design-conflict` without gating | blocked |
| `share-view-limit-web` | `spec/share-view-limit-web` `7c3becaa` (surface), `a0030881` | `slice` GREEN `20261004T141801Z-79b9bebf` (33.7 s) | blocked, `check-return` RED `build-return.surface-commit-off-branch` |
| `share-view-limit-api` | none | none | blocked, because it depends on the store task |

## Halts

| Halt | Task | Reason | Answer, by whom, wait |
|---|---|---|---|
| `6D09B64D-94A1-46A6-B975-D10B20FABED0`, 14:23:28.9Z | `share-view-limit-web` | `question`: `check-return` RED, `build-return.surface-commit-off-branch` | `continue` (go on without it, the recommended option), by the orchestrator, 43 ms |
| `09B29326-2E70-410C-B1C1-7A1E1138D70F`, 14:23:59.2Z | `share-view-limit-store` | `amend`: a `design-conflict` return under `on_design_conflict = "block"` | `abandon` (stop the build, the recommended option), by the orchestrator, 133 ms |

The web halt landed about 4 minutes after the web workflow finished. Its `ledger set`, `build halt` and `build
resume` calls waited 212 s for the shim to rebuild `swiftgate` (finding 4).

## Slice time

Each steady-state slice built both areas and ran `golangci-lint` on all of `memos`, with no tests, because both
warm test runs took longer than the 30 s budget (`memos` 39.6 s, `web` 34.7 s, both cold under load).

| Slice | `area-lint memos` | `area-build web` | `area-lint web` | `area-build memos` |
|---|---|---|---|---|
| `945b3a7e`, 27.6 s | 24.3 s | 10.2 s | 3.0 s | 3.0 s |
| `be184a1a`, 38.2 s | 35.6 s | 19.9 s | 11.5 s | 1.9 s |
| `79b9bebf`, 33.7 s (web only) | — | 30.7 s | 2.6 s | — |

The steps run in parallel, so the longest step sets the time. On `memos` that is lint, as in memos-3. On `web` it is
the build, because the orchestrator set every web command to run `pnpm install --frozen-lockfile --prefer-offline`
first: a fresh task worktree has no `node_modules`.

## Which binary ran

This branch's binary, by hash `d98217149be9bd88`. The events still can't show it, because no payload carries a
binary path or source hash (known). The evidence:

- Every `swiftgate` call in the orchestrator's Bash commands went through this branch's `plugin/bin/swiftgate` by
  absolute path, and the session loaded this branch's `plugin/` with `--plugin-dir`.
- The user cache's stamp and `last-good` for this branch's `gate/` both hold `d98217149be9bd88`, from 14:03Z.
- `events.jsonl` has no `hook.decision` pair with the same `inputHash` and event.
- That binary went missing from the shared user cache during the run, and the shim rebuilt it from 14:19:30Z to
  14:23:02Z (finding 4). In that window the shim ran hooks on the newest binary in the cache, which may have come
  from another worktree.

## Other numbers

- Wall time, from launch to exit: 1077.7 s (14:06:25.2Z to 14:24:22.8Z). API time was 474.1 s, over 4 turns of 56,
  6, 3 and 6 steps.
- Cost: $3.35 (the `result` line's `total_cost_usd`). The `agent.usage` events add up to $3.18: the orchestrator on
  `claude-opus-5-5` $2.33, and the 2 workflows $0.85 ($0.58 on `claude-sonnet-5-5`, $0.27 on `claude-opus-5-5`).
  The orchestrator ingested each workflow as it finished but not its own last turn, which accounts for the
  $0.17 gap. I didn't ingest after the run.
- Warm-up, from `warmup.run` events, all `cold`:
  - `memos`: build passed in 2.0 s, and test failed in 39.6 s (the same baseline failure as memos-3).
  - `web`: build passed in 11.6 s, and test failed in 34.7 s.
- Build lock: I held a ticket from 14:06:18Z, before launch, until the warm-up process exited at 14:07:12Z
  (`lock.log`). The 1-minute load was 34 to 46 then.
- `--set`: at 14:09:41Z the orchestrator ran `discover --apply` with 6 sets (`discover.run` `35AC7649-…`,
  `edited: 6`): `memos.test` and `memos.test_files` with `DRIVER=sqlite`, and the `pnpm install` prefix on 4 web
  steps.
- Guard denials: 2 `guard.reviewer-bash` blocks, by design. No `guard.build-agent-main-checkout` denial this time.
  The memos-3 denials of a worker's relative write after `cd <its worktree>` are gone.
- Session records: `events ingest` worked from the plan checkout (`73 messages read, 73 new` for the web
  workflow), so the memos-3 session-record fix holds.

## What happened

1. `discover --apply` found 2 areas, `web` (TypeScript, pnpm) and `memos` (Go, `go test -json`): 7 found
   commands and 1 guessed.
2. `swiftgate run start spec.md` copied the spec, applied discovery, started the warm-up, claimed the plan lock for
   session `a7e1495d` and launched `claude`.
3. The orchestrator read the code itself, with no explorers, in 42 s. It made the plan checkout, ran the Go and web
   tests there to see the baseline failures, and fixed the commands with `--set`.
4. It wrote `PLAN.md` with 4 tasks in 3 waves, 8 requirements and 9 assumptions (3 more came later). It landed the
   contract `6fc0cb61`: proto fields with regenerated Go and TypeScript, store fields, and a stubbed
   `ConsumeMemoShareView` in each driver. The contract was GREEN at `slice` (27.6 s) and at `merge` (147.1 s).
5. It ran `plan import` and `build start`. `build next` offered the contract task, which the orchestrator had already landed.
   `ledger set … done` refused `pending -> done`. The orchestrator walked it through `in-progress`, made a worktree
   for it so `check-return` would read it, hand-wrote a return with a `classified` review, and copied that return
   into the build run's `returns/`. Only then did `context-pack` build the dependents' packs (finding 3).
6. It launched the store and web `build-task` workflows. The web worker finished its slice GREEN with 1 verified
   minor review finding at `medium`. Its return's `surfaceCommit` (and its `span`) came back wrapped in literal
   quotes. The workflow logged the bad span but passed the bad `surfaceCommit` through, and `check-return` rejected
   it.
7. The store worker wrote migrations for all 3 drivers, `ConsumeMemoShareView` with a conditional UPDATE, and 4
   tests. Then it returned `design-conflict`: `store/test/migrator_guardrail_test.go`, outside its write set, has a
   `calver-newer` case at schema 26.9.1, which the first 26.10 migration makes older than the latest schema.
8. The orchestrator blocked the store and API tasks, took **stop**, and wrote the report. It ran neither `final` nor
   `build finish`. The plan checkout and the store and web worktrees remain beside the clone.

## Harness findings

1. **A worker's quoted `surfaceCommit` passes the workflow and fails `check-return`.** In `plugin/workflows/build-task.js`, the TaskReturn schema types `surfaceCommit` (and `span`) as
   `['string', 'null']` with no pattern. The validator accepts any non-empty string (`r.surfaceCommit !== null &&
   !nonEmptyString(…)`). The Sonnet worker emitted `"\"7c3becaa\""` and `"\"5f3dd61c7f24263c\""`. The workflow
   caught the span (`span: the worker stage returned "\"5f3dd61c7f24263c\"", not a span id`) but not the sha.
   - Evidence: `worker-journals.jsonl` (the web workflow's result and logs); `check-return` output in `run.jsonl`;
     halt `6D09B64D-…`.
   - Suggested fix: give `surfaceCommit` a `pattern: '^[0-9a-f]{7,40}$'` in the schema, and have the validator
     reject a non-hex value, so the worker stage retries. Or strip 1 layer of matching quotes from both
     fields before validating, and log it. Test: a worker result with a quoted sha fails `validateReturn` naming
     `surfaceCommit`.
2. **A design conflict ends a one-shot run with no merge and no `final`.**
   - `SwiftGateDomain/Brownfield/Discover/Discover.swift` writes `on_design_conflict = "block"` into
     `[build.presets.brownfield]`. The build skill's block flow recommends **stop**
     (`plugin/skills/build/references/event-loop.md`, "Design conflict"). The run skill takes every recommended
     option, and "an option that stops the build ends the run at step 9 with the report"
     (`plugin/skills/run/SKILL.md`). So `final` and `build finish` never run, and the run view keeps the build run
     `running`.
   - The conflict was a write-set gap the orchestrator could fix itself: add 1 test file to the task and retry.
   - Evidence: the store workflow's `designConflict` in `worker-journals.jsonl`; halt `09B29326-…` answered
     `abandon`; `run-report.txt` (`final: not recorded`).
   - Suggested fix: in a brownfield run, a `slices` design conflict that names files outside the write set should
     recommend **retry**, with the orchestrator widening the task's `Writes:` in `PLAN.md` and re-importing.
     Whatever the answer, the run skill should still run `final` on the plan branch and `build finish`, so the
     report always carries a `final` verdict.
3. **A contract the orchestrator landed before import has no supported path to `done`.**
   - The run skill lands the contract before `plan import`. The import still lists it `pending`, and `ledger set …
     done` refuses `pending -> done`. Dependent workers' `context-pack` needs a checked return for it, and
     `check-return` needs the task's own worktree and a review. The orchestrator spent 18 tool calls (about 2.3
     minutes, 14:14:45Z to 14:17:08Z) forging a worktree, a return and a review record for a commit its own
     `slice` and `merge` gates had already passed.
   - Evidence: `run.jsonl` (`ledger set` refusal, `check-return` `has no worktree`, then
     `build-return.review-missing`, then GREEN); `PLAN.md` assumption 8.
   - Suggested fix: have `plan import` take the contract commit (from the plan branch, or from a `--contract <sha>`
     flag) and record the contract task `done`, with that commit and its `slice` run id as its return.
     `context-pack` would then read it like any other return.
4. **The shared user cache lost this branch's `swiftgate` binary mid-run, so the shim rebuilt it for 212 s.**
   - The orchestrator's next `swiftgate` call at about 14:19:30Z found no `bin/d98217149be9bd88/swiftgate` and
     rebuilt it into the shared `build/release` scratch path. It then waited on another SwiftPM process holding that
     path. The stamp and `last-good` still named the hash from 14:03Z, so something outside this run deleted the
     binary. The orchestrator's halt commands sat behind that rebuild, and meanwhile the hooks ran the newest binary
     in the cache, whichever worktree built it (`plugin/bin/swiftgate`, `previous_binary`).
   - Evidence: `<user cache>/build-d98217149be9bd88.log` (`Build complete! (212.26s)`); the orchestrator's
     background task output in `run.jsonl` (`Another instance of SwiftPM … is already running`).
   - Suggested fix: the per-worktree cache already in flight. Until then, the shim should never fall back to a
     binary built from other sources for a hook.
5. **Diff-risk never answers in a fresh clone, and the report says "Review fallbacks: none".**
   - `Discover.swift` writes `judge: existing?.judge ?? .disabled` on first discovery, so `[judge]` is absent, and
     `swiftgate judge diff-risk` answers `{"level":null,"reason":"the clone's config has no [judge] section"}`
     (`SwiftGateCLI/BrownfieldJudge.swift`). Every task falls back to `medium`, and design §11.5's Jev rating never
     happens.
   - `SwiftGateDomain/Brownfield/BrownfieldRunReport.swift` still prints "Review fallbacks: none", because it
     counts only merged tasks (memos-3 finding 4, still open).
   - Suggested fix: have the first discovery write a `[judge]` section, or have `run start` write it when Jev answers
     its health check. In the report, count every task whose review ran.
6. **The report lists each baseline failure twice** (known): `memos test: …TestEntrypointDoesNotLoopWhenTargetUIDIsRoot` and `web test: the whole step`, 2 times each (`run-report.txt`).
7. **Web tests still baseline as the whole step** (known). The 3 failing vitest cases sit in 1 time-zone-dependent
   test file, so at `merge` no web test failure can gate.
8. **The run view drops the web task's GREEN slice.** `swiftgate report --json` lists 1 gate (`be184a1a`). It
   leaves out the web task's `79b9bebf`, because a rejected return links no `gateRun`. The task looks gateless
   in `report.html`. Suggested fix: the view should also list task-worktree gates by run id from the returns
   journal or the worktree's history.
9. **Slice p95 misses the budget on Go lint and the web build** (known, not a bug). `golangci-lint run ./...` took
   24 to 72 s, and the web build with its `pnpm install` prefix took 10 to 31 s. Scoping lint to the changed
   packages would put the Go slices under 15 s. Running install once per worktree, at `worktree create`, would keep
   it out of every slice.

`report.html` has no absolute local path: `grep /Users/` finds 0 matches, and nor does a search for the user name,
`/private/`, `/tmp/` or `.claude/`.

## Deviations

- **No post-run ingest.** Unlike memos-3, the run's own ingests worked. I left the orchestrator's last turn
  uningested, so `events.jsonl` sums to $3.18, not $3.35.
- **`claude` on `PATH`.** As in memos-2 and memos-3: node 22's `bin` goes after `mise`'s entries.
- **Launch flags.** As in memos-3, with `spec.md` outside the clone and `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`:

  ```sh
  swiftgate run start spec.md -- -p --output-format stream-json --verbose \
    --plugin-dir <branch>/plugin --dangerously-skip-permissions
  ```
- **Probes.** I ran both probe gates on a throwaway `probe` branch with `--base main`, then deleted the branch before
  the launch.
- **No run past the stop.** I patched neither the clone nor the harness, and I didn't resume the session. The plan
  checkout, the task worktrees and their branches stay in place beside the clone.

## Files

| File | What |
|---|---|
| `spec.md` | the spec given to `swiftgate run`, byte-identical to memos-3's |
| `discover-apply.json` | the first discovery, right after the clone |
| `slice-empty.json`, `slice-one-line.json` | the probe gates |
| `run.jsonl`, `run.stderr` | the headless session's stream-json, and `run`'s stderr |
| `events.jsonl` | `swiftgate events list` after the run |
| `gate-history.jsonl`, `gate-history-task-worktrees.jsonl` | the clone's `runs/history.jsonl`, and the plan checkout's and web worktree's histories |
| `gate-merge-contract.json` | the contract's `merge` gate report (no `final` gate ran) |
| `build-events.jsonl`, `ledger.json` | the build run's ledger transitions and the final ledger |
| `worker-journals.jsonl` | the 2 `build-task` workflows' results and logs |
| `PLAN.md`, `run-report.txt` | the orchestrator's plan, and the plan's `REPORT.md` verbatim (plain text, so the prose gate doesn't lint generated output) |
| `report.html` | `swiftgate report --html 20261004T141445Z-85d15f09`, rendered from inside the clone |
| `warmup.log`, `config.toml`, `lock.log`, `uptime.log` | the warm-up log, the config after the orchestrator's `--set`, the build lock holder's log, and the 1-minute load every 15 s through the run |
