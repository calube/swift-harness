# Fast modes: implementation plan

<!-- RESUME
Status: PLANNED 2026-09-27. Starts after speed wave 2 of the build-executor plan merges (docs/plans/2026-09-26-build-executor-plan.md "Speed").
Spec: docs/designs/2026-09-27-fast-modes-design.md (approved 2026-09-27). Decision record: [ADR 0003](../adrs/0003-ship-may-skip-the-design-step.md).
Scope: surface commits (`swiftgate surface-check`) and sprint. Design-free ship waits for sprint's rehearsals and gets its own plan tasks then.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan".
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate, with mutate once on main.
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

| Decision | Evidence | Reversal |
|---|---|---|
| `surface-check` analyses source text in `SwiftGateDomain` with SwiftSyntax; reading the commit's diff and file contents is an adapter | Gate layering; `SwiftSyntax` already runs in the domain for T0 checks | — |
| Sprint state is its own file, `sprint.json`, under the plan-state directory in the git common dir, written under the same lock as other plan state | Spec §4.2, §7 (no ledger); plan state is shared by every worktree | Fold into the ledger |
| Sprint states are a closed enum; the transition table lives in the domain and every command goes through it | Spec §4.2; worker-brief pitfall 1 | — |
| `sprint slice` and `sprint finish` read the gate run from run history by id and compare its `headCommit` to the branch HEAD | Speed wave 1 added `headCommit` to every gate run | — |
| `sprint finish` fast-forwards `main` only; it never merges or rebases | Spec §4.2: `main` only moves to a green sprint | A merge commit |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and behaviour, and
  proves at it (worker brief pitfall 10). Once `surface-check` merges, workers also run it on their surface.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a wave,
  merge every surface commit first and prove at that merge. Mutate runs once on `main` after the wave.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `TD/` `TA/` `TC/` = `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI}Tests/`,
  `P/` = `plugin/`.

### Merge points (hot files)

| File | Edited only by |
|---|---|
| `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift` | `surface-check-command`, then `sprint-commands` (different waves) |
| `plugin/docs/standards.md` rule id index | `surface-check-command`, then `sprint-commands` |
| `docs/index.md` | `sprint-skill` |

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `surface-check-command`, `sprint-state-machine` | independent: a new command, and a pure state model |
| 2 | `sprint-commands` | needs both |
| 3 | `sprint-skill` | calls every command |
| 4 | `sprint-rehearsals` | attended: the user runs it on 2 different practice prompts |

### `surface-check-command`
- Deps: none · Gate: push · Model: opus · estLines: 420
- Writes: `D/Surface/SurfaceCheck.swift`, `A/Surface/SurfaceCommitReader.swift`, `C/Commands/SurfaceCheckCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `plugin/gate/Tests/Fixtures/surface/` (captured), the fixtures README, `plugin/docs/standards.md` (rule index rows), their tests
- Does: §3.2: `swiftgate surface-check <commit> [--json]`. Over the commit's diff against its first parent, every added or changed body must be an allowed stub (§3.2 table, with §7's empty-defaults answer), including an initializer that only assigns its parameters or empty defaults, a value built by 1 initializer call from empty defaults and pass-through parameters, and bare type references or `Type.self` added to an existing array literal. Any other body, `fatalError`, `preconditionFailure`, non-empty preview data or an added test file is `surface-check.behaviour` (major) naming the file and declaration. Exit 0 GREEN, 1 RED, 2 when the reader can't load the commit. A summary note `surface-check.summary`.
- Tests: 1 captured commit per allowed body passes, and 1 per rejected shape fails naming its declaration. A stub returning non-empty sample data fails: this catches a surface holding real values. A `fatalError` stub fails. An added test file fails. A commit whose parent the reader can't load exits 2, never GREEN. Each rule id is in the standards rule index.

### `sprint-state-machine`
- Deps: none · Gate: push · Model: opus · estLines: 300
- Writes: `D/Sprint/SprintRun.swift`, `D/Sprint/SprintTransition.swift`, `A/PlanState/SprintStore.swift`, their tests
- Does: §4.2: `SprintRun` (slug, spec page path, branch, base `main` sha, surface sha, slices with status and gate run id, final gate run id) and a closed `SprintStep` enum: `started`, `surfaced`, `slicing(n)`, `finished`. `SprintTransition` accepts only start, surface, slice n in page order, finish; anything else is an error naming the step it expected. `SprintStore` reads `sprint.json` and replaces it by atomic rename under the plan-state lock, in a temp repo's git common dir in tests.
- Tests: every legal transition passes and every illegal 1 fails naming the expected step. Slice 2 before slice 1 fails. Finish before every slice fails. Round-trip is byte-stable. An unknown step fails decoding. 2 concurrent writers lose no update.

### `sprint-commands`
- Deps: surface-check-command, sprint-state-machine · Gate: push · Model: opus · estLines: 480
- Writes: `C/Commands/SprintCommand.swift`, `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `A/Build/GitWorkspace.swift` (branch create and fast-forward only), `plugin/docs/standards.md` (rule index rows), their tests
- Does: §4.1–4.2: `swiftgate sprint start <slug> --spec-page <path>` (from a GREEN `main`, creates `sprint/<slug>`), `sprint surface <sha>` (runs `surface-check`; refuses on any finding), `sprint slice <n> --gate <run id>`, `sprint finish --gate <run id>`, `sprint status [--json]`. `slice` refuses a RED, BLOCKED or push-below gate run, or 1 whose `headCommit` isn't the branch HEAD. `finish` refuses unless the run is a GREEN `ready` with prove at the surface base and `headCommit` equal to HEAD, and unless `main` is still at the recorded base; then it fast-forwards `main`. Every refusal exits 1 with `sprint.<reason>` naming what to do.
- Tests: in a temp repo with real commits, each refusal fires: stale `headCommit`, RED gate, a tier below push, a surface with behaviour, `main` moved, a `ready` run without prove Removing each check turns its test red. The happy path fast-forwards `main` to the branch. `status` names the next step after a simulated crash.

### `sprint-skill`
- Deps: sprint-commands · Gate: push · Model: opus · estLines: 260
- Writes: `P/skills/sprint/SKILL.md`, `P/skills/sprint/references/spec-page.md`, `tests/skill_commands_test.mjs` (its rows), `docs/index.md` (router row), `plugin/docs/` router if it lists skills
- Does: §4.1 and §5.2: the skill writes the spec page, skips the confirm only when every slice maps to an acceptance test the spec lists (§7), and otherwise asks once with `AskUserQuestion`. It then drives `swiftgate sprint` step by step, with the fast tier as the inner loop and push at each slice. It never advances past a refusal by hand. It stays generic: no app shape, prompt or preset value in its text.
- Tests: every `swiftgate` command and flag the skill names exists (contract test). The skill's steps match the state machine's order. The skill-reviewer or `claude plugin validate --strict` check passes.

### `sprint-rehearsals`
- Deps: sprint-skill · Gate: ready · Model: opus · estLines: 60
- Writes: `docs/e2e-report.md`
- Does: attended. The user runs `/swift-harness:sprint` on 2 different practice prompts in a warm starter repo, timed with the run history. The report records wall time per step, every refusal and whether the final gate was GREEN.
- Tests: both runs end with `main` fast-forwarded and a GREEN `ready` gate, with no manual step except the spec-page confirm.
