# What swift-harness does

A tour of every shipped capability, grouped by the problem it solves, with the command or file
behind each one. The [README](../README.md) has the highlights. Rule ids live in
[`plugin/docs/standards.md`](../plugin/docs/standards.md), and hook behaviour in
[`plugin/docs/hooks.md`](../plugin/docs/hooks.md). Every command takes `--help`.

## Agents can't cheat the gate

- **Subagents never prompt.** The PreToolUse hook allows or denies every shell, edit, write and
  web call a subagent makes. It denies writes outside the repository's checkouts, build worker
  writes to the main checkout, and writes to `.git` and `.claude`, each with a reason the agent
  can act on.
- **Guards read the shell command, not its text.** The hook splits compound commands and sees env
  prefixes. It denies `simctl erase all` and `simctl delete all`, deleting the global
  DerivedData, raw `xcodebuild`, and edits to `Package.resolved`, `.xcresult` bundles or snapshot
  references.
- **The Stop hook has a strike policy.** A RED fast tier blocks the stop. After 3 blocks in a row
  the hook lets the turn end, stamped RED. A broken environment reports `blocked`, never a strike.
- **Verdicts come from test reports.** `swiftgate test` reads xcresult bundles and test reports,
  not exit codes. It flags missing evidence, skips with no reason, and runs with no tests. A
  configured test retry is its own finding, because retries hide flakes.
- **Package pins hold.** Every gate build uses the committed `Package.resolved`. A run that
  rewrote it, or found it stale, is a finding.
- **Surface commits add API and nothing else.** `swiftgate surface-check <commit>` proves every new
  body is empty, an empty default, or a forward to existing code. Reducers return `.none` and
  views are `EmptyView`.
- **Escape hatches carry a reason.** `// swiftgate:allow <rule> — <reason>` on the same line waives
  1 rule there. A bare allow is itself a finding.
- **Ids don't leak.** `swiftgate comments --commit-msg` rejects plan, ledger and design ids in
  commit messages, and a testlint rule does the same for test names. The pre-commit check also
  catches restated code, diff narration and TODOs with no link.

## Tests have to earn their place

| Command | What it proves |
|---|---|
| `prove` | Each new or changed host test fails on an assertion with the source change reverted. A test that only compiles against new API is `prove.compile-only` |
| `mutate` | Tests kill mutants (negated conditions, shifted boundaries, default returns, removed calls) on the changed Core, client and Live lines |
| `reach` | Each new or changed test, run alone with coverage, reaches the module it claims to test |
| `stress` | New and changed tests pass N runs in a row |
| `impact`, `coverage` | Every changed Core, client or Live module has a test change, and T1 tests alone cover the changed lines |
| `testlint` | No test asserts nothing, holds an assertion that can't fail, sleeps, or sits in the wrong tier |

**`judge`** asks a model what static checks can't see: whether a test would fail if the
behaviour broke, vague names, implementation-detail assertions and the wrong tier. It's opt-in,
because it sends test source off the machine, and advisory below `ready`. The backend is Claude or
TypeSafe's Jev ([testing playbook](../plugin/docs/testing-playbook.md#54-judge-seam-swiftgate-judge)).
Jev blocks on its own with a reason Claude writes, and hands its uncertain answers to Claude.
`judge bench` scores backends on labelled cases
([first run](../evals/results/2026-09-30-judge-benchmark/summary.md)).

## Simulator QA

`/swift-harness:qa` checks a change in a running app, and `swiftgate` judges the evidence
([`simulator-qa.md`](../plugin/docs/simulator-qa.md),
[ADR 0005](adrs/0005-simulator-qa-drives-agent-device.md),
[ADR 0008](adrs/0008-simulator-qa-layered-validation.md)).

| Command | What it does |
|---|---|
| `sim up --scenario <name>` | Leases a simulator clone under a machine-wide cap, builds and installs the app, and launches it in a dependency scenario |
| `sim snap <label> --assert <text>` | Records a screenshot and accessibility tree as the next step |
| `sim verify` | Judges the recorded steps GREEN, RED or BLOCKED, including missing accessibility ids and labels |
| `sim down` | Closes the session, deletes the clone and frees the slot |
| `sim hold --run <runID>` | Holds 1 slot and device for a run; `sim up` starts it, and you don't run it yourself |
| `qa lint` | Checks `agent-device` flow files offline, before any device boots |
| `qa run` | Runs a plan's validation rows in layer order: acceptance, flow, state |

`qa run --at-base` runs each row at the merge base and records why it fails there, so a row that
passes before the change proves nothing. `qa run --final` records video and a contact sheet for
each flow. A flow worth keeping becomes an XCUITest in the T3 tier. Under a preset's `sim_qa`
setting, `/build`, `/sprint` and `/ship` run QA as a validate stage after the final gate.

## Repositories the harness doesn't own

The brownfield profile runs in a repository with its own languages, architecture and commands
([design](designs/2026-10-03-brownfield-profile-design.md)). It writes no file into the working
tree and no commit to the user's branch.

| Command | What it does |
|---|---|
| `discover --apply` | Infers each area's build and test commands and keeps the config under the git common dir |
| `warmup` | Warms each area's caches and records its times and baseline |
| `run <spec.md> --time-box <min>` | Launches a headless orchestrator that plans and builds the spec with no input |
| `check --tier slice\|merge\|final` | Gates each slice, merge and the final branch. A failure the merge base shares never gates, and a changed test must fail with its change reverted |
| `test-only <test>` | Compiles and runs 1 test as a cheap loop before a merge gate |
| `allow <rule> <location> --reason` | Waives 1 finding on 1 line, with a reason |
| `xcode` | Adds files to Xcode targets without restructuring the project |

