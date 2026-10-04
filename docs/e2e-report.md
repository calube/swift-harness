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

## Rehearsal (unattended, 2026-09-26): SampleApp standard design

A rehearsal, not the attended acceptance run. The user was away and approved running it unattended.
The orchestrator answered every question, and the session recorded each answer as
"orchestrator-answered rehearsal", never as the user's. Nobody approved the design, and nobody
published, merged or pushed anything.

Setup: a scratch copy of `examples/SampleApp` (`git init`, local bare `origin`), bootstrapped with
`HOME` pointed at a scratch directory. A git-ignored `lefthook-local.yml` pointed the git hooks at
that scratch shim. One `claude -p` session (Claude Code 2.1.282, opus main session) ran
`/swift-harness:design CounterFeature history that survives relaunch` with `--plugin-dir`,
`--setting-sources project,local`, `--permission-mode acceptEdits` and an `--allowedTools` list,
never bypass. Each question ended a turn, and each answer came back through `--resume`.

| Test | Result |
|---|---|
| Standard design approved through the Artifact | Needs the attended run: see the headless Artifact finding below |
| Design PR merged | Needs the attended run |
| Ledger passes `plan-lint` | Needs the attended run: `/swift-harness:plan` needs an approval; `plan-lint` on the claimed plan is BLOCKED (no designSha yet) |
| `swiftgate self-test` | GREEN, 20.6 s |
| `swiftgate calibrate design` | RED once, then GREEN twice (23 cases, 11 agents, about 147 s): see the flake below |
| §11 estimates against measurements | Below |

Run, in order:

1. Frame: 6 questions (3 frame prompts in all). The first `design-scope` said `quick`; the
   orchestrator overrode it to `standard`.
2. Standard design: 4 lanes and 64 claims. Review round 1 came back `rethink`. The standards
   reviewer found file IO in CounterCore (D2/D3), a conflict the orchestrator's own frame answer
   ("no new modules") created, and the verifier confirmed it. It also had 1 major and 3 minor
   findings: an unversioned file, the debounce cost, a flaky relaunch test and a missing
   `[[flows]]` entry.
3. Reframe with a `CounterHistoryClient` pair: `design-scope` said `deep`. 4 lanes, 124 claims (85
   supported) and 1 failed probe. Review rounds found 10, then 3, then 1 major finding, and 1
   extra round the orchestrator allowed still ended `revise` (a load retry with no trigger). It
   stopped there without dismissing anything, so publish never ran.

`design-render` on the draft (run by the worker as evidence, not publish) was GREEN at designSha
`7cb04856`; the page stays in the worker's scratch folder.

Harness defects fixed test-first:

- The stamped `AGENTS.md` and `docs/index.md` failed prose, and `.swiftgate.toml` left them out of
  `managed_files`, so a new repository's first push was RED.
- A markdown section's own body ran to its next sibling heading, so `design-lint` counted a
  design about twice. All 59 design fixtures lint the same before and after, and `calibrate
  design` stayed GREEN. `docs-lint` shares the count, so this repository's file budgets now sit
  on the corrected counts, and the 400/800 router and topic defaults allow about twice as much.
- Claim packs rejected probe citations; a probe now brings its snippet and verdict. A quote
  holding `"` now matches `answers.jsonl`.
- The stamped `.gitignore` missed `.harness/design-render/`.
- A headless resume now names `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`: without it `claude -p`
  ended the deep research workflow after 600 s and still reported success.

Findings, open:

- A `claude -p` session has no `Artifact` tool, with an API key or the claude.ai login, so
  publish and Approve need an interactive session.
- No command changes a claimed plan's tier. `plan.json` kept `quick` through standard and deep,
  and `resume` stayed `framing`.
- The prior-decisions lane once returned a claim with an empty `citation.pin`; a rerun fixed it.
- `context-pack` infers the pin kind from its shape: a short commit SHA reads as an SDK pin, and
  nothing checks `--key` against the lane names.
