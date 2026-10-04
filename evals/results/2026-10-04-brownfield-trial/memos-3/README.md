# Brownfield trial: usememos/memos, third attempt

This attempt reruns the brownfield trial (design §14) on `usememos/memos` at
`0d989707f82c33f74bb852edd8965ec88fcf041b`. The clone is fresh, made on 2026-10-04 at `trials/memos-3`. It uses
the same `spec.md` as [the second attempt](../memos-2/README.md): a view limit on memo share links. The harness ran
from this branch's `plugin/bin/swiftgate`, which is main at `a8af3873`.

**Verdict: the one-shot run is INCOMPLETE, with 0 merges.** The fixes on main cleared the memos-2 blocker. Both build workers wrote
code in their task worktrees, which now sit beside the clone, and each finished with a GREEN `slice` gate. Then
`build check-return` rejected both returns with `build-return.gate-missing-step`: it wants an `app-build` step that a
brownfield `slice` never runs (finding 1). The orchestrator answered both halts by itself, marked the tasks blocked,
ran `final` (GREEN, but it gated only the contract commit), and wrote a report headed `run: INCOMPLETE`. Clone to
first gate passes. The untouched-code checks pass. The steady-state `slice` p95 is 40.3 s, which fails the 30 s bar.
The run asked the user nothing, and every hook and gate ran this branch's binary.

## Measures

| Measure | Value | Bar | Result | Source |
|---|---|---|---|---|
| Clone to first gate | 6.4 s. `git clone` and checkout of the pinned commit took 5.4 s, from 12:34:45.8Z. `discover --apply` took 0.36 s, then `slice` on an empty commit took 0.45 s | under 3 min | PASS | `gate.run` `25E4B922-AE89-4223-A4EF-63ACA57AC784`, run `20261004T123451Z-71da72bb`, at 12:34:52.233Z (`events.jsonl`) |
| Findings on untouched code, empty commit | 0 | 0 | PASS | `slice-empty.json`, `gate.run` `25E4B922-…`, `ruleCounts {}` |
| Findings on untouched code, 1-line change | 0 on code. There was 1 `area.build-only` nit with no file or line, the report line saying the warm-up hadn't measured the Go tests yet. The change was 1 comment line in a Go file | 0 | PASS | `slice-one-line.json`, `gate.run` `CBF69BE1-A67B-470B-90B3-AA5D7C3DB1ED`, run `20261004T123503Z-709e1b4b`, 41.7 s cold. Its `area-lint` step took 39.9 s of that and ended RED on lines the change didn't add, so it made no finding |
| `slice` p95, before the warm-up | 2 samples: 0.35 s and 41.7 s, so p95 is 41.7 s | 30 s or less | FAIL (cold probes) | `gate.run` `25E4B922-…` and `CBF69BE1-…` |
| `slice` p95, during the warm-up | 0 samples. The warm-up ran from 12:36:27Z to 12:37:01Z, and no gate ran then | 30 s or less | no data | `warmup.run` events `140717C0-…`, `45BCDA7C-…`, `EDEC194B-…`, `AE9DDF06-…` |
| `slice` p95, steady state | 9 samples: 0.04 s (the Stop hook), 0.09, 0.09, 5.1, 6.3, 18.2, 23.2, 27.3 and 40.3 s. The nearest-rank p95 is 40.3 s. Leaving out the 3 runs under 0.1 s, which had empty diffs, gives the same p95 | 30 s or less | FAIL | `gate.run` events from `7D154498-…` (12:39:48Z) to `9C9C8C86-…` (12:48:52Z). The 40.3 s run is `20261004T124744Z-9d7ec113` (`38F35105-…`), the store task's first slice: `area-lint` on `memos` took 30.2 s and `area-build` 9.9 s |
| One-shot run | Contract commit `1316c660` on `swift-harness/spec`. 0 merges: the store and web tasks are blocked with GREEN slice gates, and the API task never started. `final` was GREEN but gated only the contract. The report heads itself `run: INCOMPLETE, 3 task(s) not done` | `spec.md` to a GREEN plan branch, every merge and `final` GREEN, 0 human input | FAIL (INCOMPLETE) | `gate.run` `63385386-…`, run `20261004T125001Z-cfca83f2` (`command = check final`), `build-events.jsonl`, `ledger.json`, `run-report.txt` |
| Human input | 0. The session made no `AskUserQuestion` call, and the stream holds no user message after the launch prompt. Each of its 3 turns ended with `stop_reason: end_turn`. Turns 2 and 3 started on workflow-completion notifications. There were 2 `build.halt` events, both `question`, and the orchestrator answered both `continue` | 0 | PASS | `run.jsonl` (3 `result` lines, session `5f9bc272-d96a-48ac-ae63-61af01b8865a`); `build.halt` `10892904-…` and `3C1E405D-…`, `build.resume` `1785545D-…` and `87F1E740-…` |

