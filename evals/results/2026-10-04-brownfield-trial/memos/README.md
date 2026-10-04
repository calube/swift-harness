# Brownfield trial: usememos/memos

The first of the 3 brownfield trials (design §14). Repository `usememos/memos` at
`0d989707f82c33f74bb852edd8965ec88fcf041b`, cloned fresh on 2026-10-04 under a `trials/` directory outside every
harness checkout. The harness ran from this branch's `plugin/bin/swiftgate`.

**Verdict: the one-shot run BLOCKED.** `swiftgate run` prepared the clone and the orchestrator landed a GREEN
contract commit, then the harness's own plan-state guard refused every write of `PLAN.md`. The run imported,
built and merged nothing, and never reached `final`. Clone to first gate and the untouched-code findings pass; the `slice` p95 is inconclusive.

## Measures

| Measure | Value | Bar | Result | Source |
|---|---|---|---|---|
| Clone to first gate | 18.9 s: clone 8.7 s, `discover --apply` 4.5 s, `slice` 72 ms | under 3 min | PASS | `git clone` started 09:16:43Z; gate run `20261004T091702Z-b9a3c3b5` finished 09:17:02Z (`gate-history.jsonl`). No `gate.run` event exists to cite: see finding 2 |
| Findings on untouched code, empty commit | 0 | 0 | PASS | `slice-empty.json`, gate run `20261004T091702Z-b9a3c3b5` |
| Findings on untouched code, 1-line change | 0 on code. 1 `area.build-only` nit with no file or line: the report line that the warm-up hadn't run yet | 0 | PASS | `slice-one-line.json` (`20261004T091737Z-13449742`, 88.8 s cold) and `slice-one-line-rerun.json` (`20261004T091912Z-7a2ee17a`, 3.9 s warm) |
| `slice` p95 | 1 slice in the run: 25.3 s (`20261004T092416Z-a6af67a8`, the contract). All 4 slices on this clone: 0.07, 88.8, 3.9 and 25.3 s, so p95 by nearest rank is 88.8 s, set by the cold probe that ran before any warm-up | 30 s or less | INCONCLUSIVE | `gate-history.jsonl`, `gate-history-checkout.jsonl`. One in-run sample isn't a p95, and no `gate.run` events exist |
| One-shot run | Contract commit `95b513f8` on `swift-harness/spec`, GREEN at `slice`. 0 merges, no `final`. 0 user prompts: no `AskUserQuestion` call, and the session ended by itself with `stop_reason: end_turn` | `spec.md` to a GREEN plan branch, every merge and `final` GREEN, 0 human input | FAIL (BLOCKED) | `run.jsonl` `result` line, session `25eca2b9-1f9f-4503-82a1-ee423e3a00ee`; `run-report.md` |

Other numbers from the run:

- Run wall time, from launch to exit: 355 s. The session: 36 turns, $1.33, all on `claude-opus-5-5`.
- Warm-up, from `warmup.run` events: `go build ./...` took 3.3 s and `go test ./...` took 19.0 s, both `cold` and
  `passed`. Its test time is under the 30 s `slice_budget_s`, so the Go area isn't build-only.
- Machine load: about 28 to 40 throughout. I held the build-lock ticket from the warm-up's start until its process
  exited at 09:21:40Z.

## What happened

1. `discover --apply` found 1 area: Go, at the root, with 4 commands it marked as found. It missed the
   pnpm/TypeScript client in `web/` (finding 3).
2. `swiftgate run spec.md` copied the spec, wrote the clock, applied discovery, started the warm-up, created
   `swift-harness/spec` and launched `claude`.
3. The orchestrator read the spec. It replaced the test commands with
   `discover --apply --set memos.test=DRIVER=sqlite go test ./...` (`discover.run` with `edited: 2`), regenerated
   the protos with `buf generate`, landed the contract commit and gated it at `slice`, which came back GREEN.
4. It tried to write `<common>/swift-harness/plans/spec/PLAN.md` with the Write tool, and
   `guard.plan-state` denied it. It tried a shell heredoc, and the guard denied that too. It tried `plan claim`, which requires
   `--design` or `--spec-page`, and neither fits a live plan. It then stopped and reported BLOCKED instead of
   working around the guard. Its draft plan is `PLAN-draft.md`: 3 tasks (store, API, web) and 9 assumptions.

## Harness findings

1. **BLOCKER: a `swiftgate run` session can't write its own `PLAN.md`.**
   - `SwiftGateDomain/Hooks/Guards.swift` (`EditGuard`, `OrchestratorMarker`) treats `plans/<slug>/PLAN.md` as
     plan state. It lets a session write there only with `SWIFT_HARNESS_ORCHESTRATOR=1` or the plan's lock.
   - `SwiftGateCLI/Commands/RunCommand.swift` (`prepare`, `ExecClaudeLauncher`) and `RunLaunch.arguments` in
     `SwiftGateDomain/Brownfield/RunClock.swift` provide neither.
   - `SwiftGateCLI/Commands/PlanClaimCommand.swift` can't claim a plan with no design and no spec page.
   - Suggested fix: in `prepare`, mint a session UUID, write the plan lock with it, and pass
     `--session-id <uuid>` through `RunLaunch.arguments`. Or have `plan claim` accept a live-plan source that
     `plan import` honours.
   - Test: a prepared run's launched session id passes `EditGuard` for `plans/<slug>/PLAN.md`.