- The review workflow's `previous` input (about 41 KB) is too big for headless tool input, so the
  session edited a copy of the workflow script. The first design's rethink took `review-1/`, and
  the reframe began at `review-2/`; `review-synth` and `stats` don't read round numbers.
- The claim checker's pack ignores `--key`. `evidence check` has no checkouts-path option, so the
  session symlinked `.build/checkouts`. It accepts L1-L24 on a 23-line file, which `context-pack`
  rejects.
- A bare option label in `answers.jsonl` can't support a claim about what the option meant.
  `prose` flags an adverb inside a claim id.
- `prove` restores only Swift production source, so a test that guards a template can't be
  proven. The 2 template tests here failed before their fixes, but the ready gate reports them
  `prove.not-proven`.
- `calibrate design` flakes on `uikit-in-core-module`: it answered D2 instead of A2 at p=0.55.
- The design skill once put 6 questions in 1 prompt; the other worker's change caps it at 4.
- The worker killed a resume seconds after launch to lower its cap, so its message may repeat in
  the transcript. It also sent a labelled operator note to relaunch the killed workflow.

§11 against measured: agents logged 2.0M tokens in `phases.jsonl` for 2 designs (a standard design
to `rethink`, then a deep design through 5 review rounds), against 0.6–1M per standard design. Wall
time was 78 minutes over 10 turns, about 30 of them for the standard design, against a p99 of
10–15 minutes. Research lanes (26 minutes) and redrafts dominated; no probe build was cold. Cost:
$28.35 for the session and 3 `calibrate design` runs.

For the attended run: use an interactive session so publish has the `Artifact` tool. Answer the frame
with a client module up front, since D2 forces one for persistence. Expect `plan.json`'s tier to
stay at the first claim.

## Sprint rehearsals (unattended, 2026-09-28)

At the user's request, each run was a headless `claude -p "/swift-harness:sprint <spec file>"`
(opus, `bypassPermissions`) in a warm copy of the same starter app. The orchestrator answered
questions through `--resume`.

| Run | Prompt shape | Warm start |
|---|---|---|
| A | a form with field validation and on-device persistence | `b324260` |
| B | a multi-state approval workflow with undo and history | `5f801db` |

### Attempt 1: harness `7b0fa5a`, neither run passed

| Step | A (5 slices) | B (4 slices) |
|---|---|---|
| Wall time | 56 min 9 s (12:19:30Z to 13:15:39Z), then a 4-min resume | 49 min 32 s (13:16:23Z to 14:05:55Z) |
| Preflight | 35 s | 28 s |
| Spec page | 2 min 7 s; confirm asked (5 slices for 4 acceptance lines), answered "Build this page." | 1 min 12 s; confirm skipped; `guard.plan-state` denied the page write: question 1 |
| Start | 10 s | 3 s |
| Surface | 2 min 36 s; `surface-check` RED twice | 32 s; GREEN first time |
| Slice 1 | 17 min 55 s; fast T1 runs of 417 s and 499 s | 2 min 48 s; push RED `coverage.diff`: question 2 |
| Later slices | 35 s, 40 s, 19 min 16 s (17 min a stalled model response Claude Code resumed), 23 s | 12 s, 22 s, 18 s |
| Ready | 10 min 50 s, 2 runs | 14 min 47 s BLOCKED; a background re-run killed when the headless turn ended; 24 min 23 s GREEN in the foreground |
| Finish | refused `sprint.gate-blocked` | 22 s; `main` fast-forwarded to `7f1a4e6` |
| Resume | `ready` RED in 171 s; stopped as told | none |

B moved `main`, but 2 extra questions, a `SWIFT_HARNESS_ORCHESTRATOR=1` override and an
orchestrator-requested re-run fail the pass criteria. Branches: `attempt-1/edit-your-profile`,
`attempt-1/document-approval-with-undo`.