## Every merge

None. The contract went straight to `done` in the ledger when the orchestrator landed it, at 12:41:54Z. No task
reached `build merge`. The task branches still hold the work:

| Task | Branch, commits | Task gate | Ledger |
|---|---|---|---|
| `share-view-limit-contract` | `swift-harness/spec` `1316c660` | `slice` GREEN `20261004T124315Z-62ce9982` (empty diff, 94 ms); `merge` GREEN `20261004T124046Z-5e6be9b3` | done. `check-return` was RED with the same finding, and the orchestrator recorded it in `PLAN.md` and went on |
| `share-view-limit-store` | `spec/share-view-limit-store` `f975b462`, `1151658c` | `slice` RED `20261004T124744Z-9d7ec113` (`neutral.lint`), then GREEN `20261004T124847Z-cc87cdd0` | blocked, `check-return` RED |
| `share-view-limit-web` | `spec/share-view-limit-web` `92640971`, `85f39893` | `slice` RED `20261004T124437Z-d7c9ce0b` (`area.lint-failed`), then GREEN `20261004T124503Z-79e036f7` | blocked, `check-return` RED |
| `share-view-limit-api` | none | none | pending, because it depends on the store task |

## Halts

| Halt | Task | Reason | Answer, by whom, wait |
|---|---|---|---|
| `10892904-CBA6-4A9D-913D-30788F0676C8`, 12:46:26.7Z | `share-view-limit-web` | `question`: `check-return` RED, `build-return.gate-missing-step` (`app-build`) | `continue` (go on without it, the recommended option), by the orchestrator, 202 ms |
| `3C1E405D-BB98-4B9A-8948-EFF0F65B85DB`, 12:49:56.3Z | `share-view-limit-store` | the same | `continue`, by the orchestrator, 112 ms |

## Which binary ran

Every hook and gate ran this branch's binary (hash `b49790db12112294`). The events can't show it,
because no `gate.run` or `hook.decision` payload records a binary path or hash (finding 6). The evidence:

- The settings hooks in `<common>/swift-harness/settings.json` call this branch's `plugin/bin/swiftgate` by
  absolute path, and the session loaded this branch's `plugin/` with `--plugin-dir`.
- The user cache and the plugin-data cache both hold `bin/b49790db12112294/swiftgate`, and both are the same
  inode. The shim wrote the plugin-data stamp and `last-good` at 12:36:27Z, the launch second, so `swiftgate run`
  warmed that cache before `claude` started.
- `events.jsonl` has no `hook.decision` pair with the same `inputHash`. Memos-2's stale binary showed up as such
  pairs. The plugin-source SessionStart hook printed nothing, as designed, and the settings source printed the
  brownfield context.
- Every `swiftgate` call in the orchestrator's and the 8 workflow agents' Bash commands (57 calls) went through
  this branch's `plugin/bin/swiftgate` by absolute path. No call was bare.

## Other numbers

- Wall time, from launch to exit: 890.3 s (12:36:27.4Z to 12:51:17.7Z). API time was 592.5 s, over 3 turns of
  67, 7 and 10 steps.
