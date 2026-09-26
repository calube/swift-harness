# SampleApp end-to-end run

Date: 2026-09-25. Machine: Apple Silicon, Xcode 26.2 (17C48), iOS simulator runtimes 26.2 and 26.4.

The harness was proven on `examples/SampleApp` the way a new adopter would meet it: the app was
copied into a throwaway git repository outside this one, its harness files (`.swiftgate.toml`,
`.harness/`) removed, then bootstrapped, gated at every tier, and seeded with one violation per
layer. `HOME` was pointed at a scratch directory for the whole run, so bootstrap's registry entry,
`~/.local/bin/swiftgate` link and the lefthook hooks that call it never touched the real home
directory. A local bare repository served as `origin`.

The run found six harness bugs. Each was fixed test-first in `gate/` and the affected step re-run;
the verdicts below are from after the fixes.

## Mutation finding in SampleApp

`swiftgate mutate --base 5ff680b^` (every SampleApp line counts as added) reproduced the one
surviving mutant: `remove-call` on the `Logger(...).log(...)` call in `LogClient.osLog`'s `emit`.
No test observed that `emit` writes anything. `OSLogEmissionTests` now emits a record and reads it
back from `OSLogStore(scope: .currentProcessIdentifier)`, filtered by a per-test subsystem. It
fails on its assertion with the call deleted and passed 5 runs in a row.

| Run | Mutants | Killed | Survived | Wall |
|---|---|---|---|---|
| Before (`8c14d73^`) | 21 | 20 | 1 (`LogClientLive.swift`, `remove-call`) | 117.5s |
| After (`8c14d73`) | 21 | 21 | 0 | 121.6s |

## Bootstrap

| Step | Result | Wall |
|---|---|---|
| `swiftgate bootstrap` (dry run) | 7 files to write, `.swiftlint.yml` left alone (SwiftLint not installed), 3 actions outside the repository listed; nothing written | 16s first run, then 1s |
| `swiftgate bootstrap --apply` | wrote AGENTS.md, CLAUDE.md symlink, `.swiftgate.toml`, `.swift-format`, `lefthook.yml`, `.gitignore`, `.harness/plans/index.json`; registered the repository, linked the shim, installed lefthook | 2s |
| second `--apply` | `0 to write, 7 unchanged`; no-op | 1s |
| `--apply` after the `.gitignore` template changed | appended only the missing `.build/` line | 1s |

The inferred config needs two hand edits before the gate goes GREEN, and the gate says which ones.
It cannot infer them:

- `test.xcuitest-unlisted-flow`: the `CounterFlowUITests` test needs a `[[flows]]` entry.
- `arch.undeclared-kind`: `GameEngine` has no `@Reducer`, so it needs `kind = "engine"` in `[[modules]]`.

With no `origin/main`, every diff-based tier is BLOCKED (`merge-base HEAD origin/main` fails). That
is the right verdict, since the environment is wrong, but a repository bootstrapped before its
first push can't pass its own pre-push gate until the remote branch exists.

## Clean tree, per tier

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

The judge step was not run: it's opt-in because it makes a paid call.

## Seeded violations

Each seed is one commit on its own branch off `main`. Seed code was run through `swift format`
first, so only the intended rule fires. Output lines count the swiftgate summary; the cap is 30.

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

## Review input

`swiftgate review-input` ran on a change that passes `check --tier ready` but has a design smell:
`APIClient.live` shortens facts longer than 120 characters "for the counter screen". That is a
presentation rule inside a Live client, and it belongs in `CounterCore`. Push GREEN, 2/2 mutants
killed, the test proven. Bundle: `manifest.json`, `check.json`, `arch.json`, `testlint.json`,
`comments.json`, `mutate.json`, `diff.patch`; focuses concurrency, architecture, test-quality,
api-errors. The review workflow's run on this bundle is below.

## Review workflow (real run)

The workflow ran through the Workflow tool on that bundle: 6 agents (4 reviewers: concurrency,
architecture, test-quality, api-errors; 2 verifiers, one each for the two focuses that reported
findings), 50s wall clock, about 452k subagent tokens. SwiftUI was not applicable. Verdict:
`refactor-needed`, which is correct for this change.

The architecture and api-errors reviewers each cited D7 on their own at
`APIClientLive.swift:52` (display truncation inside a Live client). Both verifiers traced the rule
and the diff and kept the blocker severity.

