# Brownfield trial: usememos/memos, fifth attempt

This attempt reruns the brownfield trial (design §14) on `usememos/memos` at
`0d989707f82c33f74bb852edd8965ec88fcf041b`. The clone is fresh, made on 2026-10-04 at `trials/memos-5`. It uses
the same `spec.md` as [the fourth attempt](../memos-4/README.md), byte for byte: a view limit on memo share links.
The harness ran from this branch's `plugin/bin/swiftgate`, which is main at `f984f367`, built as source hash
`96c3af01c158ee4d`.

**Verdict: the one-shot run PASSES.** `spec.md` went to the plan branch `swift-harness/spec` at `587495a1` with all
4 tasks done: the contract landed through `plan import --contract`, then 3 merges, each with a GREEN `merge` gate.
`final` is GREEN. The run asked the user nothing and raised no halt. It took 21 minutes and cost $4.32.

Every memos-4 blocker is gone. Workers returned unquoted shas, the contract went to `done` through `plan import`,
diff-risk rated every task, and no shim rebuild happened mid-run. The one RED merge gate (the web task broke the
repository's locale tests) went through the merge fixer and merged GREEN, with no halt.

Two bars still fail. The `slice` p95 misses 30 s before the warm-up (40.8 s) and in steady state (34.2 s), where
the slowest sample ran at a 1-minute load of 120 to 156. Under a load below 30, the 2 steady-state samples were 27.1 s
and 3.4 s, which passes. The harness findings below are new: none of them blocked the run.

## Measures

| Measure | Value | Bar | Result | Source |
|---|---|---|---|---|
| Clone to first gate | 3.7 s at most. `git clone` and the reset to the pinned commit ran from 16:01:10Z (whole-second clock) to 16:01:13.221Z. `discover --apply` took 0.17 s (`discover.run` `ms` 124), then `slice` on an empty commit took 0.20 s | under 3 min | PASS | `gate.run` `B9CC04A5-D462-47AD-8970-FDFA163B2F2C`, run `20261004T160113Z-0fdc35b8`, at 16:01:13.748Z |
| Findings on untouched code, empty commit | 0 | 0 | PASS | `slice-empty.json`, `gate.run` `B9CC04A5-…`, `ruleCounts {}` |
| Findings on untouched code, 1-line change | 0 on code. There was 1 `area.build-only` nit with no line: the warm-up hadn't run yet. The change was 1 comment line at the end of `store/memo_share.go` | 0 | PASS | `slice-one-line.json`, `gate.run` `D49EC643-5C51-4CEB-A810-A6F6998B33E7`, run `20261004T160127Z-4932a01b`, 40.8 s. Its `area-lint` step on `memos` took 38.6 s and ended RED on lines the change didn't add, so it made no finding |
| `slice` p95, before the warm-up | 2 samples: 0.20 s and 40.8 s, so p95 is 40.8 s. The 1-minute load was 14.5 to 22.2 | 30 s or less | FAIL (a cold Go lint) | `gate.run` `B9CC04A5-…` and `D49EC643-…` |
| `slice` p95, during the warm-up | 0 samples. The warm-up ran from 16:02:31Z to 16:04:13Z, and no gate ran then. The 1-minute load peaked at 192 | 30 s or less | no data | `warmup.run` `C3697ABD-…`, `C5F14364-…`, `302B3688-…`, `99F0F1DA-…` |
| `slice` p95, steady state | 8 samples: 3.4, 5.3, 6.9, 10.5, 20.1, 27.1, 29.3 and 34.2 s. The nearest-rank p95 is 34.2 s, the contract's slice at a 1-minute load of 120 to 156 | 30 s or less | FAIL | See "Slice time" below |
| `slice` p95, steady state, load below 30 | 2 samples where the 1-minute load stayed below 30 for the whole gate: 27.1 s (load 13.1 to 15.8) and 3.4 s (15.8). p95 is 27.1 s. Counting the 2 samples that touched 30.6, p95 is still 27.1 s | 30 s or less | PASS (2 samples) | `gate.run` `40BFB2CC-…` (run `20261004T161704Z-1cb7de82`) and `9A49CF52-…` (run `20261004T161734Z-4fbb2f5e`); `uptime.log` |
| One-shot run | Plan branch `swift-harness/spec` at `587495a1`: the contract and 3 merges, every `merge` gate on a merged commit GREEN, `final` GREEN. The report says `run: COMPLETE` | `spec.md` to a plan branch, every merge and `final` GREEN, 0 human input | PASS | `gate.run` `ABAEAAC4-92A8-44A2-9EEB-BF0150ABB185`, `command = check final`, run `20261004T162117Z-f3ed863d`; `build-events.jsonl`; `run-report.txt` |
| Human input | 0. The session made no `AskUserQuestion` call; the name appears only in skill text it read. The stream's 64 user messages are 63 tool results and the merge fixer's prompt, which carries a `parent_tool_use_id`. Each of its 3 turns ended with `stop_reason: end_turn`; turns 2 and 3 started on workflow notifications | 0 | PASS | `run.jsonl` (3 `result` lines, session `56eaccaa-db89-4023-ad6d-5c1a9e043420`); no `build.halt` event |
| Worker writes denied | 0 wrong denials. 11 blocks, all by design: 10 `guard.reviewer-bash`, and 1 `guard.subagent-outside-checkouts` when the merge fixer tried a scratch script in the system temp dir. It moved the script to `.harness/tmp/` in its worktree and went on | 0 | PASS | `hook.decision` `A76E664E-0F08-4B0D-BE8F-B00ACA21CD9C` and the 10 reviewer blocks from 16:09:00Z to 16:18:37Z |
| Gate events name this binary | 482 of 486 events carry `source.binary.sourceHash` `96c3af01c158ee4d`, the hash the shim printed when it built this worktree's binary. The 4 `warmup.run` events carry no `source` (finding 4) | every gate event | PASS for gate events; FAIL for `warmup.run` | `events.jsonl` |

## Every merge

| Task | Commits | Task gate | Merge | Merge gate | Review |
|---|---|---|---|---|---|
| `share-view-limit-contract` | `07b59425` | `slice` GREEN `20261004T160519Z-19e2cfc2` (34.2 s) | landed before import; `plan import --contract share-view-limit-contract --contract-run 20261004T160519Z-19e2cfc2` made it `done` | `merge` GREEN `20261004T160613Z-723391c1` (39.7 s) | none, as a contract |
| `share-view-limit-web` | `a25abae2` (surface), `20e3afcf`, fix `bae9f2f8` | `slice` GREEN `20261004T160825Z-8924b00e` (10.5 s) | `9f5c7a21` at 16:10:03Z, undone at 16:10:45Z; then `025d3cf0` (with `d17f7fef`) at 16:13:41Z | RED `20261004T161006Z-3c0f2ae2` (46 `area.test-failed`); fixer GREEN `20261004T161222Z-50cc3d46`; GREEN `20261004T161355Z-8a9c7da2` (34.0 s) | classified at medium |
| `share-view-limit-store` | `990fd862` | `slice` GREEN `20261004T160820Z-3c3ed983` (29.3 s, on a dirty tree; finding 2) | `97012540` at 16:14:42Z | GREEN `20261004T161445Z-aa86d7d2` (86.8 s) | classified at high |
| `share-view-limit-api` | `bceaeec9`, `0f470558` | `slice` GREEN `20261004T161750Z-62635ccf` (6.9 s), after 3 RED slices on a lint finding | `587495a1` at 16:19:14Z | GREEN `20261004T161914Z-7ee90012` (114.2 s) | classified at high |
| `final` | the plan branch at `587495a1` | — | — | `final` GREEN `20261004T162117Z-f3ed863d` (110.8 s); prove: 8 of 8 changed tests fail with the change's source reverted | — |

The web task's first merge turned the `merge` gate RED: `tests/locale-resources.test.ts` and
`tests/i18n-locale-search.test.ts` require every locale file to hold every English key, and the spec said other
locales may fall back to English. The orchestrator undid the merge and launched the build fixer on Opus. The fixer
added the 6 new keys, translated, to the 45 other locale files, and its own `merge` gate passed. Its return
failed `check-return` because the locale files sat outside the task's write set. The orchestrator widened the
write set in `PLAN.md`, re-imported the plan and checked the return again: GREEN. It ran `build merge --fix` in
the same Bash command as the first check, joined with `;`, so the merge landed 1 s after the RED check and 11 s
before the GREEN one (finding 1). The merged result passed its `merge` gate.

## Halts

None. No `build.halt` or `build.resume` event exists. The RED merge went through the build skill's fixer path,
which needs no halt.

## Slice time

Both areas' warm test runs took longer than the 30 s budget (`memos` 83.8 s, `web` 84.1 s, both cold at a load of up
to 192), so every slice built and linted with no tests. The task slices said so for another reason too: their base
tree had no warm-up (finding 3).

