# swift-harness

A Claude Code plugin that holds agent-written SwiftUI code to the same bar as a staff engineer's,
and proves it did.

![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange) ![iOS 18+](https://img.shields.io/badge/iOS-18%2B-blue) ![Xcode 26.2](https://img.shields.io/badge/Xcode-26.2-lightgrey)

## Why

Coding agents write Swift fast. Left alone, they also drift: a `Date()` in a reducer, a singleton
behind a protocol, a `try!` with no reason, a test that passes whether the code works or not. Rules
in a prompt don't hold. The agent forgets them, and every place that's meant to enforce them
checks something a little different.

swift-harness fixes that with 1 rule: **there is 1 gate.** `swiftgate` is a Swift CLI that
owns every check: lint, architecture, test tiers, red/green proof, mutation and evidence. Claude
Code hooks, skills, agents, workflows and git hooks all call it, and none of them re-implement a
check. When the gate says green, it's green everywhere.

## How it works

```mermaid
flowchart LR
  subgraph Claude Code
    SK[Skills<br/>/ship · /design · /plan · /build · /review …]
    WF[Workflows + agents<br/>design research · review · build tasks]
    HK[Hooks<br/>SessionStart · PreToolUse · PostToolUse · Stop]
  end
  GIT[Git hooks<br/>pre-commit · commit-msg · pre-push]
  SK --> WF
  SK --> G
  WF --> G
  HK --> G
  GIT --> G
  G[[swiftgate]] --> T[swift format · swift test<br/>xcodebuild · simulators]
  G --> R[Run report<br/>evidence · verdict]
```

- **Hooks keep the agent honest while it types.** The hook formats and lints each Swift edit on the
  spot. It denies raw `xcodebuild`, hand edits to snapshots or `Package.resolved`, and wiping
  simulators. The session can't stop while `swiftgate check --tier fast` is red.
- **Git hooks hold the same line outside Claude.** Pre-commit and commit-msg check comments.
  Pre-push runs the push tier. They call the same binary, through a stable symlink.
- **Skills and workflows do the thinking; the gate does the judging.** `/design` fans out research
  and review agents, `/plan` schedules tasks into waves, and `/build` runs them in parallel
  worktrees. Each step asks `swiftgate` for the verdict instead of deciding on its own.
- **`swiftgate` follows the layering it enforces.** It has a pure domain module, IO adapters
  behind protocols, and a thin CLI. It proves its own rules with `swiftgate self-test`.

## Highlights

**Agents can't fake green.**

- A new test has to fail with the source change reverted (`prove`), kill mutants on the lines you
  changed (`mutate`), and reach the module it claims to test (`reach`). Verdicts come from the test
  reports, not exit codes, and a configured retry is itself a finding because retries hide flakes.
- `surface-check` proves a commit adds API and no behaviour: every body is empty or a forward,
  reducers return `.none`, views are `EmptyView`. Slices then have to fill it in test-first.
- Hooks parse the shell command itself. Compound commands and env prefixes don't get raw
  `xcodebuild`, a simulator wipe or a snapshot edit past them.

**The harness checks itself.**

- Every rule has a seeded violation, and `swiftgate self-test` proves each one fires and that
  clean code passes.
- A test checks the rule table in `standards.md` against the rule registries, so a rule can't ship
  undocumented.
- Editing any design or build agent's prompt blocks `git push` until `swiftgate calibrate` passes
  that agent again on labelled cases, with the same model.
- Hook latency is a tested budget: under 50ms of CPU on the PreToolUse path, even on a loaded
  machine.

**Parallel agents, 1 source of truth.**

- `plan-schedule` orders tasks into waves where no 2 tasks write the same files, and `/build` runs
  each one in its own warm git worktree. A single orchestrator lock and a ledger that rejects
  illegal status changes keep parallel sessions from trampling each other.
- Subagents never hit a permission prompt. The hook allows or denies every call a subagent makes,
  with a reason the agent can act on.
- A time-budgeted preset stops starting tasks at minute 30 and has green code on `main` by 38.

**The gate checks designs like code.**

- Design claims cite evidence with a hash, and `evidence check` re-verifies each one at HEAD.
  `probe` compiles a design's API snippets against the pinned packages.
- The verifier reproduces each review finding without seeing the reviewer's reasoning.
  `review-synth` dedupes the findings and returns merge, fix-then-merge or refactor-needed.
  Findings on lines the change didn't touch never count against it.

Every capability, with the command behind it: [`docs/capabilities.md`](docs/capabilities.md).

## The bar

Opinions, written down in [`standards.md`](plugin/docs/standards.md) and enforced by the gate
rather than suggested.

**Code**

- **Swift 6 language mode, iOS 18+, a pinned Xcode.** `swiftgate doctor` blocks on a mismatch.
- **Thin app target, logic in local packages.** Each module has a kind: `feature` (TCA reducer),
  `engine`, `render`, `library` or `client`. Core modules import no UI framework and test on the
  Mac under `swift test`. `swiftgate arch` checks the module graph.
- **TCA 1.x is the default architecture:** `@Reducer`, `@ObservableState` and `TestStore`.
- **No hidden nondeterminism.** The gate bans `Date()`, `UUID()`, `Task.sleep`, `asyncAfter` and
  `.random` in Core. Time, randomness and IO arrive through `@Dependency`.
- **Every service is a `FooClient` / `FooClientLive` pair.** Vendor SDKs live only in `*Live`
  modules, only the app target imports them, and there are no singletons.
- **Log and trace through `LogClient` / `TracingClient`**, with privacy-tagged attributes. No
  `print`, no direct `Logger`.
- **Escape hatches need a reason on the same line.** `try!`, `as!`, `fatalError`,
  `@unchecked Sendable` and every suppression carry `swiftgate:allow <rule> — <reason>`.
- **Comments carry only what the code can't.** No restated code, no history, no codenames.

**Tests**

- **4 tiers, each with a budget:** T0 static (< 5s), T1 host (< 60s), T2 simulator snapshots, and
  T3 flow smoke tests capped by config.
- **A new test must fail first.** `swiftgate prove` reverts the source change and requires every
  new or changed test to fail on an assertion.
- **Tests must catch mutants.** `swiftgate mutate` flips conditions and boundaries on changed lines,
  and `swiftgate reach` runs each test alone to show it touches the module it claims to test.
- **Slop is a finding.** Tests that assert nothing, are tautological, sleep, or sit in the wrong
  tier fail `swiftgate testlint`. A judge agent reviews what static checks can't see.
- **Verdicts come from the test reports**, not from the exit code.

## Proof

The harness gets tested the way it tests apps: seeded failures, real runs, recorded verdicts. The
full record is in [`docs/e2e-report.md`](docs/e2e-report.md).

- **Every layer catches its seed.** The run bootstrapped `examples/SampleApp` fresh, the way a new
  adopter would. Then it seeded 1 violation per layer, from a `Date()` in Core and an
  assertion-free test to a snapshot drift, an unproven test and a surviving mutant. The gate turned
  each one RED with the expected rule id, and a clean tree stayed GREEN at every tier.
- **The run found bugs in the harness too.** It found 6, from a pre-push hook that rebuilt every
  package to a commented-out `+=` that slipped past pre-commit. Each got a test-first fix and a
  re-run.
- **Spec to green `main`, unattended.** 2 headless `/swift-harness:sprint` runs built real
  features (a validated, persisted form and an approval workflow with undo) from a spec file. The
  first attempt failed both and exposed 7 defects. After the fixes, both passed with no questions:
  31m 45s ($2.75) and 12m 28s ($1.02).
- **The gate tests itself.** `swiftgate` carries about 2,300 Swift Testing cases against fixtures
  captured from real tool runs, never hand-written. `swiftgate self-test` proves every rule fires
  on its seeded violation and passes clean code.

Next: [evals](evals/README.md) that measure the harness across many tasks and trials, with and
without it. They're planned, not running yet.

## A run, end to end

Hand it a spec and pick how much ceremony the change deserves.

**`/swift-harness:ship <spec>`** takes a spec all the way to merged, green code:

1. **Preflight.** `swiftgate doctor` checks the machine, the Xcode pin and a clean, warm `main`.
2. **Design.** `/design` picks a depth (quick, standard or deep). Research agents read the
   codebase, Apple's docs, packages and prior decisions, and probes compile the risky claims. Then
   challengers, a pre-mortem and a standards check review the draft before you approve it.
3. **Plan.** `/plan` breaks the design into sized tasks, and `swiftgate plan-schedule` orders them
   into waves.
4. **Build.** `/build` runs each task test-first in its own git worktree, in parallel. It checks
   and merges every return, and runs the merge gate on `main` after each merge.
5. **Report.** The ledger page shows each task's verdict and the build's wall time.

It stops at the first halt (a red `main` after the fixer, a design conflict, a spent time budget)
and says where to resume.

**`/swift-harness:sprint <spec>`** is the fast path for a spec that already says what to build. It
has no design doc, no worktrees and no workers. It writes a 1-page spec with 1 acceptance test per
slice and lands a surface commit that `swiftgate surface-check` proves adds API but no behaviour.
Then it builds each slice test-first behind a push gate, and fast-forwards `main` only after a
final `ready` gate. `/ship` can take the same shortcut under a preset that skips design
([ADR 0003](docs/adrs/0003-ship-may-skip-the-design-step.md)).

## Quick start

The repository is its own plugin marketplace, and the plugin it serves is `plugin/`. Register it
once per machine, then enable it only in the iOS repositories that use it:

```bash
claude plugin marketplace add calube/swift-harness      # or a local checkout: ./path/to/swift-harness
cd /path/to/your-ios-app
claude plugin install swift-harness@swift-harness --scope project   # or --scope local
```

Then run `/swift-harness:bootstrap` in a session there. It runs `swiftgate bootstrap` (dry run,
then `--apply`), which writes `.swiftgate.toml`, `AGENTS.md`, the git hooks, and links
`~/.local/bin/swiftgate`.

To try a checkout without installing anything, pass its plugin directory for 1 session:
`claude --plugin-dir /path/to/swift-harness/plugin`.

<details>
<summary>Why project or local scope, not user scope</summary>

`marketplace add` records the marketplace in your user settings but enables nothing. `--scope
project` writes the plugin to the repository's `.claude/settings.json`, which you commit:

```json
{
  "enabledPlugins": { "swift-harness@swift-harness": true }
}
```

`--scope local` writes the same key to `.claude/settings.local.json` instead, for you alone.
Avoid the default user scope: it loads the hooks in every session on the machine. They no-op
outside a repository with `.swiftgate.toml`, but each still spawns a process per tool call.

Sources: https://code.claude.com/docs/en/plugin-marketplaces,
https://code.claude.com/docs/en/plugins/install (install scopes),
https://code.claude.com/docs/en/settings-reference (`enabledPlugins`).

</details>

## Reference

### Skills

Each runs as `/swift-harness:<name>`.

| Skill | Use it to |
|---|---|
| `ship` | take a spec to merged, green code: design, plan and build in 1 command |
| `sprint` | build a spec in 1 session on 1 branch, with no design doc or workers |
| `design` | frame, research, draft, review, publish and amend a design before any code |
| `plan` | turn an approved design into a build plan of sized, scheduled tasks |
| `build` | run a plan's tasks in parallel worktrees until merged `main` is green |
| `bootstrap` | stamp or upgrade the harness in an iOS repository |
| `architecture` | pick a new module's kind and scaffold its packages |
| `tdd` | write a failing test first, then make it pass |
| `test-gate` | run the pre-ready gate and judge new tests for slop |
| `review` | run the multi-agent code review on a Swift change |
| `pr-feedback` | work review comments to a stopping rule: validate, fix, gate, reply, resolve |
| `comment-audit` | judge each comment a change adds: keep, trim or cut |
| `validate` | produce ready-for-review evidence and a PR body block |
| `prose` | write docs that pass the plain-English rules `swiftgate prose` checks |
| `status` | list active plans across this machine's bootstrapped repositories |

<details>
<summary><code>swiftgate</code> subcommands</summary>

Run `swiftgate <subcommand> --help` for any of these.

| Area | Subcommands |
|---|---|
| Gate tiers | `check`, `test`, `stats` |
| Static checks | `lint`, `arch`, `testlint`, `impact`, `comments`, `coverage`, `module-graph` |
| Test proof | `prove`, `mutate`, `reach`, `stress`, `judge`, `snapshots` |
| Design | `design-scope`, `design-lint`, `design-diff`, `design-render`, `design-telemetry`, `evidence`, `probe` |
| Plan and build | `plan`, `plan-schedule`, `plan-lint`, `ledger`, `index`, `build`, `worktree`, `context-pack` |
| Fast modes | `sprint`, `spec-page`, `surface-check` |
| Review | `review-input`, `review-synth` |
| Docs | `docs-lint`, `prose` |
| Harness | `bootstrap`, `doctor`, `gc`, `hook`, `self-test`, `calibrate` |

</details>

## Roadmap

Designed and approved, not built yet:

- **Simulator QA.** `swiftgate sim` launches the app with launch-argument dependency scenarios. A
  QA skill drives it through `agent-device` and keeps screenshots and accessibility trees as
  evidence. Flows worth keeping become T3 UI tests.
  [Design](docs/designs/2026-09-28-simulator-qa-design.md) · [ADR 0005](docs/adrs/0005-simulator-qa-drives-agent-device.md)
- **Agentic profiling.** `swiftgate profile` and `leaks` wrap `xctrace` and `leaks` and cut their
  output down to compact JSON an agent can read. They start report-only, measured per signpost.
  [Design](docs/designs/2026-09-28-agentic-profiling-design.md) · [ADR 0006](docs/adrs/0006-profiling-wraps-xctrace-report-only-first.md)

Both plug into `/build`'s validate stage once they land.

## Contributing

Contributor material (this README, `AGENTS.md`, `docs/`, `examples/`, `tests/`) stays at the root;
everything consumers install lives in `plugin/`. Start at [`AGENTS.md`](AGENTS.md), then
[`docs/index.md`](docs/index.md).

`cd plugin/gate && swift build && swift test && swift format lint --strict -r Sources Tests Package.swift`.
`swift test` also runs every `tests/*_test.mjs` (needs `node`) and `tests/shim_test.sh`, and reports
each as skipped when its interpreter is missing from `PATH`.
`claude plugin validate .` checks the marketplace manifest and `claude plugin validate --strict plugin`
the plugin; `plugin/bin/swiftgate check --tier ready` runs the latter.