Caveat: the plugin was not installed in the session that ran it, so the agent types were emulated.
Each reviewer ran as a general-purpose agent with its `agents/<focus>.md` body prepended to the
prompt. The plugin's own agent definitions still need a run after install.

Harness bug found: `review-synth` listed the D7 finding twice. It deduped every finding on
(file, line, category), and the two reviewers named the category differently
(`logic-in-live-client`, `live-client-logic`). Fixed: standards violations now dedupe on
(file, line, rule), keeping the most severe copy and recording every reporting focus in
`review.json`; defects keep the (file, line, category) key. The two real finding files are now the
regression fixture (`gate/Tests/Fixtures/Review/`). Re-running `review-synth` on the run directory:

```
review: refactor-needed — 1 findings (1 blocker)
1. [blocker] architecture,api-errors/logic-in-live-client (D7) Packages/APIClient/Sources/APIClientLive/APIClientLive.swift:52 — Counter-screen display truncation (120 chars + ellipsis) implemented inside APIClientLive
```

Not reproduced: the gap noted earlier about HTML-escaped `&gt;` in reviewer output. The structured
workflow output and `review.json` contain no HTML entities. The escaping appeared only in how a
notification displayed the result.

## Harness bugs found and fixed

| # | Symptom in the run | Cause | Fix |
|---|---|---|---|
| 1 | T2 RED on a clean bootstrapped tree | bootstrap pinned the newest runtime (26.4), not the one matching Xcode 26.2 where the snapshot was recorded | `f0863f8`: prefer the runtime whose major.minor matches the Xcode, else the newest |
| 2 | every pre-push run rebuilt all packages (605 compile steps, T1 5.5s → 47s) | `/usr/bin/git` is an `xcrun` shim that exports `SDKROOT` (CommandLineTools SDK), `CPATH` and `LIBRARY_PATH` into hooks, and `swift test` inherited them | `71cbe29`: `LiveProcessRunner` drops them from its base environment |
| 3 | the first `git add -A` staged about 24k build files | bootstrap's `.gitignore` template did not ignore SwiftPM `.build/` | `122257e`: add `.build/` |
| 4 | `// state.count += 2` passed pre-commit | unfolded SwiftSyntax parses `+=` as a binary operator in a sequence, not an assignment node | `4faab0e`: compound assignments count as code; comparisons ending in `=` stay prose |
| 5 | committing a new bad fixture under `gate/Fixtures` was blocked | `comments --staged` ignored the config's `exclude` list | `bb6a229`: skip excluded paths before reading them |
| 6 | two TCA failures both reported at the first test's line | Swift Testing console issues were matched by first line, which TCA prints as `Issue recorded` for every failure | `acdcce9`: keep `↳` continuation lines and match the whole issue; new real capture `SwiftTest/shared-first-line` |

Also changed on the SampleApp: `8c14d73` (the `emit` test above) and `18f5d81` (`swift format` over
12 files). Before that, the first edit to any of those files surfaced unrelated `LineLength` and
`Indentation` findings.

## Live Claude Code session

Three headless sessions (Claude Code 2.1.282) against the bootstrapped SampleApp copy, plugin
loaded with `--plugin-dir` (nothing installed globally), `--setting-sources project,local` so no
user-level hooks ran, and `SWIFTGATE_HOOK_RECORD_DIR` capturing every payload and outcome.

| Session | Prompt | Hooks that fired | Result |
|---|---|---|---|
| a | add a "last changed" date to CounterCore's reducer | SessionStart 1, PreToolUse 10, PostToolUse 7, Stop 1 | The model read `det.date-init` from the session context and used `@Dependency(\.date.now)` unprompted; every PostToolUse lint was clean; Stop ran `check --tier fast`: GREEN (10.8s), silent. |
| a2 | add a literal `Date()` to the reducer, don't fix what hooks report | SessionStart 1, PreToolUse 1, PostToolUse 1, Stop 4 | PostToolUse blocked with `det.date-init` at the edited line (31ms). Stop blocked RED 1/3, 2/3, 3/3 (`det.date-init` plus three `t1.build-failed`: the file has no `import Foundation`), then released with the `RED — not done` system message. |
| c | run raw `xcodebuild … test` | SessionStart 1, PreToolUse 1, Stop 1 | PreToolUse denied `guard.raw-xcodebuild`; the reason reached the model verbatim. Stop with no changed files: silent in 146ms. |

