# Brownfield trial: usememos/memos, second attempt

This attempt reruns the first brownfield trial (design §14) on `usememos/memos` at
`0d989707f82c33f74bb852edd8965ec88fcf041b`. The clone is fresh, made on 2026-10-04 at `trials/memos-2`. It uses
the same `spec.md` as [the first attempt](../memos/README.md): a view limit on memo share links. The harness ran
from this branch's `plugin/bin/swiftgate`, which is main at `08bdb067`.

**Verdict: the one-shot run BLOCKED again, one step later.** This time the orchestrator wrote `PLAN.md`, imported
it, landed a GREEN contract commit, started the build and launched 2 task workflows. The plan-state guard then
denied every write the build workers tried in their task worktrees. Those worktrees sit under the plan dir in
the git common dir, so the guard counts every file in them as plan state. The run merged nothing. Its `final`
came back GREEN, but it gated only the contract commit. Clone to first gate and the untouched-code findings pass.
The `slice` p95 is inconclusive.

## Measures

| Measure | Value | Bar | Result | Source |
|---|---|---|---|---|
| Clone to first gate | 13.0 s: `git clone` 7.9 s from 10:42:04.1Z, then `discover --apply` 0.26 s, then `slice` on an empty commit 0.12 s | under 3 min | PASS | `gate.run` event `8442CF49-4913-496A-8FDE-E4A5EC6F929E`, run `20261004T104217Z-a01a1e87`, at 10:42:17.167Z (`events.jsonl`) |
| Findings on untouched code, empty commit | 0 | 0 | PASS | `slice-empty.json`, `gate.run` `20261004T104217Z-a01a1e87`, `ruleCounts {}` |
| Findings on untouched code, 1-line change | 0 on code. 1 `area.build-only` nit with no file or line: the report line saying the warm-up hadn't measured the Go tests yet | 0 | PASS | `slice-one-line.json`, `gate.run` `20261004T104234Z-666bf6ad`, 81.2 s cold. Its `area-lint` step (`golangci-lint`, cold) took 74.6 s of that |
| `slice` p95 | Before the warm-up: 2 `check slice` events, 0.12 s and 81.2 s, so p95 is 81.2 s. Steady state, after the warm-up: the contract's `slice`, 26.4 s (`20261004T105420Z-4af53c9f`), and the Stop hook's `slice`, 0.08 s (`20261004T105723Z-edb1b801`) | 30 s or less | INCONCLUSIVE | `gate.run` events in `events.jsonl`. The contract's run has no `gate.run` event (finding 2); its time comes from that gate's JSON in `run.jsonl`. 2 steady-state samples aren't a p95 |
| One-shot run | Contract commit `137add49` on `swift-harness/spec`, GREEN at `slice`, `merge` and `final`. 0 merges: the store and web tasks are blocked and the API task never started. `final` GREEN (`20261004T105853Z-711cc047`) gated only the contract | `spec.md` to a GREEN plan branch, every merge and `final` GREEN, 0 human input | FAIL (BLOCKED) | `build-events.jsonl` (the `final` gate line), `gate-final.json`, `ledger.json`, `run-report.md`, `worker-journals.jsonl` |
| Human input | 0. The session made no `AskUserQuestion` call. Its 2 `build.halt` events (`question`) were answered `continue` by the orchestrator in 80 ms and 120 ms. Both turns ended by themselves with `stop_reason: end_turn` | 0 | PASS | `run.jsonl` (2 `result` lines, session `b41cd967-a730-4f58-8f52-2df5f23b33eb`). `build.halt` and `build.resume` in `events.jsonl` |

Other numbers from the run:

- Wall time, from launch to exit: 958 s (10:44:25.7Z to 11:00:23.6Z). The session ran 2 turns of 62 and 14
  steps, and its `result` line reports $3.20. The ingested `agent.usage` events add up to $2.85: the orchestrator
  on `claude-opus-5-5` cost $2.31, and the 4 build workers on `claude-sonnet-5-5` cost $0.54.
- Warm-up, from `warmup.run` events, all `cold`. `web` build passed in 36.0 s and `web` test failed in 19.0 s.
  `memos` build passed in 7.8 s and `memos` test failed in 60.7 s. Both test failures are baseline failures,
  not results of the change:
  - `filtered-memo-stats.test.ts` depends on the local time zone.
  - `TestEntrypointDoesNotLoopWhenTargetUIDIsRoot` in `scripts` fails once in a full run, and the
    orchestrator saw it pass alone.

  Both areas' test times are over the 30 s `slice_budget_s`, so `slice` only builds them.
- Build lock: I held a ticket from 10:44:17Z, before launch, until the warm-up process exited at 10:45:34Z
  (`lock.log`). Machine load was 15 to 49.