| Run | Gate | Verdict | Gating rule | Fix the session made |
|---|---|---|---|---|
| A `20260928T122319Z-18538cdd` | `surface-check` | RED | 3 `surface-check.behaviour`: the `AppFeature` manifest and the new client's `DependencyValues` accessor | accessor stubbed `get { .init() }` / `set {}` |
| A `20260928T122336Z-6370b447` | `surface-check` | RED | `surface-check.behaviour` on `Package.swift` | a same-line allow (ignored), then the feature moved to a new package |
| A `20260928T123342Z-313772c4` | push | RED | `impact.untested-change` | client tests pulled into slice 1 |
| A `20260928T124229Z-0e8b1067` | push | RED | `coverage.diff` on surface stubs | an extra assertion |
| A `20260928T130308Z-ab15ea4f` | push | RED | `impact.untested-change` | a root-store wiring test |
| A `20260928T130410Z-20e79d20` | ready | RED | 2 `mutate.survived`; T3 BLOCKED: `simctl clone` of a booted device (SimError 405) | a boundary test |
| A `20260928T130947Z-2758ea91` | ready | BLOCKED | T1 `prove.no-evidence`: new targets empty at `main`; T3 as above | none; `finish` refused |
| A `20260928T164206Z-298fd7a6` | ready | RED | 11 `prove.compile-only`: slice 4 added `ProfileClientLive`, a target the surface lacks | none |
| B `20260928T131912Z-cc90d5bd` | push | RED | `coverage.diff`, 34 of 53 lines | slice 2's code and test moved into slice 1 |
| B `20260928T132227Z-1590fe9a` | ready | BLOCKED | T3 `t3.no-evidence`: `simctl` timed out at 60 s | re-run |
| B `20260928T133858Z-ab18ab21` | ready | **GREEN** | | T3 took 1014 s |

| Defect | Hit by | Fixed by |
|---|---|---|
| prove stopped at the merge base when a new package's targets were empty there | A | `prove-retries-emptied-targets-at-proof-base` |
| `guard.plan-state` read `sprints/` as a plan | B | `plan-state-guard-allows-sprint-pages` |
| slice push gates measured coverage from `main`, counting surface stubs | A, B | `slice-gates-measure-from-the-surface` |
| T3 cloned a booted device; `simctl` had a fixed 60 s deadline | A, B | `t3-never-clones-a-booted-base` |
| `surface-check` judged an added manifest dependency as behaviour | A | `surface-check-allows-additive-manifest-edits` |
| the skill lacked the accessor stub, the no-allow rule for surface findings, and a foreground `ready` | A, B | `sprint-skill-rehearsal-lessons` |
| a slice could add a target the surface lacks | A | `sprint-slice-refuses-targets-the-surface-lacks` |

### Attempt 2: harness `7b6d49f`, both runs passed