2. **Brownfield gates write no `gate.run` events.** `gate.run`, which §14 names as its source, is absent. Only
   `discover.run` and `warmup.run` reach `events list` (`events.jsonl`, 6 events). This is the open item that
   `brownfield-gates-record-and-judge` closes, so this README reads every gate measure from `runs/history.jsonl`.
3. **Discover drops the `web/` area.** `web/pnpm-workspace.yaml` holds only pnpm settings (`allowBuilds`,
   `patchedDependencies`) and no `packages:` key.
   - In `SwiftGateDomain/Brownfield/Discover/Readers/NodeReader.swift`, `workspaceGlobs` returns `[]`, not `nil`,
     for that file. `web/` therefore becomes a workspace root that matches no packages and yields no area.
   - Suggested fix: a `pnpm-workspace.yaml` with no `packages` list doesn't make a workspace root. Capture this
     repository's `web/` as a discover fixture.
   - Effect: the orchestrator planned the web task with hand-run `pnpm lint` and `pnpm test`, outside any gate.
4. **Discover doesn't mine CI env.** CI sets `DRIVER: sqlite` at step level, and the found `go test ./...` without it makes
   the store tests start MySQL and Postgres. The orchestrator fixed this through `--set`, as §11.2 intends.
   - Suggested fix: carry a job's `env:` into mined commands in `CICommandMining`.
5. **The SessionStart context describes the owned profile in a brownfield clone.** It says "active in memos
   (.swiftgate.toml)" and "the Stop hook runs `swiftgate check --tier fast`". The rendered settings' Stop
   `statusMessage` also says `check --tier fast`.
   - Hooks from `--settings` also run without `CLAUDE_PLUGIN_ROOT`, so the context reports "Plugin reference
     docs unavailable" and "Session record not written".
   - Files: `SwiftGateDomain/Hooks/SessionContext.swift` (`render`) and
     `SwiftGateDomain/Brownfield/HookSettings.swift`.
   - Suggested fix: branch the text on the profile, and set the plugin root in each settings hook command's
     environment.
6. **A failed launch leaves a prepared run behind.** In attempt 1 (`attempt-1/`), `claude` wasn't on `PATH`
   inside the `mise` toolchain environment. `ExecClaudeLauncher` failed after `prepare` had already created the
   plan dir and the `swift-harness/spec` branch and started a detached warm-up.
   - Suggested fix: resolve `claude` on `PATH` before `prepare`, or roll back the plan dir and branch when
     launch fails.
7. **Each stop ran the Stop hook twice.** `gate-history.jsonl` shows 2 `hook stop` runs finishing in the same
   second. Both were GREEN at about 130 ms, so the only cost is the duplicate work.

## Deviations

- **The candidate change already exists at the pinned commit.** Share expiry (`expires_ts`, `expire_time` and
  the share panel's expiry select) is already in place at `0d98970`. `spec.md` asks instead for a change of the
  same shape: an optional **view limit** on share links, with a migration per driver, a proto field, a web
  option, Go store and API tests, and a vitest test.
- **Toolchains.** I installed them with `mise` from a `mise.toml` in the parent `trials/` directory, so the clone
  stays clean: go 1.27.0, golangci-lint 2.13.1, node 24, pnpm 11.0.1 through `npm:pnpm` (the aqua pnpm package
  404s), and buf 1.73.0 for proto regeneration.
- **Environment.** I exported `DRIVER=sqlite` into the run's environment, as the trial asks.
- **Attempt 1.** I cleared attempt 1's plan dir and branch and stopped its warm-up before relaunching. Its partial
  Go caches stayed under `.git/swift-harness/caches`, so attempt 2's warm-up isn't a true cold start, though it
  labels itself `cold`.
- **No run past the blocker.** As the task asks, I didn't resume the session with `SWIFT_HARNESS_ORCHESTRATOR=1`.

## Files

| File | What |
|---|---|
| `spec.md` | the spec handed to `swiftgate run` |
| `discover-apply.json` | the first discovery, run right after the clone |
| `slice-empty.json`, `slice-one-line.json`, `slice-one-line-rerun.json` | the probe gates |
| `run.jsonl`, `run.stderr` | the headless session's stream-json and `run`'s stderr |
| `events.jsonl` | `swiftgate events list` after the run |
| `gate-history.jsonl`, `gate-history-checkout.jsonl` | gate run history, from the clone and from the plan checkout |
| `warmup.log`, `config.toml` | the warm-up log and the config after the orchestrator's `--set` |
| `PLAN-draft.md` | the plan the orchestrator couldn't write |
| `run-report.md` | `swiftgate run report spec` after the stop |
| `attempt-1/` | stderr and warm-up log of the launch that couldn't find `claude` |