- Cost: $4.37 (the `result` line's `total_cost_usd`). The `agent.usage` events add up to the same $4.37: the
  orchestrator on `claude-opus-5-5` cost $3.14. The workflow agents on `claude-sonnet-5-5` (workers, test-quality
  reviewers, diff-risk) cost $0.92, and the 2 verifiers on `claude-opus-5-5` cost $0.32. The run's own ingest
  failed (finding 2), so I ingested after the run from the main checkout (see Deviations).
- Warm-up, from `warmup.run` events, all `cold`:
  - `web`: build passed in 10.7 s, and test failed in 22.8 s.
  - `memos`: build passed in 1.7 s, and test failed in 30.6 s.

  The Go test time is 0.6 s over the 30 s `slice_budget_s`, so every `slice` built `memos` without testing it.
- Build lock: I held a ticket from 12:36:26Z, before launch, until the warm-up process exited at 12:37:01Z
  (`lock.log`). The 1-minute load average was 9 to 19 around the launch.
- `--set`: at 12:38:36Z the orchestrator set `memos.test` and `memos.test_files` to `DRIVER=sqlite go test -json …`,
  because the discovered `go test -json ./...` tried the MySQL and PostgreSQL containers (`discover.run`
  `3F8D0785-…`, `edited: 2`). This time the web tests needed no Vite wrapper, because the worktrees sit beside the
  clone.
- Guard denials: there were 4 `guard.reviewer-bash` blocks, by design. Reviewers and verifiers tried
  `git diff`/`grep` pipelines and then read with Read and Grep. There were also 4 `guard.build-agent-main-checkout`
  blocks of build workers writing inside their own worktrees (finding 3).

## What happened

1. `discover --apply` found 2 areas, `web` (TypeScript, pnpm) and `memos` (Go, with `go test -json`): 7 found
   commands and 1 guessed.
2. `swiftgate run start spec.md` copied the spec, applied discovery, started the warm-up, claimed the plan lock for
   session `5f9bc272` and launched `claude`.
3. The orchestrator read the code itself, with no explorers. It made the plan checkout with
   `swiftgate run checkout create` and diagnosed both baseline test failures. It fixed the Go driver with `--set`,
   then landed the contract `1316c660`: proto fields with regenerated Go, OpenAPI and TypeScript, store fields, and
   a stubbed `ConsumeMemoShareView` in each driver. That commit was GREEN at `slice` (23.2 s) and at `merge` (53.2 s).
4. It wrote `PLAN.md` with 4 tasks in 3 waves and 9 assumptions (it later added 3 more for the `check-return` failures), and ran `plan import`, which wrote the index entry
   this time. It started the build, created the worktrees, built the worker packs with `context-pack`, and
   launched the store and web `build-task` workflows.
5. Both workers built their slices, each fixed 1 RED slice (a lint finding), and returned GREEN gates. Test-quality
   reviews ran at `medium` with 1 verified minor finding each. `build check-return` rejected both returns, because
   neither gate ran `app-build`.
6. The orchestrator halted, answered `continue`, and blocked each task. It ran `final` (GREEN in 37.8 s), recorded
   it, and ran `build finish` (1 done, 2 blocked, 1 pending). It removed the checkout with `swiftgate run checkout
   remove` and wrote the report. The first removal failed on the orchestrator's own `.harness/` scratch files, and
   it deleted them and retried.

## Harness findings

1. **BLOCKER: `build check-return` requires owned-profile gate steps that a brownfield `slice` never runs.**
   - `SwiftGateDomain/Build/TaskReturn.swift` checks `taskGateSteps = [.impact, .coverage, .appBuild]` whenever
     `evidence.taskGateStepsRequired`. `SwiftGateCLI/Commands/BuildCheckReturnCommand.swift` sets that to `!fix`
     without looking at the profile or the task gate's tier.
   - A brownfield `slice` records `neutral`, `area-lint`, `area-build` and `record`, never `app-build`. A brownfield `check`
     accepts `--app-build` and does nothing with it (`SwiftGateCLI/Commands/CheckCommand.swift`
     runs it only on the owned T1 path). No brownfield task can pass `check-return`.
   - Evidence: `check-return` output for gate runs `20261004T124309Z-438724c5`, `20261004T124315Z-62ce9982`,
     `20261004T124503Z-79e036f7` and `20261004T124847Z-cc87cdd0` in `run.jsonl`. Halts `10892904-…` and
     `3C1E405D-…`.
   - Suggested fix: when the task gate is `slice`, `merge` or `final`, require no owned-profile extra step, or the
     brownfield steps (`neutral`, plus `area-build` for each touched area). Have `check --tier slice|merge|final`
     reject `--app-build`, `--impact` and `--coverage` by name, not ignore them. Test: a `check-return` citing a
     GREEN brownfield `slice` with the brownfield steps passes, and 1 citing a slice with no steps fails.
2. **`events ingest` and `doctor` can't find the session record from a linked worktree.**
   - The SessionStart hook writes `<common>/swift-harness/hook-state/sessions/<id>.json`, through the main checkout's
     state root. `SwiftGateAdapters/SessionRecordStore.swift` resolves its directory with
     `StateRootResolver.resolve(worktree:)`, so from the plan checkout it looks under
     `.git/worktrees/<name>/swift-harness/` and misses.
   - Evidence: both of the orchestrator's `events ingest` calls returned `no session record for 5f9bc272-…`, from
     the plan checkout. `doctor` from the same checkout reported `doctor.session-record` (`gate.run` `932F7B68-…`).
     The same ingest from the main checkout stored 132 messages.
   - Suggested fix: read session records from the common dir's state root (or fall back to it) in every worktree.
3. **The main-checkout guard denies a build worker's relative writes after `cd <its worktree>`.**
   - `SwiftGateDomain/Hooks/ShellWriteTargets.swift` (`writeTargets`) names each relative write target twice: once
     under the shell's starting directory and once under each literal `cd`. The session's starting directory is
     the main checkout, so `Guards.swift` (`guard.build-agent-main-checkout`) denies the first spelling.
   - Evidence: `hook.decision` `1DB90B84-…`, `B66A6D7E-…`, `5F10D3C4-…` and `052B6E34-…`. For example,
     `cd <task worktree>/store && cat > migration/sqlite/…` drew a denial naming `<clone>/migration/sqlite/…`. The workers
     retried with absolute paths, which cost turns but did no harm.
   - Suggested fix: after a literal absolute `cd`, resolve later relative targets under that directory only. Test:
     `cd /wt && echo x > a` from a main-checkout cwd allows `/wt/a`, and the guard still denies `echo x > a` alone.
4. **The report's baseline and review sections are wrong in 2 small ways.** Both are in
   `SwiftGateDomain/Brownfield/BrownfieldRunReport.swift`.
   - `baselineFailures` lists `memos test: …TestEntrypointDoesNotLoopWhenTargetUIDIsRoot` twice. It doesn't
     dedupe across baseline records. Suggested fix: dedupe on area, step and test.
   - `reviewFallbacks` counts only merged tasks, so the report says "none" while reviewers looked at both blocked tasks at
     `medium` because no diff-risk level came back. Suggested fix: count every task whose review ran.
5. **Web tests still baseline as a whole step.** The `web test` failure, a time-zone-dependent vitest test, stays in the baseline as
   "the whole step", so at `merge` and `final` no web test failure can gate. The Go side now records per test.
   Suggested fix: have discover's Node reader add a JUnit reporter (`{junit}`) for vitest and jest, as it now adds
   `-json` for Go.
6. **Events don't name the binary.** No `gate.run`, `gate.step` or `hook.decision` payload carries the gate binary's
   path or source hash, so no reader can get the measure "which binary ran" from events. I read it from the shim caches
   and the transcripts. Suggested fix: add the shim's source hash (`SWIFTGATE_SOURCE_HASH` or similar, set by
   `plugin/bin/swiftgate` before `exec`) to the event `source` (`SwiftGateDomain/Events/`).
