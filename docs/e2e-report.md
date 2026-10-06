# End-to-end runs

This report records real runs of the harness on `examples/SampleApp` and scratch copies of it.
Each run seeds failures or hands the plugin a real task, then records the verdicts. Every run
found harness bugs, and each bug got a test-first fix before the verdicts below.

The 7 practice-app runs, from spec to merged code with no input, have their own page:
[practice-app results](results/2026-10-05-practice-app-results.md).

Each section records its findings as of its run date. Where a later change fixed an open finding,
and the code confirms it, the text says so.

## Summary

| Run | Date | What it showed | Harness bugs |
|---|---|---|---|
| [Bootstrap and seeded violations](#bootstrap-and-seeded-violations) | 2026-09-25 | Each layer turned its seed RED with the expected rule id; a clean tree stayed GREEN at every tier | 6 found, 6 fixed |
| [Review workflow](#review-workflow) | 2026-09-25 | The review returned `refactor-needed` on a design smell that passes every gate | 1 found, 1 fixed |
| [Hooks in a live session](#hooks-in-a-live-session) | 2026-09-25 | Hooks fired, denied and blocked as documented, in milliseconds | 0 |
| [Plugin install](#plugin-install) | 2026-09-26 | A marketplace install runs the plugin's agents, and the guards stop subagent writes to plan state | 1 found, 1 fixed |
| [A probe refutes an invented API](#a-probe-refutes-an-invented-api) | 2026-09-26 | A design kept a refuted claim out of its Decision | 5 fixed, 2 open at the time |
| [A standard design, unattended](#a-standard-design-unattended) | 2026-09-26 | The design workflow ran through 2 designs and 5 review rounds with no person | 5 fixed, several open |
| [Sprints, unattended](#sprints-unattended) | 2026-09-28 | 2 specs went to green `main` with no questions, on the second attempt | 7 found, 7 fixed |
| [Simulator QA](#simulator-qa) | 2026-10-04 | 9 of 10 acceptance checks passed; a log-only bug went RED once a check read the logs | 9 findings |

## Bootstrap and seeded violations

Date: 2026-09-25. Machine: Apple Silicon, Xcode 26.2 (17C48), iOS simulator runtimes 26.2 and 26.4.

The run met the harness the way a new adopter would. It copied the app into a throwaway git
repository, removed its harness files (`.swiftgate.toml`, `.harness/`), then bootstrapped it,
gated it at every tier, and seeded 1 violation per layer. `HOME` pointed at a scratch directory,
so bootstrap's registry entry, shim link and git hooks never touched the real home directory. A
local bare repository served as `origin`.

### Bootstrap

| Step | Result | Wall |
|---|---|---|
| `swiftgate bootstrap` (dry run) | 7 files to write, `.swiftlint.yml` left alone (SwiftLint not installed), 3 actions outside the repository listed; nothing written | 16s first run, then 1s |
| `swiftgate bootstrap --apply` | wrote AGENTS.md, CLAUDE.md symlink, `.swiftgate.toml`, `.swift-format`, `lefthook.yml`, `.gitignore`, `.harness/plans/index.json`; registered the repository, linked the shim, installed lefthook | 2s |
| second `--apply` | `0 to write, 7 unchanged`; no-op | 1s |
| `--apply` after the `.gitignore` template changed | appended only the missing `.build/` line | 1s |

The inferred config needs 2 hand edits before the gate goes GREEN, and the gate names both:

- `test.xcuitest-unlisted-flow`: the `CounterFlowUITests` test needs a `[[flows]]` entry.
- `arch.undeclared-kind`: `GameEngine` has no `@Reducer`, so it needs `kind = "engine"` in `[[modules]]`.

With no `origin/main`, every diff-based tier reports BLOCKED, because `merge-base HEAD
origin/main` fails. That verdict fits a broken environment, but it means a repository can't pass
its own pre-push gate until its remote branch exists.

### Clean tree, per tier

| Tier | How run | Verdict | Wall | Notes |
|---|---|---|---|---|
| fast | shell, config-only change | GREEN | 0s | no affected T1 targets |
| fast | shell, Core change + tests | GREEN | 1s | 6 affected tests |
| push | pre-push hook, cold build | GREEN | 139s | T1 119s: first SwiftPM build of 5 packages |
| push | shell, warm | GREEN | 27s | T1 5.5s |
| push | pre-push hook, warm, after the SDK fix | GREEN | 22s | T1 3.2s, 0 compile steps (47s before the fix) |
| push | pre-push hook, CounterFeature changed | GREEN | 58s | T2 snapshot 49s |
| ready | shell | GREEN | 366s | T1 166s rebuild (hook-environment bug below), T3 93s |
| ready | shell, Core change + tests | GREEN | 197s | T2 45s, T3 57s, prove 33s, mutate 47s |
| `test --tier t2` | shell | GREEN | 82s | on the iOS 26.2 pin; RED on 26.4 (bug 1) |

The run skipped the judge: it's opt-in because it makes a paid call.

### Seeded violations

Each seed is 1 commit on its own branch off `main`. The run passed seed code through `swift
format` first, so only the intended rule fires. "Lines" counts the swiftgate summary; the cap is 30.

| Layer | Seed | Tier | Expected | Observed verdict / rule id | Wall | Lines |
|---|---|---|---|---|---|---|
| lint | `Date()` in a `CounterCore` extension | fast | RED `det.date-init` | RED `det.date-init` | 5s | 6 |
| arch | `import SwiftUI` in `CounterCore` | fast | RED `arch.ui-framework-in-core` | RED `arch.ui-framework-in-core` | 2s | 6 |
| testlint | `@Test` whose body is `_ = CounterFeature.State()` | fast | RED `test.no-assertion` | RED `test.no-assertion` | 3s | 6 |
| comments | `// state.count += 2` staged, `git commit` | pre-commit (lefthook) | commit blocked, `comments.commented-out-code` | blocked, `comments.commented-out-code` (GREEN before bug 4 was fixed) | 1s (hook 0.09s) | 6 |
| impact | behavior-neutral Core line, no test change | push | RED `impact.untested-change` | RED `impact.untested-change`; the same seed pushed through the pre-push hook was rejected | 55s | 8 |
| coverage | new `if fact.isEmpty` branch no test reaches | push | RED `coverage.diff` | RED `coverage.diff` + `coverage.uncovered-lines` (lines 60–62) | 43s | 9 |
| T1 | increment adds 2 | fast | RED `t1.test-failed` | RED `t1.test-failed` ×2, each at its own test's line (both at the first test's line before bug 6 was fixed) | 2s | 7 |
| T2 | counter font 64 → 48 | push | RED `t2.test-failed` | RED `t2.test-failed` (snapshot does not match reference) | 61s | 7 |
| T3 | new `FactFlowUITests` with no `[[flows]]` entry | fast | RED `test.xcuitest-unlisted-flow` | RED `test.xcuitest-unlisted-flow` | 0s | 6 |
| prove | behavior-neutral Core rewrite + a new test of unrelated behavior | ready | RED `prove.not-proven` | RED `prove.not-proven` (mutate skipped: T1 RED) | 146s | 14 |
| mutate | decrement floors at 0; the new test starts at −3 | ready | RED `mutate.survived` | RED `mutate.survived`: relational-boundary `>` → `>=` | 204s | 15 |
| clean | the mutate seed + a test starting at 0 | ready, then pre-push hook | GREEN | GREEN (2/2 mutants killed); pushed through the hook | 197s / 58s | 15 / 8 |

### A surviving mutant in SampleApp itself

`swiftgate mutate --base 5ff680b^`, where every SampleApp line counts as added, found 1 surviving
mutant: `remove-call` on the `Logger(...).log(...)` call in `LogClient.osLog`'s `emit`. No test
observed that `emit` writes anything. `OSLogEmissionTests` now emits a record and reads it back
from `OSLogStore(scope: .currentProcessIdentifier)`, filtered by a per-test subsystem. It fails on
its assertion with the call deleted, and it passed 5 runs in a row.

| Run | Mutants | Killed | Survived | Wall |
|---|---|---|---|---|
| Before (`8c14d73^`) | 21 | 20 | 1 (`LogClientLive.swift`, `remove-call`) | 117.5s |
| After (`8c14d73`) | 21 | 21 | 0 | 121.6s |

### Harness bugs found and fixed

| # | Symptom in the run | Cause | Fix |
|---|---|---|---|
| 1 | T2 RED on a clean bootstrapped tree | bootstrap pinned the newest runtime (26.4), not the one matching Xcode 26.2 where the snapshot was recorded | `f0863f8`: prefer the runtime whose major.minor matches the Xcode, else the newest |
| 2 | every pre-push run rebuilt all packages (605 compile steps, T1 5.5s → 47s) | `/usr/bin/git` is an `xcrun` shim that exports `SDKROOT` (CommandLineTools SDK), `CPATH` and `LIBRARY_PATH` into hooks, and `swift test` inherited them | `71cbe29`: `LiveProcessRunner` drops them from its base environment |
| 3 | the first `git add -A` staged about 24k build files | bootstrap's `.gitignore` template did not ignore SwiftPM `.build/` | `122257e`: add `.build/` |
| 4 | `// state.count += 2` passed pre-commit | unfolded SwiftSyntax parses `+=` as a binary operator in a sequence, not an assignment node | `4faab0e`: compound assignments count as code; comparisons ending in `=` stay prose |
| 5 | committing a new bad fixture under `plugin/gate/Fixtures` was blocked | `comments --staged` ignored the config's `exclude` list | `bb6a229`: skip excluded paths before reading them |
| 6 | 2 TCA failures both reported at the first test's line | Swift Testing console issues were matched by first line, which TCA prints as `Issue recorded` for every failure | `acdcce9`: keep `↳` continuation lines and match the whole issue; new real capture `SwiftTest/shared-first-line` |

The run also changed SampleApp: `8c14d73` (the `emit` test above) and `18f5d81` (`swift format`
over 12 files). Without the format pass, the first edit to any of those files surfaced unrelated
`LineLength` and `Indentation` findings.

Gaps the run left:

- `impact.untested-change` fired on formatting-only source changes. Fixed: `impact` now skips a
  file whose tokens match the merge base.
- A test that pins unchanged behaviour at a boundary passes with the change reverted, so `prove`
  rejects it, though `mutate` needs it. Fixed in the `tdd` skill: assert both sides of the
  boundary in 1 test, and use literals rather than constants the change adds.
- Cold-build T1 (119 to 166s) runs over its 60s budget. The budget finding is a non-gating `minor`.

## Review workflow

`swiftgate review-input` ran on a change that passes `check --tier ready` but has a design smell.
`APIClient.live` shortens facts longer than 120 characters "for the counter screen". That's a
presentation rule inside a Live client, which standards rule D7 forbids; it belongs in
`CounterCore`. The bundle held `manifest.json`, `check.json`, `arch.json`, `testlint.json`,
`comments.json`, `mutate.json` and `diff.patch`.

The workflow ran 6 agents: 4 reviewers (concurrency, architecture, test-quality, api-errors) and 2
verifiers, 1 for each focus that reported findings. It took 50s and about 452k subagent tokens.
The verdict was `refactor-needed`, which is right for this change. The architecture and api-errors
reviewers each cited D7 on their own at `APIClientLive.swift:52`, and both verifiers kept the
blocker severity.

Caveat: the session that ran it didn't have the plugin installed, so each reviewer ran as a
general-purpose agent with its `plugin/agents/<focus>.md` body prepended. The
[plugin install](#plugin-install) run later showed that plugin agent types run by name.

Harness bug: `review-synth` listed the D7 finding twice. It deduped on (file, line, category), and
the 2 reviewers named the category in 2 ways (`logic-in-live-client`, `live-client-logic`). The fix
dedupes standards violations on (file, line, rule) and keeps the most severe copy. The 2 real
finding files are now the regression fixture (`plugin/gate/Tests/Fixtures/Review/`). The re-run:

```
review: refactor-needed — 1 findings (1 blocker)
1. [blocker] architecture,api-errors/logic-in-live-client (D7) Packages/APIClient/Sources/APIClientLive/APIClientLive.swift:52 — Counter-screen display truncation (120 chars + ellipsis) implemented inside APIClientLive
```

## Hooks in a live session

3 headless sessions (Claude Code 2.1.282) ran against the bootstrapped SampleApp copy. Each
loaded the plugin with `--plugin-dir` and `--setting-sources project,local`, so no user-level
hooks ran. `SWIFTGATE_HOOK_RECORD_DIR` captured every payload and outcome.

| Session | Prompt | Hooks that fired | Result |
|---|---|---|---|
| a | add a "last changed" date to CounterCore's reducer | SessionStart 1, PreToolUse 10, PostToolUse 7, Stop 1 | The model read `det.date-init` from the session context and used `@Dependency(\.date.now)` unprompted; every PostToolUse lint was clean; Stop ran `check --tier fast`: GREEN (10.8s), silent. |
| a2 | add a literal `Date()` to the reducer, don't fix what hooks report | SessionStart 1, PreToolUse 1, PostToolUse 1, Stop 4 | PostToolUse blocked with `det.date-init` at the edited line (31ms). Stop blocked RED 1/3, 2/3, 3/3 (`det.date-init` plus three `t1.build-failed`: the file has no `import Foundation`), then released with the `RED — not done` system message. |
| c | run raw `xcodebuild … test` | SessionStart 1, PreToolUse 1, Stop 1 | PreToolUse denied `guard.raw-xcodebuild`; the reason reached the model verbatim. Stop with no changed files: silent in 146ms. |

Every hook exited 0. In session a, `acceptEdits` didn't allow Bash, so the model's own
`swiftgate check` waited for approval; the Stop hook ran the check anyway.

Latency in process, from 30 recorded invocations:

| Hook | n | median | max |
|---|---|---|---|
| SessionStart (context) | 3 | 6ms | 40ms (first, cold module-map cache) |
| PreToolUse (allow / deny) | 11 / 1 | 0ms / 1ms | 0ms / 1ms |
| PostToolUse (format + lint) | 8 | 34ms | 187ms (first edit in a session) |
| Stop, full `check --tier fast` | 2 | n/a | 6.9s RED, 10.8s GREEN |
| Stop re-entry (cached verdict) | 3 | 102ms | 103ms |

With the shim and process start, a replay through `plugin/bin/swiftgate` averages 33ms
(PreToolUse) and 36ms (SessionStart) end to end.

The recorded payloads matched the hook fixtures on every field swiftgate reads, so the decoder
needed no change. 7 fixtures are now the scrubbed live payloads. These sessions didn't exercise
subagent payloads, Write, or SessionStart `resume`; the [plugin install](#plugin-install) run
covered subagent payloads.

## Plugin install

Date: 2026-09-26. Unattended: no person answered or approved anything.

The run used a scratch copy of `examples/SampleApp` with a local bare `origin`, Claude Code
2.1.282, `--setting-sources project,local` and `--model claude-sonnet-5`. A temporary logging hook
saved each hook's stdin. It installed the plugin from the copy, with nothing at user scope:

```
claude plugin marketplace add <harness checkout> --scope project
claude plugin install swift-harness@swift-harness --scope project
```

The first SessionStart said enforcement was warming up while the shim built `swiftgate`, which
took 2 min 17 s.

| Test | Command | Observed |
|---|---|---|
| Plugin agent types run | `claude -p … --output-format json --verbose`, Agent with `subagent_type: "swift-harness:design-lane-codebase"` | `init` listed 17 `swift-harness:*` agents; the agent returned a report. In the worktree session its `Read` fired PreToolUse with `agent_type: "swift-harness:design-lane-codebase"`. |
| Subagent writes denied | same, `--session-id` set to the id given to `swiftgate plan claim counter-reset --session <id>`, `bypassPermissions` | A `general-purpose` subagent's Write to `ledger.json`, the design doc and `<doc>.evidence/claims.jsonl`: each denied, `guard.plan-state`, 2–78 ms. The main session's same three writes succeeded. The subagent payloads carried the lock holder's `session_id`, so `agent_id` alone decided each denial. |
| 2 worktrees share plan state | `swiftgate index set counter-reset designing …`, `git worktree add`, `claude -p` in the second | Same `--git-common-dir` and `index.json` md5 from both. The second worktree's SessionStart listed `counter-reset (designing)`, and its session read the main session's `ledger.json`. |

A subagent's PreToolUse payload carries `agent_id` and `agent_type`, which a main-session payload
lacks. `agent_type` is plugin-qualified for plugin agents.

Findings:

- A `directory` marketplace runs the plugin from the checkout, so checkout edits apply without
  `claude plugin update`. Install still copies `plugin/` into the plugin cache, including the
  untracked `plugin/gate/.build` (843 MB).
- Project scope still writes the Claude config's `known_marketplaces.json` and
  `installed_plugins.json`. The user `settings.json` didn't change.
- Fixed: the `status` skill read a retired plan-index path. It now resolves each repository's git
  common dir, and `tests/plan_state_paths_test.mjs` fails on the old paths in shipped skills,
  agents or workflows.
- Without `origin/main` the first Stop came back BLOCKED and let the session end; with it, Stop
  stayed silent.

Cost: 3 sessions, $0.38, about 9 minutes with the cold build.

## A probe refutes an invented API

Date: 2026-09-26. Unattended: a second agent answered the frame questions in place of a person,
and the session labelled each such answer "orchestrator-answered rehearsal". No one approved or
merged the design.

The request leaned on a `@PersistedState` macro: a TCA property wrapper that saves a field across
relaunches. It sounds like TCA's `@ObservableState` and `@Presents`, but it doesn't exist. Before
the run, against the pinned `swift-composable-architecture` 1.26.2 checkout:

```
$ grep -rn 'PersistedState' .build/checkouts/swift-composable-architecture; echo "exit=$?"
exit=1
$ grep -rn 'PersistedState' .build/checkouts; echo "exit(all checkouts)=$?"
exit(all checkouts)=1
$ grep -rnE 'func persist(ed|ing)?\(' .build/checkouts/swift-composable-architecture; echo "exit=$?"
exit=1
```

As a control, the same tree does contain the real macros, in
`Sources/ComposableArchitecture/Macros.swift`.

Every run used `claude -p --plugin-dir <worktree>/plugin --model opus --setting-sources
project,local --max-budget-usd <cap> --output-format json`, and each answer came back through
`--resume`.

| Run | Result | Cost |
|---|---|---|
| 1 | the main session grepped for the macro itself and stopped before the frame | $0.18 |
| 2 (skill fixed) | frame questions returned as text, premise left to verify | $0.17 |
| 3 (frame answers) | claimed at `quick`; research lane `not-researched` (context-pack pin bug) | cumulative $1.38 |
| 4 (lane re-run) | probe refuted the macro; drafted; stopped on `docs-lint.dangling-id` (bug) | cumulative $3.83 |
| 5 | lint GREEN, review `ready`, committed `proposed` on a design branch, rendered; stopped at publish | cumulative $4.22 |

Runs 2 to 5 shared 1 session, so each cumulative cost includes run 2. With run 1's $0.18 and 2
4-question checks that cost $0.25 more, the run spent about $4.64 in all, as `claude -p` reports it,
over 27 minutes including the harness fixes.

**Result: PASS.** The probe reported `unknown attribute 'PersistedState'`, and
`evidence check` marked the claim `refuted`. The Decision cites only supported claims, and the
refuted id appears nowhere in the doc. As a control, citing it in Decision made `design-lint` RED:

```
design-lint.citation-not-supported: Decision cites "ev-persisted-state-macro-probe", which is refuted, not supported.
```

| Defect | Status |
|---|---|
| The design skill had no way to ask in headless mode, and the main session checked a named API itself | fixed in the skill: headless asks, and "a premise is a claim" |
| Headless asks put 5 questions in 1 prompt, over the cap of 4 | fixed in the skill |
| `context-pack --role research-lane` read every pin as `<pkg>@<version>`, and each lane's pack overwrote the last | fixed test-first |
| `docs-lint` passed no claims to reference integrity, so every `ev-` tag was `dangling-id` | fixed test-first |
| `design-lint.unverified-uncovered` can't match `… [UNVERIFIED].`, because the stripped text keeps a space before the period | open at the time |
| the bootstrap `.gitignore` template doesn't ignore `.harness/design-render/` | fixed: the template ignores it |
| `docs-lint` reported neither `unreachable-doc` nor `requirement-uncited` on the new doc | open at the time |

Headless mode has no `Artifact` tool, so publish and approval need an interactive session.

## A standard design, unattended

Date: 2026-09-26. Unattended, as above. Nobody approved, published, merged or pushed anything.

1 `claude -p` session (Claude Code 2.1.282, opus) ran `/swift-harness:design CounterFeature
history that survives relaunch` with `--permission-mode acceptEdits` and an allowed-tools list.
Each question ended a turn, and each answer came back through `--resume`.

1. **Frame.** 6 questions. `design-scope` said `quick`; the operator overrode it to `standard`.
2. **Standard design.** 4 lanes and 64 claims. Review came back `rethink`: the standards reviewer
   found file IO in CounterCore, against standards rules D2 and D3, and the verifier confirmed it.
3. **Reframe** with a `CounterHistoryClient` pair. `design-scope` said `deep`: 4 lanes, 124
   claims (85 supported) and 1 failed probe. Review rounds found 10, then 3, then 1 major finding,
   and the last round still ended `revise`, so publish never ran.

| Check | Result |
|---|---|
| `swiftgate self-test` | GREEN, 20.6 s |
| `swiftgate calibrate design` | RED once, then GREEN twice (23 cases, 11 agents, about 147 s); the flake is below |
| Approval, merge, `plan-lint` | need an interactive session |

Harness defects fixed test-first:

- The stamped `AGENTS.md` and `docs/index.md` failed prose, so a new repository's first push was RED.
- A markdown section's body ran to its next sibling heading, so `design-lint` counted a design
  about twice. All 59 design fixtures lint the same after the fix.
- Claim packs rejected probe citations; a probe now brings its snippet and verdict.
- The stamped `.gitignore` missed `.harness/design-render/`.
- A headless resume now sets `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`. Without it, `claude -p`
  ended the deep research workflow after 600 s and still reported success.

Findings left open at the time:

- No command changed a claimed plan's tier. Fixed since: `swiftgate plan set --tier`.
- `context-pack` infers the pin kind from its shape, so a short commit SHA reads as an SDK pin.
- The review workflow's `previous` input (about 41 KB) is too big for headless tool input.
- `evidence check` has no checkouts-path option, and it accepts a line range past the end of a file.
- `prove` restores only Swift production source, so it can't prove a test that guards a template.
- `calibrate design` flaked on `uikit-in-core-module`, answering D2 instead of A2 at p=0.55.

Cost and time: agents logged 2.0M tokens for 2 designs, against the design's estimate of 0.6 to
1M per standard design. Wall time was 78 minutes over 10 turns. Research lanes and redrafts took
most of it. The session and 3 `calibrate design` runs cost $28.35.

## Sprints, unattended

Date: 2026-09-28. Each run was a headless `claude -p "/swift-harness:sprint <spec file>"` (opus,
`bypassPermissions`) in a warm copy of the same starter app.

| Run | Spec |
|---|---|
| A | a form with field validation and on-device persistence |
| B | a multi-state approval workflow with undo and history |

### Attempt 1: neither run passed

A stopped at `finish` with `sprint.gate-blocked` after 56 minutes. B fast-forwarded `main` after
49 minutes, but it asked 2 questions and needed an override, so it failed the pass criteria.

| Step | A (5 slices) | B (4 slices) |
|---|---|---|
| Wall time | 56 min 9 s, then a 4-min resume | 49 min 32 s |
| Spec page | 2 min 7 s; confirm asked | 1 min 12 s; `guard.plan-state` denied the page write: question 1 |
| Surface | 2 min 36 s; `surface-check` RED twice | 32 s; GREEN first time |
| Slice 1 | 17 min 55 s; fast T1 runs of 417 s and 499 s | 2 min 48 s; push RED `coverage.diff`: question 2 |
| Ready | 10 min 50 s, 2 runs | 14 min 47 s BLOCKED, then 24 min 23 s GREEN in the foreground |
| Finish | refused `sprint.gate-blocked` | `main` fast-forwarded |

| Defect | Hit by | Fix |
|---|---|---|
| `prove` stopped at the merge base when a new package's targets were empty there | A | `prove` retries at the proof base |
| `guard.plan-state` read `sprints/` as a plan | B | the guard allows sprint pages |
| slice push gates measured coverage from `main`, counting surface stubs | A, B | slice gates measure from the surface |
| T3 cloned a booted device, and `simctl` had a fixed 60 s deadline | A, B | T3 never clones a booted base |
| `surface-check` judged an added manifest dependency as behaviour | A | additive manifest edits pass |
| the skill lacked the accessor stub, the no-allow rule for surface findings, and a foreground `ready` | A, B | skill updated |
| a slice could add a target the surface lacks | A | `sprint` refuses it |

### Attempt 2: both runs passed

Both repositories restarted from their warm starts. Neither session asked a question or hit a
`sprint` refusal. A shared the machine with a mutation-testing worker, so its times run high.

| Step | A (4 slices) | B (4 slices) |
|---|---|---|
| Wall time | **31 min 45 s**, $2.75 | **12 min 28 s**, $1.02 |
| Preflight | 35 s | 31 s |
| Spec page | 1 min 32 s; no confirm | 26 s; no confirm |
| Surface | 51 s; GREEN first time | 26 s |
| Slices | 1 min 46 s, 48 s, 1 min 21 s, 47 s | 51 s, 40 s, 32 s, 39 s |
| Ready | 23 min 26 s, 5 runs | 7 min 46 s, 2 runs |
| Finish | 14 s; `main` fast-forwarded | 20 s; `main` fast-forwarded |

| Run | Gate | Verdict | Gating rule | Fix the session made |
|---|---|---|---|---|
| A | push, slice 1 | RED | `coverage.diff`, 2 `coverage.no-t1-tests` | the new client's tests moved into slice 1 |
| A | ready, 242 s | RED | 2 `mutate.survived` | a scope test and a boundary test |
| A | ready, 228 s | BLOCKED | T1 `prove.no-evidence`: no `Package.resolved` in the new package | `swift package resolve`, lockfile committed |
| A | ready, 226 s | RED | 2 `prove.compile-only`: an API renamed after the surface | a stub commit as a 2nd `--proof-base`, then a restore commit |
| A | ready, 169 s | RED | `prove.not-proven`: the stub left the accessor real | a 2nd stub-and-restore pair |
| A | ready, 272 s | **GREEN** | | |
| B | ready, 245 s | RED | `mutate.survived`: the child `Scope` removed | a root-store test |
| B | ready, 208 s | **GREEN** | | |

The other fast-tier REDs were the inner loop at work. No fast T1 run in attempt 2 took over 7 s.

Open findings from these runs:

| Finding | Evidence |
|---|---|
| Fast-tier runs of 7 to 8 minutes, unexplained | A, attempt 1: 417 s and 499 s runs whose SwiftPM builds took 4.75 s and 18.5 s |
| A new package with no `Package.resolved` BLOCKS `ready` | prove's scratch copy resolves with automatic resolution off |
| A surface API renamed mid-sprint needs a stub-then-restore commit pair to prove | A, attempt 2: 4 extra commits and 2 extra `ready` runs |
| The created-device path boots a fresh simulator on every T3 run | each T3 run creates, boots and deletes its own device (41 to 97 s) |
| `sprint.target-outside-surface` can only halt | its fix rewrites the surface, but `sprint.json` accepts `surface` only straight after `start` |

## Simulator QA

Date: 2026-10-04. `agent-device` 0.21.18, Xcode 26.2, each device a clone that `sim up` made from
the configured iPhone 17 (iOS 26.2). The `sim` lock is machine-wide, with its default cap of 2.

The skill steps ran from `examples/SampleApp`. The isolation check used a scratch copy with 2
extra git worktrees. The validation table and the planted bug used a second scratch copy with its
own plan state.

### Acceptance checks

| Check | Result | Evidence |
|---|---|---|
| `doctor` is GREEN | pass | 0 gating findings |
| `/swift-harness:qa`, counter flow, `fixed-fact` scenario | pass | `sim up --scenario fixed-fact`; 3 steps asserted `0`, `1` and the fixed fact |
| `sim verify` GREEN | pass | `stepCount` 3, `headCommit` equals the checkout's HEAD |
| `sim down` leaves nothing | pass | `released: true`; no clone, lease or `agent-device` session left |
| Seeded branch RED on both accessibility rules | pass | RED, `sim.a11y-identifier` (Button "Share") and `sim.a11y-label` (Button `counter.dot`) |
| 3 `sim up` from 3 worktrees, cap 2: the third queues | pass | a and b leased; c waited, then leased, built and returned after a's `sim down` |
| SIGKILL the holder, then `gc` leaves no device and no claim | **fail** | `gc` deleted the clone, but the lease file, the `agent-device` session and its device claim survived (finding 1) |
| Validation table: `--at-base` fails each row, `qa run` passes, `--final` leaves MP4 and contact sheet | pass, with gaps | below; findings 3 and 4 |
| T3 leaves the kept flow's `qa.flow` with `source: xcuitest` | pass | GREEN 2/2; 2 `qa.flow` events, each with video and sheet |
| Validation tab links each flow step to its video offset | pass | 7 of 7 steps link `video.mp4#t=<s>` in all 3 reports |

### The validation table

The scratch app's `feature` branch adds a Reset button (`counter.reset`). It also logs `count
changed count=<n>` through `LogClient` on each count change, and adds the unit test
`resetAfterIncrementsShowsZero`. The plan has 3 rows for 1 requirement:

- acceptance: `swift test --filter resetAfterIncrementsShowsZero`, whose output must say a test ran;
- flow: `qa/reset.flow.json`, which increments twice, checks `1` and `2`, resets and checks `0`;
- state: `qa/reset.state.sh`, which reads the last 3 `count changed` lines from the device log
  and requires `1 2 0`.

| Command | Wall | Result |
|---|---|---|
| `qa run --at-base` | 47 s | acceptance red (no test ran at base); flow red, `qa.flow-unknown-id` for `counter.reset`; state unverified (no device) |
| `qa run` | 126 s | 3 of 3 pass |
| `qa run --final` | 93 s | 3 of 3 pass; `video.mp4`, `sheet.png`, 7 steps with offsets; logs saved |

### Planted bug: a value the screen never shows

The bug logs the count before the increment, so every increment logs the old value while the
screen shows the new one:

```diff
       case .incrementButtonTapped:
+        log.log(.notice, "count changed", category: "Counter", [.public("count", state.count)])
         state.count += 1
         state.fact = nil
-        log.log(.notice, "count changed", category: "Counter", [.public("count", state.count)])
         return .none
```

For b2, a second copy held the same diff with the state row removed. `/swift-harness:qa` then ran
in a fresh `claude -p` session, with a prompt that asked for QA and evidence and didn't mention logs.

| Run | Flow row | State row | Verdict | What showed the bug |
|---|---|---|---|---|
| clean | pass | pass, `1 2 0` | GREEN | nothing to show: the logs read `count=1`, `count=2`, `count=0` |
| b1, targeted | pass | **red** | RED | the state row quotes `count=0`, `count=1`, `count=0`, and the viewer's "Why it failed" shows them |
| b2, untargeted | pass | no row | **GREEN**, plus a prose warning | the skill read the diff, saw the log call before `+= 1`, and confirmed it in the collected log. It reported that no check reads log contents, so the verdict stays GREEN |

The acceptance unit test passed in every run, because it checks state, not the log. In the run
viewer, b2's page looks the same as the clean one: no row can show the bug.

### Findings, ranked

1. **`gc` didn't free what a killed holder left.** It deleted the clone but left the lease file,
   the `agent-device` session and its device claim. Fixed since: `gc` frees each lease a dead
   `sim hold` left, with its session and claims, before it deletes clones.
2. **A log-only bug passes validation unless a row targets it.** In b2 every row passed. The skill
   spotted the bug from the diff, but by its rule ("`swiftgate` is the judge") it can't turn a log
   mismatch into RED. With a state row reading the device log (b1), the run went RED.
3. **`--at-base` passed an acceptance test that exists only on the branch.** A plain
   `swift test --filter` row read `pass` at base, printing `No matching test cases were run`
   and exiting 0. It took a check that also requires a test to run to get a red at base.
4. **At base, a state row behind a lint-red flow never gets a red run.** The flow stops at
   `qa.flow-unknown-id` and no device comes up, so the state row reads unverified.
5. **A cold shim build ended a `claude -p` QA session with no verdict.** The first `qa run` waited
   behind a 190 s release build and the headless turn ended. On a warm cache the session ran to
   the end (495 s, $0.36).
6. A red row's report `message` is only `exit 1`. The reason is in the row's `.txt` evidence,
   which the viewer's popover shows.
7. A plain `qa run` needs the ledger's `waves` key, but `--at-base` doesn't read the ledger.
8. `sim snap --assert` can only check that text is present. A negative value such as `-2` parsed
   as a flag. Fixed since: `--assert` takes a value that starts with `-`.
9. `sim verify` can't tell a build from uncommitted changes.

### Wall time per command

| Command | Wall |
|---|---|
| `doctor` | 2.4 s |
| `sim up` (cold DerivedData / warm) | 103 s / 31 s |
| `sim snap` | 1.4 to 2.0 s |
| `sim down` | 4.4 to 5.0 s |
| `sim verify` | 0.1 s |
| `gc` after SIGKILL | 3.8 s |
| `qa run --at-base` | 47 to 71 s |
| `qa run` | 126 s |
| `qa run --final` | 90 to 116 s |
| `test --tier t3` | 91 s |
| b2 `/swift-harness:qa` session | 150 s (killed) / 495 s |