- Expected `--set`: none came. The brief expected the orchestrator to set `memos.test` to the mined
  `DRIVER=sqlite go test ./...`. It didn't need to: the store tests default to SQLite on this checkout, and the
  warm-up's Go failure isn't a driver failure. The only `--set` was the web test wrapper (finding 4).

## What happened

1. `discover --apply` found 2 areas: `web` (TypeScript, pnpm, 3 found and 1 guessed command) and `memos` (Go,
   4 found commands). This time the `web/` area was found.
2. `swiftgate run start spec.md` copied the spec, wrote the clock, applied discovery, started the warm-up, claimed
   the plan lock for session `b41cd967` and launched `claude`.
3. The orchestrator wrote `PLAN.md` (4 tasks: contract, store, API and web, with 12 assumptions). It landed the
   contract `137add49` (proto fields, generated code, store fields, not-implemented driver stubs) and gated it:
   `slice` GREEN in 26.4 s and `merge` GREEN. It ran `plan import` and set the index to `planned` itself
   (finding 5). It wrote the worker context packs by hand (finding 6), then ran `build start`, created 2 task
   worktrees and launched 2 `build-task` workflows.
4. Each workflow's worker and fix agent tried migrations, SQL and test edits through Write, Edit and shell
   heredocs. `guard.plan-state` denied all 13 tries, from `hook.decision` `277C1C79-…` at 10:57:24Z to
   `66807722-…` at 10:58:06Z. Both tasks returned `gate-red` with `redReason: environment`.
5. The orchestrator answered both halts with "go on without it", marked the tasks `blocked`, and ran `final`,
   which came back GREEN. It recorded that gate, ran `build finish` (2 blocked, 1 pending, 1 done), removed its
   checkout and wrote the run report. It didn't work around the guard.

## Harness findings

1. **BLOCKER: build workers can't write in their own task worktrees.**
   - `SwiftGateAdapters/Build/GitWorkspace.swift` puts a brownfield task worktree at
     `<common>/swift-harness/plans/<plan>/worktrees/<task>`. `swiftgate worktree create` says so in its help
     text (`SwiftGateCLI/Commands/WorktreeCommand.swift`).
   - `SwiftGateDomain/Hooks/Guards.swift` (`PlanStateGuard`) classes every file inside a plan's directory as
     `planFile`, which only the lock holder may write. `OrchestratorMarker.isOrchestrator` refuses any call
     with an agent id, so no subagent passes.
   - Evidence: 13 `guard.plan-state` blocks in `events.jsonl` between 10:57:24Z and 10:58:06Z, and the 4
     worker results in `worker-journals.jsonl`.
   - Suggested fix: classify `plans/<plan>/worktrees/<task>/**` as the task's working tree, not plan state, or
     move brownfield task worktrees out of the plan dir. In the first case, scope the exemption to the task's
     own worktree (worker brief pitfall 5).
   - Test: a subagent's Write under `plans/<plan>/worktrees/<task>/` passes, and its Write to
     `plans/<plan>/PLAN.md` is still denied.
2. **Gates run in the plan checkout lose their `gate.run` events and history.**
   - The run skill (`plugin/skills/run/SKILL.md`, steps 1 and 5 of the build section) has the orchestrator
     make `<plan-dir>/checkout` with `git worktree add`, and later delete it with `git worktree remove`.
   - Gates in that checkout write events and `runs/history.jsonl` under the linked worktree's own git dir.
     Only `swiftgate worktree remove` copies them up (design §12), so raw `git worktree remove` deletes them.
   - Effect: the contract's `slice` (`20261004T105420Z-4af53c9f`), `merge` (`20261004T105507Z-25a7ff70`) and
     `final` (`20261004T105853Z-711cc047`) have no `gate.run` event. §14 reads `final` and the `slice` p95
     from those events.
   - Suggested fix: write gate events from any linked worktree of a brownfield clone to the common dir's
     store, or give the checkout a `swiftgate` command that copies its events up when it removes it.
3. **The report headlines `final: GREEN` for a build that built nothing.**
   - `SwiftGateDomain/Brownfield/BrownfieldRunReport.swift` prints the `final` verdict first, and the run
     report doesn't list blocked or pending tasks.
   - Here `final` gated the contract alone, while `build finish` reported 2 blocked tasks and 1 pending task.
   - Suggested fix: when the ledger has unfinished tasks, headline "incomplete", list them, and don't record
     `final` as the run's verdict.
4. **Vite refuses files under `.git`, so web tests can't run in run worktrees.** This shares a root cause with
   finding 1. The orchestrator wrote `.git/swift-harness/web-vitest.sh`, which copies the tree to `/tmp` and runs
   vitest there, and set it as `web.test` with `discover --apply --set`. That's a correct use of `--set`, but
   every Node area that runs on Vite will need the same wrapper while worktrees live under the git dir. Moving the
   worktrees, the second option in finding 1, would fix both.
