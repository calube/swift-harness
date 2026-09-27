# Handoff: interview trial run 2 findings

<!-- RESUME
State (2026-09-27): a second `/swift-harness:ship specs/1-list-detail.md --preset interview` run in interview-rehearsal-1, on swift-harness 24fc934 (surface-commit proofs, per-task prove and mutate, strict write sets, gate verdicts on the ledger page). It merged 3 of 4 tasks. The views task never started after the 30-minute no-new-starts cutoff, and the final ready gate is RED.
Verdict from the user: far too slow for a coding interview, which needs 3-4x this scope in 45 minutes. Next: a research session on a much faster interview mode, or no harness for interviews.
Evidence: the bundle `interview-trial-evidence/2026-09-27/` beside the repos (its README.md is this doc), and tags `run-1-final` and `run-2-final` in interview-rehearsal-1. Both plans are at index status building with their claims released.
Open: findings 1-8 below. None is fixed.
-->

Two runs of `/swift-harness:ship specs/1-list-detail.md --preset interview` in `interview-rehearsal-1`,
the 45-minute "posts list and detail" exercise. Run 1 used swift-harness at `627007b`. Between the runs,
swift-harness `24fc934` added surface-commit proofs, per-task prove and mutate, strict write sets and
gate verdicts on the ledger page. Run 2 used `24fc934`.

**Bottom line from the user:** a real interview needs 3–4× this work in the same time, so the
harness as run is far too slow. An open question is whether to use the harness for a coding
interview at all.

## Where the evidence is

All `run-N/` paths are inside the bundle `interview-trial-evidence/2026-09-27/`, which sits beside the repos.

| What | Where |
|---|---|
| Run 1 code, as merged plus 2 follow-up test fixes | `interview-rehearsal-1` tag `run-1-final`, branch `run-1` |
| Run 2 code, as merged (views task never ran) | `interview-rehearsal-1` tag `run-2-final`, branch `run-2` |
| Plan state: `plan.json`, `ledger.json`, build `run.json`, `events.jsonl`, stored returns | `run-N/plan-state/` here; originals in `interview-rehearsal-1/.git/swift-harness/plans/` |
| Design runs: frame answers, phases, drafter packs | `run-N/design-run/` |
| Returns as checked, merge JSON, gate output (run 2) | `run-N/build-scratch/` |
| Gate run reports (`report.json`, logs) | `run-N/<runId>/`, ids below |
| Ledger pages as last rendered | `run-N/ledger.html` |
| Run 2 manual steps | `run-2/manual-steps.md` |
| Every gate run's summary line | `history.jsonl` (from `interview-rehearsal-1/.harness/runs/`) |
| Run 1's proof against a hand-made API surface | `run-1/proof-from-api-surface-20260927T191526Z-858eaecf/`; base branch `posts-api-surface` in `interview-rehearsal-1` |
| Agent and workflow transcripts | the Claude Code project directory for interview-rehearsal-1, session `fbec7e75-b9c5-46fa-99c0-d7b3471f7b5f`, under `subagents/workflows/wf_*` |
| Harness changes between the runs | swift-harness commit `24fc934` |
| First trial run's findings | [`2026-09-27-interview-trial-run-1.md`](2026-09-27-interview-trial-run-1.md) |

## Timelines (UTC)

| Phase | Run 1 | Run 2 |
|---|---|---|
| Preflight start | 18:19:53 | 20:40:35 |
| Design merged (sketch; 8 frame answers, 1 drafter + 1 lint round, approval) | ~18:31 | 20:53:36 |
| Plan done | ~18:32 | 20:54:54 |
| **Before any code** | **~12.5 min** | **~14.3 min** |
| Build start | 18:32:25 | 20:55:14 |
| Last merge | 18:55:40 (23.3 min) | 21:29:48 (34.6 min) |
| Final ready gate | 18:56–18:58, RED | 21:30–21:33, RED |
| End to end | ~38 min | ~53 min |

Per-task workflow wall time (worker, plus the fixer where it ran):

| Run 1 task | Time | Run 2 task | Time |
|---|---|---|---|
| api-client-user-and-comments-endpoints (opus) | 2m 20s | posts-api-client-user-and-comments (opus) | 4m 18s + fixer 1m 41s |
| posts-list-feature-load-and-refresh (sonnet) | 7m 23s | posts-list-feature-reducer (sonnet) | **25m 38s** |
| post-detail-feature-author-and-comments (opus) | 2m 28s | post-detail-feature-and-root-stack (opus) | 7m 14s |
| app-root-stack-navigation (opus) | 3m 1s | (merged into the detail task) | |
| app-ui-list-and-detail-views (sonnet) | 10m 38s | posts-list-and-detail-views | never started (no-new-starts at 30 min) |

Each merge gate (push tier on main) took 8–40 s. A ready gate took ~2.5–4.5 min.

## Outcomes