| Slice | Task | Time | Load | `area-lint memos` | `area-build memos` | `area-lint web` | `area-build web` |
|---|---|---|---|---|---|---|---|
| `20261004T160519Z-19e2cfc2` | contract, committed | 34.2 s | 120 to 156 | 24.6 s | 9.3 s | 3.5 s | 8.5 s |
| `20261004T160802Z-06104314` | web, RED | 20.1 s | 46 to 53 | — | — | not started | not started |
| `20261004T160825Z-8924b00e` | web | 10.5 s | 41 to 46 | — | — | 1.3 s | 8.9 s |
| `20261004T160820Z-3c3ed983` | store, dirty tree | 29.3 s | 37 to 46 | 26.8 s | 2.0 s | — | — |
| `20261004T161704Z-1cb7de82` | api, dirty tree, RED | 27.1 s | 13 to 16 | 24.8 s | 2.1 s | — | — |
| `20261004T161734Z-4fbb2f5e` | api, RED | 3.4 s | 16 | 1.4 s | 1.6 s | — | — |
| `20261004T161741Z-a36701fe` | api, RED | 5.3 s | 16 to 31 | 1.8 s | 3.4 s | — | — |
| `20261004T161750Z-62635ccf` | api | 6.9 s | 31 | 4.2 s | 2.4 s | — | — |