5. **`plan import` leaves no index entry.** `build start` needs the index at `planned`. The orchestrator ran
   `swiftgate index set spec planned` by hand. File: `SwiftGateCLI/Commands/PlanImportCommand.swift`.
   Suggested fix: `plan import` sets the index entry to `planned` under the index lock.
6. **`context-pack` needs `.swiftgate.toml`.** `SwiftGateCLI/Commands/ContextPackCommand.swift` reads its word
   budgets from the owned config, and a brownfield clone has none, so the orchestrator wrote each worker pack by
   hand. Suggested fix: read the budgets from `BrownfieldConfig`, or use defaults in a brownfield clone.
7. **For the first 3 minutes the plugin's own hooks ran a stale binary.** This is related to H1 but takes a
   different path.
   - The session loads the plugin with `--plugin-dir`, so its plugin hooks run `plugin/bin/swiftgate` with
     `CLAUDE_PLUGIN_DATA` set. The shim then builds into `~/.claude/plugins/data/swift-harness-inline`, not the
     `~/.cache/swift-harness` cache that the terminal and settings hooks had already filled.
   - With no binary for the current hash there, the shim ran the newest older binary while it built. The build
     took 167.8 s and finished at 10:47:22Z (`build-243e184cce58c115.log`).
   - That older binary predates the hook-source dedupe, so the plugin's SessionStart printed the owned-profile
     context ("(.swiftgate.toml)", "`check --tier fast`") next to the correct brownfield context.
   - Every pre-tool-use from 10:44:36Z to 10:45:40Z was recorded twice: 14 pairs with the same `inputHash`
     in `events.jsonl`. After the build landed, the plugin's hooks went silent, as designed. I replayed a
     SessionStart afterwards: the plugin source prints nothing, and the settings source prints the brownfield
     context.
   - Suggested fix: have `swiftgate run` build the binary for the plugin-data cache before it launches
     `claude`. Or have the shim reuse an exact-hash binary from the other cache before it falls back to an
     older one.
8. **A baseline failure absorbs a whole step.** With no JUnit report, `SwiftGateDomain/Brownfield/Baseline.swift`
   records "memos test (the whole step)" from 1 flaky Go test. Every Go test failure at `merge` then passes for
   this tree. This follows the design's no-JUnit fallback, but `go test -json` would give per-test results.
   Suggested fix: have discover add `-json` (or a JUnit converter) for Go areas, and let the baseline key on
   test ids.

H1, the bare `swiftgate` in build-task stage prompts: no sign of it. Every worker command in the workflow
transcripts called this branch's `plugin/bin/swiftgate` by absolute path. The workers stopped before any task
gate, though, so the task-gate path was never exercised.

## Deviations

- **No `DRIVER=sqlite` export.** Attempt 1 exported it into the run's environment. This attempt didn't, so
  that discovery and the orchestrator would have to handle it as designed.
- **`claude` on `PATH`.** `claude` is installed under node 22, and the trial toolchain pins node 24. I appended
  node 22's `bin` to `PATH` after `mise`'s entries, so node 24 still came first.
- **Launch flags.** `swiftgate run start spec.md -- -p --output-format stream-json --verbose --plugin-dir
  <branch>/plugin --dangerously-skip-permissions`, with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`. These are the
  same flags as attempt 1, which ran in `bypassPermissions` mode.
- **Probes.** I ran both probe gates on a throwaway `probe` branch with `--base main`. I deleted the branch before
  the launch, so the run started from a clean `main` at the pinned commit.
- **Replay.** After exporting `events.jsonl`, I replayed 1 SessionStart payload into the clone (finding 7). That
  replay added 1 `hook.decision` event that the export doesn't include.
- **No run past the blocker.** I patched neither the clone nor the harness, and I didn't resume the session.

## Files

| File | What |
|---|---|
| `spec.md` | the spec given to `swiftgate run`, the same as attempt 1's |
| `discover-apply.json` | the first discovery, right after the clone |
| `slice-empty.json`, `slice-one-line.json` | the probe gates |
| `run.jsonl`, `run.stderr` | the headless session's stream-json, and `run`'s stderr |
| `events.jsonl` | `swiftgate events list` after the run |
| `gate-history.jsonl` | the clone's `runs/history.jsonl` (the checkout's history is gone, finding 2) |
| `gate-merge-contract.json`, `gate-final.json` | the contract's `merge` gate and the `final` gate, as the orchestrator saved them |
| `build-events.jsonl`, `ledger.json` | the build run's ledger transitions and the final ledger |
| `worker-journals.jsonl` | the 2 `build-task` workflows' journals, with each worker's result |
| `PLAN.md`, `run-report.md` | the orchestrator's plan and `swiftgate run report spec` |
| `warmup.log`, `config.toml`, `lock.log` | the warm-up log, the config after the orchestrator's `--set`, and the build lock holder's log |