| | Run 1 | Run 2 |
|---|---|---|
| Tasks merged | 5 of 5 | 3 of 4 |
| Merge gates | 5 GREEN | 1 RED then fixed, 3 GREEN |
| Edits outside write set | 1 (`AppView.swift`), check-return passed it | 0 |
| Final ready run | `20260927T185605Z-1de54f8f` RED | `20260927T213024Z-c4f8f4d9` RED |
| prove | 0/23: 23 compile-only | 14/23 proven at proof bases; 9 not-proven |
| reach | 1 weak test | clean |
| mutate | never ran (T1 RED); 4 survivors found later | clean |
| T3 launch flow | GREEN | RED: `AppView.swift` doesn't compile (views task never ran) |
| Diff coverage | 99% | 100% |

## Where the time went

1. **Design and plan: ~13–14 min before any code, in both runs.** Most of it goes to 2 frame prompts
   and the drafter, at about 2 min per round. Each run needed a second round for the 1200-word budget.
   The rest is lint, the proposed and approved commits, the approval prompt and push gates.
2. **Worker time.** One task per worker, with a single-digit number of tests each, took 2–26 min. Run 2's
   list worker spent 25.6 min alone: it built everything first, then rewrote it to stubs to make proof
   bases (8 commits: `88afe24` → `0cf9a63`).
3. **Per-task prove and mutate (run 2).** Each task gate builds scratch trees, so this adds about
   1–3 min per task.
4. **Serial merge gates.** Each is short, but a red one costs an undo, a fixer (~1.7 min) and another gate.
5. **Final ready gate.** 2.5–4.5 min, run once.
6. **Orchestrator overhead.** Checks, worktree create and remove, packs, ledger renders, Artifact
   publishes and notifications: a few seconds each, many times.

## Findings to research

Numbered for reference. Each says what happened, with the evidence.

1. **Speed floor.** The sketch design plus plan takes ~13 min before code; the spec's work takes
   another 25–35 min. That is well past a 45-minute interview that needs 3–4× this scope. Candidate
   directions: skip design and plan for interview specs, or fold them into 1 step. Run fewer, bigger
   tasks. Drop per-task prove and mutate at the interview preset and keep a single final ready gate.
   Or don't use the harness in an interview.
2. **Nothing checks that a surface commit is behavior-free.** Run 2's API surface `3a5dcb0` already held the
   real preview values, so the fixer's 2 preview tests can't be proven at any proof base.
3. **A task can only name 1 surface commit.** The list worker made several stub and implementation
   commits. Its task gate (run `20260927T211802Z-0119dcfa`, taken 3 s after its last commit, recorded
   GREEN) cited `4411bca`. At the final gate the same 7 tests are `not-proven` with `4411bca`, and still
   with `f6dba25` added (diagnostic run `20260927T213439Z-dc3c59bf`). **Unexplained:** why the task gate
   was GREEN. `worktree remove` deleted its report along with the task worktree's `.harness/runs/`.
   Nothing ties a gate run to the commit it ran at: the run history records no HEAD sha.
4. **The fast task gate doesn't check impact or coverage.** Run 2's API task passed its task gate, then
   failed its merge gate: `impact.untested-change` and `coverage.diff` 65%, run
   `20260927T210026Z-ac7b4ecd`. It cost an undo and a fixer round.
5. **`check-return --fix` rejects every fixer return.** It raises `build-return.review-missing`, but
   the fixer contract says `review` is always `null`. The fix path had never worked before; run 1 never
   used it.
6. **The session caches agent prompts.** Agent definitions load at session start, so the run 2 fixer
   ran the pre-`24fc934` prompt and omitted `surfaceCommit`. The workers got the new contract only
   through `build-task.js`'s brief.
7. **A task that changes a root reducer's API breaks the iOS view.** The host gate compiles
   `AppView.swift` out, so the break shows only at T3. It hides until the views task or the final gate
   runs, which is the open E2 item from trial run 1.
8. **The budget cutoff drops the task that makes the app compile.** At 30 min no new task starts, so
   the views task never ran and T3 failed.

## Manual steps in run 2 (see `run-2/manual-steps.md`)

- M1: the fixer's return lacked `surfaceCommit` (finding 6). The user approved adding `"surfaceCommit": null`.
- M2: `check-return --fix` was RED on finding 5. The orchestrator merged the fix branch anyway through a
  command sequence with no stop. `main` was GREEN after it (`20260927T210350Z-8fa5aecd`), and the orchestrator kept it.

## State left behind

- `interview-rehearsal-1` main is at `run-2-final` (`42b5902`). Plan `2026-09-27-posts-list-and-detail`
  is `building` (run `20260927T205514Z-9f10de46`, final gate recorded RED on its ledger page). Plan
  `2026-09-27-posts-list-detail` (run 1) is also `building`. The ending session released both claims, so any session
  can claim either plan.
- Branch `posts-api-surface` in `interview-rehearsal-1` is the hand-made surface base for run 1's proof.