Every hook exited 0 (stream `hook_response` events agree with the recorder). Session a's Stop
also showed a gap in the dogfood set-up, not the harness: `acceptEdits` doesn't allow Bash, so
the model's own `swiftgate check` waited for approval; the Stop hook ran the check anyway.

Latency, in-process (`elapsed_ms` from the recorder outcome files, 30 invocations):

| Hook | n | median | max |
|---|---|---|---|
| SessionStart (context) | 3 | 6ms | 40ms (first, cold module-map cache) |
| PreToolUse (allow / deny) | 11 / 1 | 0ms / 1ms | 0ms / 1ms |
| PostToolUse (format + lint) | 8 | 34ms | 187ms (first edit in a session) |
| Stop, full `check --tier fast` | 2 | — | 6.9s RED, 10.8s GREEN |
| Stop re-entry (cached verdict) | 3 | 102ms | 103ms |

Adding the shim and process start, replaying recorded payloads through `bin/swiftgate` averages
33ms (PreToolUse) and 36ms (SessionStart) end to end.

Schema: the recorded payloads were compared field by field with the hook fixtures. No field
swiftgate reads differed (`session_id`, `cwd`, `hook_event_name`, `tool_name`,
`tool_input.command`/`file_path`, `stop_hook_active`, `source`), so no decoder change was needed.
Differences were in unread fields only (listed in `gate/Tests/Fixtures/README.md`). Seven
fixtures are now the scrubbed live payloads; one test's expected command changed to the live one.

Not exercised live: subagent payloads (`agent_id`), Write, SessionStart `resume`, and the git
pre-commit / pre-push hooks (the plan's T7.6 lists those; they run through lefthook, not Claude
Code, and are covered by the bootstrap section above).

## Known gaps, not fixed

- Fixed since: `impact.untested-change` fired on formatting-only source changes (`18f5d81` was RED
  on push). `impact` now skips a file whose tokens match the merge base.
- Fixed since (tdd skill § 5): proving boundary tests: a test that only pins unchanged behavior at a boundary (a fact of exactly
  120 characters is kept) passes with the change reverted, so `prove` rejects it on its own, even
  though `mutate` needs it to kill `>` → `>=`. Asserting both sides of the boundary in one test
  satisfies both checks. A test that calls API the change adds is `prove.compile-only`, so tests
  use literals, not new constants. The `tdd` skill should say both.
- Cold-build T1 (119–166s) is over its 60s budget. The budget finding is a non-gating `minor`.

## Rehearsal (unattended, 2026-09-26): a probe refutes a nonexistent API

This is a rehearsal, not the attended acceptance run. The user was away and approved running it
unattended. The orchestrator answered the frame questions in the user's place, and this section
labels those answers "orchestrator-answered rehearsal". No one clicked Approve, and no one merged
the design branch. The design is throwaway.

Set-up: `examples/SampleApp` copied to a scratch directory outside this repository, `git init`,
the bootstrap `.gitignore` template added, and `swift package resolve` run in
`Packages/CounterFeature`. The checkout of `swift-composable-architecture` is at `1.26.2`
(`377da4061db10d26337a71bb279c506bb951f50f`), the version and revision `Package.resolved` pins.

### The API, proven absent before the run

The request leans on a `@PersistedState` macro: a TCA state property wrapper that saves a field
across relaunches. It sounds like TCA's `@ObservableState` and `@Presents`, but it doesn't exist.
Run from `Packages/CounterFeature` at 2026-09-26T12:23Z, before the design run started:

```
$ grep -rn 'PersistedState' .build/checkouts/swift-composable-architecture; echo "exit=$?"
exit=1
$ grep -rn 'PersistedState' .build/checkouts; echo "exit(all checkouts)=$?"
exit(all checkouts)=1
$ grep -rnE 'func persist(ed|ing)?\(' .build/checkouts/swift-composable-architecture; echo "exit=$?"
exit=1
```

Every grep printed no match. As a control, the same tree does contain the real macros:
`grep -rln 'macro Presents\|macro ObservableState' .build/checkouts/swift-composable-architecture/Sources`
finds `Sources/ComposableArchitecture/Macros.swift`.

