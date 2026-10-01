# What swift-harness does

A tour of every shipped capability, grouped by the problem it solves, with the command or file
behind each one. The [README](../README.md) has the highlights.
Rule ids live in [`plugin/docs/standards.md`](../plugin/docs/standards.md), and hook behaviour in
[`plugin/docs/hooks.md`](../plugin/docs/hooks.md).

## Agents can't cheat the gate

- **Subagents never prompt.** A background subagent can't answer a permission prompt, so the
  PreToolUse hook allows or denies every shell, edit, write and web call a subagent makes. It denies writes outside the repository's
  checkouts, build worker writes to the main checkout, and writes to `.git` and `.claude`, each
  with a reason the agent can act on.
- **Guards read the shell command, not its text.** The hook splits compound commands and sees env
  prefixes. It denies `simctl erase all` and `simctl delete all`, which would hit other sessions' simulators,
  deleting the global DerivedData, raw `xcodebuild`, and edits to `Package.resolved`, `.xcresult`
  bundles or snapshot references.
- **The Stop hook has a strike policy.** A RED fast tier blocks the stop, and the hook skips content
  that already passed. After 3 blocks in a row the hook lets the turn end and stamps it RED. A
  broken environment reports `blocked` and never counts as a strike.
- **Verdicts come from test reports.** `swiftgate test` reads xcresult bundles and test reports,
  not exit codes. It flags missing evidence, skips with no reason, and runs with no tests. A
  configured test retry is its own finding, because retries hide flakes.
- **Package pins hold.** Every build and test the gate runs uses the committed `Package.resolved`.
  A run that rewrote it, or found it stale, is a finding.
- **Surface commits add API and nothing else.** `swiftgate surface-check <commit>` proves every new
  body is empty, an empty default, or a forward to existing code. Reducers return `.none` and
  views are `EmptyView`. A later slice can't add a target the surface lacks.
- **Escape hatches carry a reason.** `// swiftgate:allow <rule> — <reason>` on the same line waives
  1 rule there. A bare allow is itself a finding, and reports count every waiver.
- **Ids don't leak.** `swiftgate comments --commit-msg` rejects plan, ledger and design ids in commit
  messages, and a testlint rule does the same for test names. The pre-commit comment check also
  catches restated code, diff narration and TODOs with no link.
- **Written-out scripts need a deadline.** A testlint rule flags a script or source that a test
  writes out and that waits forever.

## Tests have to earn their place

- **`prove`** reverts the source change and requires each new or changed host test to fail on an
  assertion. A test that only compiles against new API is `prove.compile-only`.
- **`mutate`** negates conditions, shifts boundaries, returns defaults and removes calls on the
  changed Core, client and Live lines, then re-runs the affected tests. A surviving mutant is RED.
- **`reach`** runs each new or changed test alone with coverage. A test that covers nothing in the
  module it claims to test is RED.
- **`stress`** runs new and changed tests N times. One failing run is RED.
- **`impact` and `coverage`** require a test change for every changed Core, client or Live module,
  and T1 tests alone to cover the changed lines.
- **`testlint`** flags tests that assert nothing, have assertions that can't fail, sleep, or sit in
  the wrong tier, and UI tests that map to no listed flow.
