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
api-errors. The review workflow itself has not been run on it yet.

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

## Known gaps, not fixed

- Fixed since: `impact.untested-change` fired on formatting-only source changes (`18f5d81` was RED
  on push). `impact` now skips a file whose tokens match the merge base.
- Fixed since (tdd skill § 5): proving boundary tests: a test that only pins unchanged behavior at a boundary (a fact of exactly
  120 characters is kept) passes with the change reverted, so `prove` rejects it on its own, even
  though `mutate` needs it to kill `>` → `>=`. Asserting both sides of the boundary in one test
  satisfies both checks. A test that calls API the change adds is `prove.compile-only`, so tests
  use literals, not new constants. The `tdd` skill should say both.
- Cold-build T1 (119–166s) is over its 60s budget. The budget finding is a non-gating `minor`.