The steps run in parallel, so the longest step sets the time. Go lint dominates whenever it runs over many packages:
the contract touched store, proto and API code, and the 2 dirty-tree slices linted at 24.8 and 26.8 s. On a
committed change in 1 package it took 1.4 to 4.2 s. The web slice's RED run started in the worktree's `web/`
directory, not its root (finding 5). With `[judge]` set, no slice asked Claude about a no-assertion candidate in
this run: all 3 `judge.call` events are diff-risk.

## Other numbers

- Wall time, from launch to exit: 1266.0 s (16:02:29.8Z to 16:23:35.8Z). API time was 634.9 s, over 3 turns of 33,
  16 and 8 steps.
- Cost: $4.32 (the `result` line's `total_cost_usd`). After my ingest the `agent.usage` events add up to $4.32 as
  well: the orchestrator on `claude-opus-5-5` $2.17, and the workers $2.15 ($1.18 on `claude-sonnet-5-5`, $0.97 on
  `claude-opus-5-5`, which includes the merge fixer). The 3 diff-risk calls cost another $0.055, outside the
  session.
- Post-run ingest: the run ingested each workflow and the fixer, but not the orchestrator's own last turn: the
  events summed to $4.06. I ran `swiftgate events ingest --session 56eaccaa-… --role orchestrator --build-run
  20261004T160656Z-0ad8c7c2` after the run: `64 messages read, 6 new`. I exported `events.jsonl` after it.
- Warm-up, from `warmup.run` events, all `cold`:
  - `memos`: build passed in 2.8 s, and test failed in 83.8 s (the baseline failure memos-3 and memos-4 saw).
  - `web`: build passed in 18.6 s, and test failed in 84.1 s.
- Build lock: I held a ticket from 16:02:24Z, before launch, until the warm-up process exited at 16:04:13Z
  (`lock.log`). The 1-minute load went from 30 to 189 in that window.
- Discovery needed no `--set`: `discover.run` `AB023DD8-…` at launch has `edited: 0`. The web worker ran `pnpm
  install --frozen-lockfile` in its own worktree, and the orchestrator ran it in the plan checkout, since a task
  worktree has no `node_modules` (known).
- Review depth: diff-risk rated web `medium` (0.6), store `high` (0.8) and API `high` (0.72). The report's
  "Review fallbacks" says none, which is now correct (finding 7).
- Baseline: the report lists each of the 5 base-tree failures once, per test: 1 Go test and 4 vitest cases. The
  web baseline is per test now.

## What happened

1. `discover --apply` found 2 areas, `web` (TypeScript, pnpm) and `memos` (Go): 7 found commands and 1 guessed.
2. `swiftgate run start spec.md` copied the spec, applied discovery, started the warm-up, and launched `claude`.
3. The orchestrator read the code itself, with no explorers, in 45 s (its `explore` span). It wrote `PLAN.md` with 4
   tasks in 3 waves and 7 assumptions (an 8th came after the web merge), and made the plan checkout. It committed
   the contract `07b59425`: the proto fields with regenerated Go and TypeScript, store fields, and a stubbed
   `ConsumeMemoShareView` in each driver. The contract was GREEN at `slice` (34.2 s) and `merge` (39.7 s).
4. It ran `plan import --contract`, `build start` and `build next`, then launched the store and web `build-task`
   workflows in parallel at 16:07:00Z. Both returned `ready-to-merge` with a GREEN slice and a classified review.
5. It merged web, saw the `merge` gate go RED on the locale tests, undid it, ran the fixer, widened the write set
   and merged again GREEN. Then it merged store GREEN.
6. It launched the API workflow, which hit 3 RED slices on a `revive` naming finding in its new test before a
   GREEN one. The orchestrator merged it GREEN.
7. It ran `final` on the plan branch: GREEN, with 3 baseline failures absorbed and 8 of 8 changed tests proven.
   It ran `build finish`, removed the plan checkout and wrote the report. The clone's `main` is untouched, with a
   clean status.

## Harness findings

1. **`build merge` doesn't check that the task's return passed `check-return`.**
   - The orchestrator ran `build check-return … --fix --json | grep …; build merge spec <task> --fix`. The check
     was RED (`build.return-checked` `149F4D00-BC19-467E-B18F-8E330C1B6A00`: locale files outside the write set),
     and the merge landed anyway at 16:13:41Z. The next GREEN check, `B676185C-0484-4C1F-8457-75119ECCD7E2`, came
     11 s later.
   - File: `plugin/gate/Sources/SwiftGateCLI/Commands/BuildMergeCommand.swift` reads no `build.return-checked`
     event.
   - Suggested fix: `build merge` refuses unless the latest `build.return-checked` for the task (or the fix, with
     `--fix`) in this build run is GREEN and names the commits it merges. Test: a RED check followed by `build
     merge` exits non-zero and merges nothing.
2. **`check-return` accepts a task gate run on a dirty tree at a commit before the task's own.**
   - The store task's return names `slice` run `20261004T160820Z-3c3ed983` (`gate.run` `36939D61-…`): `dirty:
     true`, `head` `07b59425`, the contract. The task's commit is `990fd862`. `check-return` passed it
     (`1ACB8B71-E8A2-4ADA-83D6-6CCB7E7241AE`). The API worker did the same once, in run `20261004T161704Z-1cb7de82`,
     and then gated its commits.
   - Files: `plugin/gate/Sources/SwiftGateCLI/Commands/BuildCheckReturnCommand.swift` (`gateRun`) and
     `plugin/gate/Sources/SwiftGateDomain/Build/TaskReturn.swift` (`TaskReturnEvidence.GateRun` keeps the tier,
     verdict, steps and proof bases, but no head, tree or dirty flag).
   - Suggested fix: carry the history record's head and dirty flag into the evidence, and add a rule such as
     `build-return.gate-stale` when the run was dirty or its head isn't the task's last commit.
3. **A task slice never finds a warm-up, because the warm-up measures only the run's base tree.**
   - Every task slice said `no warm-up measured its tests at the base tree <tree>`, with the tree of the contract
     commit (`dedc8f5e…`) or of a later merge (`792774e8…`). The only warm-up is at the base `98ce20b4…`
     (`.git/swift-harness/warmup/`). So no task slice can run tests in a run with a contract commit, even when the
     area's tests would fit the budget.
   - File: `plugin/gate/Sources/SwiftGateCLI/BrownfieldSliceCheck.swift`, which looks the warm test time up by the
     exact merge-base tree.
   - Suggested fix: fall back to the nearest warmed ancestor's time for the budget decision, keeping the exact tree
     only for the baseline; or warm the contract commit's tree once it lands.
4. **`warmup.run` events carry no `source.binary`.**
   - `run start` spawns the warm-up by re-executing its own binary, and `SwiftGate.main` has already unset
     `SWIFTGATE_SOURCE_HASH`, so the child reads no hash. All 4 `warmup.run` events lack `source`.
   - File: `plugin/gate/Sources/SwiftGateCLI/Commands/RunCommand.swift` (`LiveWarmupSpawner`).
   - Suggested fix: pass the current binary's source hash to the spawned warm-up's environment. Test: a spawned
     warm-up's events carry the parent's hash.
5. **`swiftgate check` from a subdirectory reads paths against that subdirectory, and the error misleads.**
   - The web worker ran the slice from `web/` after a `cd` into it. The gate resolved the area root `web` to
     `web/web`, which doesn't exist, and every command failed with `could not start /bin/sh: No such file or
     directory`, exit 127, plus 3 `swiftgate.not-run` notes (`can't read web/src/…`). Run
     `20261004T160802Z-06104314`, `gate.run` `BF721B87-…`. The worker ran it again from the root, GREEN.
   - Files: `plugin/gate/Sources/SwiftGateCLI/Commands/CheckCommand.swift` (`root` is the current directory) and
     `plugin/gate/Sources/SwiftGateAdapters/Brownfield/LiveAreaCommandRunner.swift` (names `/bin/sh`, not the
     missing directory).
   - Suggested fix: resolve the root with `git rev-parse --show-toplevel`, or refuse outside it naming the root;
     and say "working directory `<dir>` doesn't exist" when a spawn fails for that reason.
6. **`merge` and `final` `gate.run` events have no `baselineCount`.** `final` absorbed 3 baseline failures (its
   `baseline.summary`), but `ABAEAAC4-…` has no `baselineCount` key; slices write 0. Design §12 adds the field to
   every `gate.run`. File: `plugin/gate/Sources/SwiftGateCLI/BrownfieldMergeCheck.swift`. Suggested fix: pass its
   baseline's absorbed count into the gate run parts, as `BrownfieldSliceCheck` does.
7. **The report shows review depth only when it fell back.** The 3 depths (medium, high, high) appear only in
   each return's notes and the `judge.call` events. Neither `run-report.txt` nor `report.html` names a task's
   depth. File: `plugin/gate/Sources/SwiftGateDomain/Brownfield/BrownfieldRunReport.swift`. Suggested fix: a
   "Review depth" line per merged task, with the diff-risk level, and the same in the run view's task drawer.
8. **Worker stages still return quoted span ids.** The workflows logged `the worker stage returned
   "\"44b7bfe58637a914\"", not a span id` 3 times: the store and API worker stages and the API
   `review:architecture` stage, so no later stage names those spans. Main fixed the `surfaceCommit` half of the
   memos-4 finding, but not this half. File: `plugin/workflows/build-task.js`.
   Suggested fix: the same pattern and retry for `span` as for `surfaceCommit`.
9. **Slice p95 misses the budget on Go lint** (known). `golangci-lint run ./...` took 24.6 to 38.6 s whenever it
   linted many packages: the cold probe, the contract, and the dirty-tree slices. Scoping it to the changed
   packages would keep these under 10 s.
10. **No step installs node dependencies in a task worktree** (known). The web worker installed them itself.
11. **A stall watcher outlived its workflow.** The orchestrator's watcher for the store workflow printed `stalled`
    at about 16:12Z, 3 minutes after that workflow returned, and nobody stopped it. It had no effect. File:
    `plugin/skills/build/` (the stall-watch step). Suggested fix: stop the watcher when its workflow's
    notification arrives.

`report.html` has no absolute local path: `grep /Users/` finds 0 matches, and nor does a search for the user name
or `/private/`. The one `/tmp/` match is the repository-relative `.harness/tmp/sharekeys.mjs`.

## Deviations

- **Post-run ingest.** I ingested the orchestrator session once after the run, as noted above.
- **`claude` on `PATH`.** As in memos-2 to memos-4: node 22's `bin` goes after `mise`'s entries.
- **Launch flags.** As in memos-4, with `spec.md` outside the clone and `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`:

  ```sh
  swiftgate run start spec.md -- -p --output-format stream-json --verbose \
    --plugin-dir <branch>/plugin --dangerously-skip-permissions
  ```
- **Probes.** I ran both probe gates on a throwaway `probe` branch with `--base main`, then deleted the branch before
  the launch.
- **Clone clock.** The clone's start time has whole-second precision, since the shell's `date` has no
  milliseconds, so clone to first gate is between 2.7 and 3.7 s.
- **No patches.** I patched neither the clone nor the harness. The run removed its own worktrees; the plan branch
  stays in the clone.

## Files

| File | What |
|---|---|
| `spec.md` | the spec given to `swiftgate run`, byte-identical to memos-4's |
| `discover-apply.json` | the first discovery, right after the clone |
| `slice-empty.json`, `slice-one-line.json` | the probe gates |
| `run.jsonl`, `run.stderr` | the headless session's stream-json, and `run`'s stderr |
| `events.jsonl` | `swiftgate events list` after the post-run ingest |
| `gate-history.jsonl` | the clone's `runs/history.jsonl` |
| `gate-final.json`, `gate-merge-web-red.json` | the `final` gate report, and the web task's RED `merge` gate report |
| `build-events.jsonl`, `ledger.json` | the build run's merges, gates, undo and transitions, and the final ledger |
| `worker-journals.jsonl` | the 3 `build-task` workflows' results and logs |
| `PLAN.md`, `run-report.txt` | the orchestrator's plan, and the plan's `REPORT.md` verbatim (plain text, so the prose gate doesn't lint generated output) |
| `report.html` | `swiftgate report --html 20261004T160656Z-0ad8c7c2`, rendered from inside the clone |
| `warmup.log`, `config.toml`, `lock.log`, `uptime.log` | the warm-up log, the clone's config after the run, the build lock holder's log, and the load averages every 15 s through the run |