- **`judge`** asks a model what static checks can't see: whether a test would fail if the
  behaviour broke, vague names, implementation-detail assertions and the wrong tier. It's
  opt-in, because it sends test source off the machine, and advisory below `ready`. The backend is
  Claude or TypeSafe's Jev
  ([playbook §5.4](../plugin/docs/testing-playbook.md#54-judge-seam-swiftgate-judge)). Jev blocks
  on its own with a reason Claude writes, and hands its uncertain answers to Claude. `judge ask`
  prints any question set's answers as JSON, and `judge bench` scores backends on labelled cases
  ([first run](../evals/results/2026-09-30-judge-benchmark/summary.md)).

## The harness checks itself

- **`self-test`** proves every code rule trips on its seeded violations and passes the clean
  `examples/SampleApp`. `--judge` scores each backend's recording per question against its floors.
- **A test guards the rule index.** A test checks the rule id table in `standards.md` against the rule
  registries, so a rule can't ship undocumented or linger after removal.
- **Prompt edits need recalibration.** The push tier hashes the design agents and workflows and the
  build worker and fixer prompts, and compares the hash with the last passing `swiftgate calibrate` record. Any edit, or
  a record from a different model, blocks the push until calibration passes again.
- **`calibrate design|build`** runs each design agent, the build worker and the fixer against
  labelled seed cases and reports pass or fail per agent.
- **Hook latency has a tested budget.** The fastest of several PreToolUse runs stays under 50ms of
  CPU on a loaded machine.
- **The ready tier validates the plugin.** `claude plugin validate --strict` runs on `plugin/`,
  and every warning gates.
- **Fixtures come from real runs.** Every fixture under `plugin/gate/Tests/Fixtures/` comes
  from a real tool run, and its directory's README records the capture command.

## Parallel agents, 1 source of truth

- **1 orchestrator per plan.** `swiftgate plan claim` and `release` keep `orchestrator.lock` in
  the git common dir, so every worktree sees the same lock. The hook stops any tool call from
  forcing a release; taking over another session's lock is the user's call. Subagents never write
  plan state.
- **The ledger is a state machine.** `swiftgate ledger set` rejects a status change the current
  status can't make. `swiftgate index set` updates the cross-plan index under a file lock.
- **Waves never collide.** `swiftgate plan-schedule` builds topological waves, then splits them so
  no 2 tasks in a wave write the same files, capped at the plan's `max_parallel`. It never
  trusts a stored wave list.
- **The build executor checks every return.** `swiftgate build check-return` verifies a worker's
  return against git and rejects a missing or extra key. A merge conflict or a red `main` goes to
  a fixer agent in its own worktree, and a merge can be undone.
- **Time budgets have phases.** A build moves from normal to no new starts to cutoff, computed
  from the run record. The `interview` preset allows 38 minutes and starts only required tasks in
  the last 8. It runs `prove` and `mutate` once in the final gate
  ([ADR 0004](adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md)).
- **Worktrees start warm.** `swiftgate worktree create` clones a warm build into each task's
  worktree, and `warm-check` refuses when there is none. `swiftgate gc` prunes stale per-worktree
  DerivedData, old runs and orphaned simulator clones.
- **Agents get verbatim context.** `swiftgate context-pack --role` builds anchor-selected slices of
  the design, plan and standards for each agent role, and never summarises. It fails rather than
  write a thin pack. The module kinds a worker's write set touches pick which
  standards it gets.

## The gate checks designs like code

- **Evidence carries a hash.** `swiftgate evidence capture` runs a command and records its output
  and hash as a claim. `evidence check` re-verifies every claim at HEAD, against its file
  and `Package.resolved`.
- **`probe`** compiles a design's API snippets in a scratch package pinned to `Package.resolved`,
  so claims about SDK and package APIs are build-proven.
- **`design-diff`** classifies a revision as an amend (it touches requirements, decisions, module
  kinds or the test plan) or a clarify. `--chain` re-checks a plan's clarify chain against git
  history, so an approval carries across clarify-only edits.
- **`design-scope` and `design-lint`.** Scope picks a depth (quick, standard or deep) from the
  frame answers. Lint checks sections, evidence tags, id forms, word budgets and Mermaid syntax.
- **The verifier works blind.** It gets a reviewer's findings but never its
  reasoning, and reproduces each one. Standard designs get a challenger that asks whether the design
  is the best one, not only a complete one. Deep designs add a pre-mortem.

## Evidence you can paste into a PR

- **`review-synth`** dedupes verified findings and returns merge, fix-then-merge or
  refactor-needed. Findings on lines the change didn't touch are
  pre-existing and never count. A focus nobody reviewed shows as NOT REVIEWED. With `--design` it returns ready, revise
  or rethink, plus the reviewers to re-run.
- **`design-render`** renders a design as a page with diagrams, options, evidence badges and
  approval. `--ledger` renders the task graph, a wave timeline and a requirement by task coverage
  matrix. The build republishes it after every merge.
- **`/swift-harness:validate`** produces a paste-ready PR testing block: verdicts, counts and
  durations, plus anything that didn't run.

## Observability and operations

- **`stats`** reports per-command, per-tier p50 and p95 against budgets from run history.
  `--design` adds refute rate, reviewer precision, tokens and cost per agent, probe failures and
  cache hits. `--build` adds wall time per task.
- **`design-telemetry`** records each design run. Tokens no tool reported are null with a reason,
  never 0.
- **`doctor`** checks the Xcode pin, toolchain, runtime, disk and shim, and flags a plugin
  changed on disk since the session loaded it.
- **SessionStart context.** Each session starts with the module map and kinds, the Xcode pin, and
  the resume line of every active plan.
- **`/swift-harness:status`** lists active plans across every bootstrapped repository on the
  machine.
- **`bootstrap`** is a dry run by default; a re-run with nothing to change is a no-op. It
  infers `.swiftgate.toml` from the repository and names what it can't infer.
- **`docs-lint` and `prose`** check links, router reachability, dangling ids, word budgets and
  plain-English rules. Both run in the push tier.

## On the way

Simulator QA ([design](designs/2026-09-28-simulator-qa-design.md)) and agentic profiling
([design](designs/2026-09-28-agentic-profiling-design.md)) have approved designs. Neither has code
yet.