7. **Slice p95 misses the budget on Go lint.** Not a bug. `area-lint` (`golangci-lint run ./...`) takes 20 to 30 s
   per slice even warm, and memos' Go tests at 30.6 s sit 0.6 s over `slice_budget_s`, so `slice` never tests Go.
   Scoping lint to changed packages (`golangci-lint run --new-from-rev <base>` or package paths from the diff) would
   bring the 40.3 s slice under 15 s.

## Deviations

- **Post-run ingest.** The run's own `events ingest` failed (finding 2). After the run I ran the same 2 ingest
  commands from the clone's main checkout. That added 155 `agent.usage` and tool-window events, which this
  `events.jsonl` export includes. Every other event predates it.
- **`claude` on `PATH`.** As in memos-2: node 22's `bin` goes after `mise`'s entries, so node 24 still comes first.
- **Launch flags.** As in memos-2, with `spec.md` outside the clone. The launch set
  `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` and ran:

  ```sh
  swiftgate run start spec.md -- -p --output-format stream-json --verbose \
    --plugin-dir <branch>/plugin --dangerously-skip-permissions
  ```
- **Probes.** I ran both probe gates on a throwaway `probe` branch with `--base main`, then deleted the branch before
  the launch.
- **No run past the blocker.** I patched neither the clone nor the harness, and I didn't resume the session. The
  task worktrees and their branches stay in place beside the clone.

## Files

| File | What |
|---|---|
| `spec.md` | the spec given to `swiftgate run`, byte-identical to memos-2's |
| `discover-apply.json` | the first discovery, right after the clone |
| `slice-empty.json`, `slice-one-line.json` | the probe gates |
| `run.jsonl`, `run.stderr` | the headless session's stream-json, and `run`'s stderr |
| `events.jsonl` | `swiftgate events list` after the run and the post-run ingest |
| `gate-history.jsonl`, `gate-history-task-worktrees.jsonl` | the clone's `runs/history.jsonl`, and the task worktrees' histories |
| `gate-merge-contract.json`, `gate-final.json` | the contract's `merge` gate and the `final` gate reports |
| `build-events.jsonl`, `ledger.json` | the build run's ledger transitions and the final ledger |
| `worker-journals.jsonl` | the 2 `build-task` workflows' journals |
| `PLAN.md`, `run-report.txt` | the orchestrator's plan, and `swiftgate run report spec` verbatim (plain text, so the prose gate doesn't lint generated output) |
| `warmup.log`, `config.toml`, `lock.log` | the warm-up log, the config after the orchestrator's `--set`, and the build lock holder's log |