Both repositories restarted from their warm starts. Neither session asked a question or hit a
`sprint` refusal. A shared the machine with a mutation-testing worker (load peaks of 300 to 460
during T3's first boot of a created device), so its times are pessimistic.

| Step | A (4 slices) | B (4 slices) |
|---|---|---|
| Wall time | **31 min 45 s** (18:30:52Z to 19:02:37Z), $2.75 | **12 min 28 s** (19:02:50Z to 19:15:18Z), $1.02 |
| Preflight | 35 s | 31 s |
| Spec page | 1 min 32 s; no confirm | 26 s; no confirm |
| Start | 3 s | 3 s |
| Surface | 51 s; GREEN first time, with the manifest edit | 26 s |
| Slices | 1 min 46 s, 48 s, 1 min 21 s, 47 s | 51 s, 40 s, 32 s, 39 s |
| Ready | 23 min 26 s, 5 runs | 7 min 46 s, 2 runs |
| Finish | 14 s; `main` fast-forwarded to `219f1c3` | 20 s; `main` fast-forwarded to `65de1d9` |

| Run | Gate | Verdict | Gating rule | Fix the session made |
|---|---|---|---|---|
| A `20260928T183427Z-ed4ee847` | push, slice 1 | RED | `coverage.diff`, 2 `coverage.no-t1-tests` | the new client's tests moved into slice 1 |
| A `20260928T183847Z-143bb5c2` | ready, 242 s | RED | 2 `mutate.survived` | a scope test and a boundary test |
| A `20260928T184308Z-45e3a0dc` | ready, 228 s | BLOCKED | T1 `prove.no-evidence`: no `Package.resolved` in the new package | `swift package resolve`, lockfile committed |
| A `20260928T184745Z-8193c90c` | ready, 226 s | RED | 2 `prove.compile-only`: an API renamed after the surface | stub commit as a 2nd `--proof-base`, then a restore commit |
| A `20260928T185421Z-326fe548` | ready, 169 s | RED | `prove.not-proven`: the stub left the accessor real | a 2nd stub-and-restore pair |
| A `20260928T185738Z-8c24e119` | ready, 272 s | **GREEN** | | |
| B `20260928T190708Z-a5cdfd07` | ready, 245 s | RED | `mutate.survived`: the child `Scope` removed | a root-store test |
| B `20260928T191126Z-721744fe` | ready, 208 s | **GREEN** | | |

Other fast-tier REDs were the inner loop at work. No attempt-2 fast T1 run took over 7 s.

### Open findings from the rehearsals

| Finding | Evidence |
|---|---|
| Fast-tier runs of 7 to 8 minutes, unexplained | A attempt 1, `20260928T122638Z-c69b63e7` (417 s) and `20260928T123402Z-e8b94f8d` (499 s): SwiftPM builds of 4.75 s and 18.5 s. The next one needs a timed trace |
| A new package with no `Package.resolved` BLOCKS `ready` | A attempt 2: the working tree resolves on its own, but prove's scratch copy resolves with automatic resolution off (`a resolved file is required`) |
| A surface API renamed mid-sprint needs a stub-then-restore commit pair to prove | A attempt 2: 4 extra commits and 2 extra `ready` runs; the first pair stubbed too little |
| The created-device path boots a fresh simulator on every T3 run | with the pinned device booted, each T3 run creates, boots and deletes its own device (41 to 97 s in attempt 2) |
| `sprint.target-outside-surface` can only halt | its fix rewrites the surface, but `sprint.json` accepts `surface` only straight after `start` |

## Simulator QA (unattended, 2026-10-04)

Harness `main` at `91fa9876` for every check, merged to `b6bb74fe` for the run viewer. `agent-device`
0.21.18, Xcode 26.2, each device a clone `sim up` made from the configured iPhone 17 (iOS 26.2). The
`sim` lock is machine-wide and its cap is 2 (the default). Other sessions queued on the same
lock during the isolation check.

The skill steps ran from `examples/SampleApp` in this checkout. The isolation check used a scratch
copy of the app with 2 extra git worktrees. The validation table and the planted bug used a second
scratch copy with its own plan state, so the trial touched no plan state in this repository.

### Acceptance checks

| Check | Result | Evidence |
|---|---|---|
| `doctor` is GREEN | pass | `20261004T220526Z-a0f1c534`, 0 gating findings |
| `/swift-harness:qa`, counter flow, `fixed-fact` | pass | `qa run`: no plan holds a table. `sim up --scenario fixed-fact` `20261004T220545Z-f6f397eb`. 3 steps asserted `0`, `1` and the fixed fact |
| `sim verify` GREEN | pass | GREEN, `stepCount` 3, `headCommit` equals the checkout's HEAD |
| `sim down` leaves nothing | pass | `released: true`; no clone, lease or `agent-device` session left |
| Seeded branch RED on both accessibility rules | pass | the seeded diff from the fixtures README, uncommitted, then reverted. Run `20261004T220837Z-7b3464d9`: RED, `sim.a11y-identifier` (Button "Share") and `sim.a11y-label` (Button `counter.dot`) |
| 3 `sim up` from 3 worktrees, cap 2: the third queues | pass | a and b started 17:09:49 and leased by 17:12:02. c started 17:10:10, and both slot files named a's and b's holders. a's `sim down` ended 17:12:27; c leased, built and returned 17:13:44 |
| SIGKILL the holder, then `gc` leaves no device and no claim | **fail** | `gc` deleted the clone (`1 orphan clone(s)`). The lease file, the `agent-device` session and its device claim survived. A later `sim down` cleared all 3 (finding 1) |
| Validation table: `--at-base` fails each row, `qa run` passes, `--final` leaves MP4 and contact sheet | pass, with gaps | below; findings 3 and 4 |
| T3 leaves the kept flow's `qa.flow` with `source: xcuitest` | pass | `test --tier t3` `20261004T222634Z-f39ef58c`, GREEN 2/2; 2 `qa.flow` events, `flow: counter`, `source: xcuitest`, each with video and sheet |
| Validation tab links each flow step to its video offset | pass | 7 of 7 steps link `video.mp4#t=<s>` in all 3 reports; the page has 0 `img` or `video` elements |

### The validation table

The scratch app's `main` is SampleApp as committed. Its `feature` branch adds a Reset button
(`counter.reset`) and a `resetButtonTapped` action. It also logs `count changed count=<n>` at
`notice` level through `LogClient` on each count change, and adds the unit test
`resetAfterIncrementsShowsZero`. The plan has 1 done task and 3 rows for 1 requirement:

- acceptance: `swift test --filter resetAfterIncrementsShowsZero`, and its output must say a test ran;
- flow: `qa/reset.flow.json`, which waits, then increments, checks `1`, increments, checks `2`, resets and checks `0`;
- state: `qa/reset.state.sh`. It takes the last 3 `count changed` lines from the final pass's
  `qa/logs/<NN>-<req>/os.log` when one exists, or from `log show` on `QA_SIM_UDID`, and requires `1 2 0`.

| Command | Run | Wall | Result |
|---|---|---|---|
| `qa run --at-base` | `20261004T222122Z-9b62b184` | 47 s | acceptance red (no test ran at base); flow red, `qa.flow-unknown-id` for `counter.reset`; state unverified (no device) |
| `qa run` | `20261004T222215Z-2384733a` | 126 s | 3 of 3 pass; state read `log show` |
| `qa run --final` | `20261004T222435Z-513ddd35` | 93 s | 3 of 3 pass; `video.mp4`, `sheet.png`, 7 steps with offsets; logs saved; state read the collected `os.log` |

### Planted bug: an internal value the screen never shows

The bug was an uncommitted diff in the scratch copy only, reverted with `git checkout -- Packages`
after each run. It logs the count before the increment, so every increment logs the old value
while the screen shows the new one:

```diff
       case .incrementButtonTapped:
+        log.log(.notice, "count changed", category: "Counter", [.public("count", state.count)])
         state.count += 1
         state.fact = nil
-        log.log(.notice, "count changed", category: "Counter", [.public("count", state.count)])
         return .none
```

For b2, the same diff went into a second copy's `feature` commit, and the state row came out.
`/swift-harness:qa` then ran in a fresh `claude -p --plugin-dir plugin --model opus` session with the
prompt "QA the counter reset change on this branch, and record the evidence (video and logs) so I
can look at it later". The prompt didn't hint at logs.

| Run | Flow row | State row | qa skill verdict | Evidence that showed the bug |
|---|---|---|---|---|
| clean (`20261004T225912Z-99e4740e`) | pass | pass, `1 2 0` | GREEN | none: `os.log` and `app.log` read `count=1`, `count=2`, `count=0` |
| b1, targeted (`20261004T230400Z-ae9e9c11`) | pass | **red**, exit 1 | RED (`qa run` RED, 2 pass, 1 red) | the state row's stderr quotes the 3 `os.log` lines `count changed count=0`, `count=1`, `count=0`; the viewer's "Why it failed" shows them |
| b2, untargeted (session run `20261004T225356Z-6c855437`) | pass | no row | **GREEN**, plus a prose warning | the skill read the branch diff, saw the log call before `+= 1`, then confirmed it in the collected `app.log` (`count=0`, `count=1`, `count=0`). It reported "No check looks at log contents, so the verdict is still GREEN" and offered `/swift-harness:tdd` |

The acceptance unit test passed in every run, because it checks state, not the log.

### Run viewer

Each copy got a build run from `build start` with a 1-task preset before the viewer runs, since the
viewer reads only `qa run`s inside a build run. Then `qa run --final` ran again and
`swiftgate report --html` wrote the page to its default `reports/` folder. Each page went next to
its run's `video.mp4` and `sheet.png`, at the same relative paths, so every link resolves (0 missing).

| Report | Strip | Contrast |
|---|---|---|
| clean | 3 pass | every row green; 7 steps linked to `#t=0` … `#t=7.586` |
| b1 | 2 pass, 1 red | the flow row is green with 7 linked steps; the state row is red, and its "Why it failed" quotes the 3 offending log lines |
| b2 | 2 pass | no row can show the bug; the page looks the same as clean |

The b1 timeline also carries the clean run's flow ticks, since both ran in 1 build run. The rows
show the newest result.

### Findings, ranked

1. **`gc` doesn't free what a killed holder leaves.** After SIGKILL of `sim hold` (PID 96953), `gc`
   deleted the clone but left `sim-leases/<run>.json`, the `agent-device` session and its device
   claim. The claim's owner is the `agent-device` daemon, which is alive, so `device release --stale`
   skips it. A plain `sim down` from that worktree cleaned all 3 up.
2. **A log-only bug passes validation unless a row targets it.** In b2, every row passed and the
   skill's verdict was GREEN. It spotted the bug by reading the diff, not from the evidence on its
   own, and by its rule ("`swiftgate` is the judge") it can't turn a log mismatch into RED. With a
   state row reading the collected `os.log` (b1), the run went RED and named the line.
3. **`--at-base` passes an acceptance test that exists only on the branch.** The plain
   `swift test --filter resetAfterIncrementsShowsZero` row read `pass` at base, with
   `No matching test cases were run` and exit 0, and no note (`20261004T221707Z-0078b8c8`). It took a
   check that also requires a test to have run to get a red run at base.
4. **At base, a state row behind a lint-red flow never gets a red run.** The new id doesn't exist at
   base, so the flow stops at `qa.flow-unknown-id` and no device comes up. The state row reads
   unverified, not red.
5. **A cold shim build ends a `claude -p` QA session with no verdict.** In b2's first attempt, the
   skill's first `qa run` waited behind the shim's 190 s release build. Bash moved it to the
   background at 120 s, the turn ended, and `-p` killed it 150 s in. The second attempt, on a warm
   cache, ran to the end (495 s, $0.36).
6. A red row's report `message` is only `exit 1`. The reason is in the row's `.txt` evidence,
   which the viewer's popover shows.
7. A plain `qa run` needs the ledger's `waves` key (BLOCKED without it), but `--at-base` doesn't
   read the ledger, so the same plan passes `--at-base` and BLOCKS plain.
8. From b2: `sim snap --assert` can only check that text is present, never that it's gone. A
   negative value such as `--assert "-2"` parses as a flag and needs `--assert=-2`.
9. `sim verify` can't tell a build from uncommitted changes. The seeded run reported
   `headCommit` = `checkoutHead`.

### Decisions

Keep-flow answer: the session proposed no flow. The repo already keeps the counter journey as `[[flows]] counter`
(2 XCUITests). b2's skill session proposed none either, saying Reset stays inside 1 feature and a
unit test covers it.

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
