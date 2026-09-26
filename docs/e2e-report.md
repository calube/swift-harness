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

## Rehearsal (unattended, 2026-09-26): plugin installs for real

A rehearsal, not the attended acceptance run: the user was away and approved running it
unattended, so nobody answered or approved anything. The attended run repeats it.

A scratch copy of `examples/SampleApp` (`git init`, local bare `origin`), Claude Code 2.1.282,
`--setting-sources project,local`, `--model claude-sonnet-5`. A temporary logging hook in the
copy's `.claude/settings.json` saved each hook's stdin; `SWIFTGATE_HOOK_RECORD_DIR` recorded
swiftgate's outcomes. Install, from the copy, nothing at user scope:

```
claude plugin marketplace add <harness checkout> --scope project
claude plugin install swift-harness@swift-harness --scope project
```

The first SessionStart said enforcement was warming up. `bin/swiftgate --version` with the same
`CLAUDE_PLUGIN_DATA` built it in 2 min 17 s; every later hook ran it.

| Test | Command | Observed |
|---|---|---|
| Plugin agent types run | `claude -p … --output-format json --verbose`, Agent with `subagent_type: "swift-harness:design-lane-codebase"` | `init` listed 17 `swift-harness:*` agents; the agent returned a report. In the worktree session its `Read` fired PreToolUse with `agent_type: "swift-harness:design-lane-codebase"`. |
| Subagent writes denied | same, `--session-id` set to the id given to `swiftgate plan claim counter-reset --session <id>`, `bypassPermissions` | A `general-purpose` subagent's Write to `ledger.json`, the design doc and `<doc>.evidence/claims.jsonl`: each denied, `guard.plan-state`, 2–78 ms. The main session's same three writes succeeded. The subagent payloads carried the lock holder's `session_id`, so `agent_id` alone decided each denial. |
| Two worktrees share plan state | `swiftgate index set counter-reset designing …`, `git worktree add`, `claude -p` in the second | Same `--git-common-dir` and `index.json` md5 from both. The second worktree's SessionStart listed `counter-reset (designing)`, and its session read the main session's `ledger.json`. |

This run saw `agent_id` live (spec §14). A subagent's PreToolUse payload has `session_id`,
`transcript_path`, `cwd`, `prompt_id`, `permission_mode`, `agent_id`, `agent_type`, `effort`,
`hook_event_name`, `tool_name`, `tool_input` and `tool_use_id`; a main-session payload lacks the
2 agent fields. `agent_type` is plugin-qualified for plugin agents.

Findings:

- A `directory` marketplace runs the plugin from the checkout (`init` path and the reference-docs
  line name `<checkout>/plugin`), so checkout edits apply without `claude plugin update`. Install
  still copies `plugin/` into the Claude config's plugin cache, including the untracked
  `gate/.build` (843 MB).
- Project scope still writes the Claude config's `plugins/known_marketplaces.json` and
  `plugins/installed_plugins.json` (entry `scope: project` with its `projectPath`) and an empty
  `plugins/marketplaces/`. Neither file existed before, and the run removed all 3 afterwards. The
  user `settings.json` didn't change. The run left the cache entry and the plugin data dir
  (476 MB, the built gate).
- Defect, fixed: the `status` skill read the retired `.harness/plans/index.json`, listed
  `superseded` plans as active and looked for `-<slug>` directories. It now resolves each
  repository's common dir. `tests/plan_state_paths_test.mjs` fails on a `.harness/plans` or
  `.harness/orchestrator.lock` path in shipped skills, agents or workflows. `plugin/docs/hooks.md`
  had the same stale path.
- Without `origin/main` the first Stop came back BLOCKED and let the session end, as in the
  bootstrap run; with it, Stop stayed silent.

Needs the attended run: the fixed `status` skill end to end. It reads the user's
`projects.json`, and registering the scratch copy would have written to the real home directory.

Cost: 3 sessions, $0.38 (7 s, 44 s, 97 s); about 9 minutes in all with the cold build.