## The harness checks itself

- **`self-test`** proves every code rule trips on its seeded violations and passes the clean
  `examples/SampleApp`. `--judge` scores each backend's recording per question against its floors.
- **A test guards the rule index.** It checks the rule id table in `standards.md` against the
  rule registries, so a rule can't ship undocumented or linger after removal.
- **Prompt edits need recalibration.** The push tier hashes the design and build agent prompts
  against the last passing `swiftgate calibrate` record. Any edit, or a different model, blocks
  the push until `calibrate design|build` passes again on labelled seed cases.
- **Hook latency has a tested budget.** The fastest of several PreToolUse runs stays under 50ms of
  CPU.
- **The ready tier validates the plugin.** `claude plugin validate --strict` runs on `plugin/`,
  and every warning gates.
- **Fixtures come from real runs,** and the fixtures README records each capture command.

## Parallel agents, 1 source of truth

- **1 orchestrator per plan.** `swiftgate plan claim` and `release` keep `orchestrator.lock` in
  the git common dir, so every worktree sees the same lock. Subagents never write plan state.
- **The ledger is a state machine.** `swiftgate ledger set` rejects a status change the current
  status can't make. `swiftgate index set` updates the cross-plan index under a file lock.
- **Waves never collide.** `swiftgate plan-schedule` builds topological waves, then splits them
  so no 2 tasks in a wave write the same files, capped at the plan's `max_parallel`.
- **The build executor checks every return.** `swiftgate build check-return` verifies a worker's
  return against git. A merge conflict or a RED `main` goes to a fixer agent in its own
  worktree, and `build merge` can undo a merge.
- **Time budgets have phases.** A build moves from normal to no new starts to cutoff. The
  `interview` preset allows 38 minutes and starts only required tasks in the last 8. It runs
  `prove` and `mutate` once in the final gate
  ([ADR 0004](adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md)).
- **Worktrees start warm.** `swiftgate worktree create` clones a warm build into each task's
  worktree. `swiftgate gc` prunes stale DerivedData, old runs and orphaned simulator clones.
- **Agents get verbatim context.** `swiftgate context-pack --role` slices the design, plan and
  standards by anchor for each role, and never summarises.

## The gate checks designs like code

- **Evidence carries a hash.** `swiftgate evidence capture` runs a command and records its output
  and hash as a claim. `evidence check` re-verifies every claim at HEAD.
- **`probe`** compiles a design's API snippets in a scratch package pinned to `Package.resolved`,
  so claims about SDK and package APIs are build-proven.
- **`design-diff`** classifies a revision as an amend or a clarify. `--chain` re-checks a plan's
  clarify chain, so an approval carries across clarify-only edits.
- **`design-scope` and `design-lint`.** Scope picks a depth (quick, standard or deep) from the
  frame answers. Lint checks sections, evidence tags, id forms, word budgets and Mermaid syntax.
- **The verifier works blind.** It gets a reviewer's findings but never its reasoning, and
  reproduces each one.

## Evidence you can paste into a PR

- **`review-synth`** dedupes verified findings and returns merge, fix-then-merge or
  refactor-needed. Findings on lines the change didn't touch never count. A focus nobody
  reviewed shows as NOT REVIEWED.
- **`design-render`** renders a design as a page with diagrams, options and evidence badges.
  `--ledger` renders the task graph, a wave timeline and a coverage matrix.
- **`/swift-harness:validate`** produces a paste-ready PR testing block: verdicts, counts and
  durations, plus anything that didn't run.

## Observability and operations

- **Local telemetry, on by default.** Gate runs, test results, hooks, caches, build halts and
  token counts land in `.harness/events/`, with no source, prompt or key. `events summary`
  reports cost, gate time, wrong verdicts, flaky tests and halts. `[telemetry] enabled = false`
  opts out, except the judge's audit log ([`telemetry.md`](../plugin/docs/telemetry.md)).
- **The run viewer.** `report --html` writes 1 offline page per build run: timeline, a kanban
  board of tasks, the dependency graph in waves, spec coverage, gates and proofs, tokens and
  dollar cost, and validation rows with flow videos. `view` serves it live
  ([`run-viewer.md`](../plugin/docs/run-viewer.md)).
- **`stats`** reports per-command, per-tier p50 and p95 against budgets from run history.
- **`doctor`** checks the Xcode pin, toolchain, runtime, disk and shim, and flags a plugin changed
  since the session loaded it.
- **SessionStart context** gives each session the module map, the Xcode pin, and every active
  plan's resume line. `/swift-harness:status` lists active plans across the machine.
- **`bootstrap`** infers `.swiftgate.toml`, names what it can't infer, and is a dry run by default.
- **`docs-lint` and `prose`** check links, router reachability, dangling ids, word budgets and
  plain-English rules. Both run in the push tier.

## Not built yet

Agentic profiling has an approved design
([design](designs/2026-09-28-agentic-profiling-design.md),
[ADR 0006](adrs/0006-profiling-wraps-xctrace-report-only-first.md)) and no code. `swiftgate` has
no `profile` subcommand.