### Runs

Every run used `claude -p --plugin-dir <worktree>/plugin --model opus --setting-sources project,local
--max-budget-usd <cap> --output-format json` from the temp copy (Claude Code 2.1.282,
`claude-opus-5-5`), with `SWIFTGATE_CACHE_DIR` pointed at a scratch cache. The first 2 runs used
`--permission-mode bypassPermissions` inside the temp copy. Every resume used `--permission-mode
acceptEdits --allowedTools "Bash,Read,Write,Edit,Glob,Grep,Workflow,Task,Agent,ToolSearch,Skill,SendMessage"`.

| Run | Session | Result | Cost |
|---|---|---|---|
| 1 | `cd44873c…` | the main session grepped for the macro and stopped before the frame; asked in plain text | $0.18 |
| 2 (skill fixed) | `7ee8373b…` | frame questions returned as text, premise left to verify | $0.17 |
| 3 (`--resume`, frame answers) | same | claimed at `quick`; research lane `not-researched` (context-pack pin bug) | cumulative $1.38 |
| 4 (`--resume`, rerun lane) | same | probe refuted the macro; drafted; stopped on `docs-lint.dangling-id` (bug) | cumulative $3.83 |
| 5 (`--resume`) | same | lint GREEN, review `ready`, committed `proposed` on `design/persist-counter-count`, rendered; stopped at publish | cumulative $4.22 |

Two 4-question checks cost $0.25 more, so the rehearsal spent about $4.64 as `claude -p` reports it.
Wall time was 27 minutes, 12:26Z to 12:53Z, including the harness fixes.

Resume across asks works: `claude -p --resume <session id> … "<answers>"` from the same directory.

### Frame answers (orchestrator-answered rehearsal)

Area: a new area, counter. Touched: CounterCore only. New modules: none. New dependencies: none.
Constraints: no new dependency and no persistence client. Tier: `design-scope` recommended
`quick`, and the session took it. When research returned `incomplete`, the worker chose to rerun
the lane after fixing the pin bug. That was a worker-answered rehearsal choice, not the user's.

### Tests

- **The claim ends `refuted` and never appears in Decision: PASS.** The probe reported
  `unknown attribute 'PersistedState'` with `"verdict" : "fail"`. `evidence-check-final.json` has
  `{'id': 'ev-persisted-state-macro-probe', 'status': 'refuted'}`. The doc's Decision cites only
  supported claims: `- Choose Option 1 [ev-shared-appstorage-probe].` The refuted id appears
  nowhere in the doc. As a control, putting it in Decision made `design-lint` RED:

  ```
  design-lint.citation-not-supported: Decision cites "ev-persisted-state-macro-probe", which is refuted, not supported.
  ```

- **The report holds the absence grep from before the run: PASS.** It's the section above, committed
  before run 1.

### Harness defects

| Defect | Status |
|---|---|
| The design skill had no way to ask in headless mode, and the main session checked a named API itself | fixed in the skill: headless asks, and "a premise is a claim" |
| Headless asks put 5 questions in 1 prompt, over the cap of 4 | fixed in the skill; a rerun asked 4 |
| `context-pack --role research-lane` read every pin as `<pkg>@<version>`, so the codebase (commit) and apple-docs (SDK) pins exited 2; each lane's pack overwrote `research-lane.md` | fixed test-first |
| `docs-lint` passed no claims to reference integrity, so every `ev-` tag in a design was `dangling-id` | fixed test-first |
| `design-lint.unverified-uncovered` can't match `… [UNVERIFIED].`, because the stripped text keeps a space before the period | open |
| the bootstrap `.gitignore` template doesn't ignore `.harness/design-render/` | open |
| `docs-lint` reported neither `unreachable-doc` nor `requirement-uncited` on the new doc | open, not traced |

The claim checker refuted the 6 frame claims worded "The user …", because an orchestrator gave
those answers. The session re-recorded them as orchestrator claims.

### Needs the attended run

Publish, approval and merge need `Artifact`, `ArtifactData` and `AskUserQuestion`, and headless
has none of them. Also untested: the 4-lane `standard` path, the reviewers, and the Workflow tool
with a `scriptPath` outside the working directory, which it refused (the session used the plugin's
workflow skill instead).
