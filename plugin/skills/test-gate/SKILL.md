---
name: test-gate
description: This skill should be used to judge whether a swift-harness Swift change's tests are real and to run the pre-ready test gate — scope the diff, run swiftgate check --tier push, judge new and changed tests for slop the tools can't see, then run check --tier ready (T3 flows, prove, stress, reach). Use it whenever the user asks whether their tests actually catch anything, would fail if the code were wrong, or are fake, padding or passing trivially; says "check the tests are real", "review my tests", "is this ready", "run the full gate", "gate this branch"; before opening or marking a PR ready or asking for review; or after /swift-harness:tdd finishes a change. Not for writing a test or fixing a failing or flaky one (use tdd), PR evidence text (use validate) or a merge verdict on the code (use review).
---

# Test gate

Sequence: scope → `push` → test-slop judgment → `ready`. Each tool step stops the sequence on RED:
running a slower tier over code that fails a faster one wastes minutes and tokens. Rules cited as
`P1`–`P11` live in the plugin's `docs/testing-playbook.md`.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Pass `--base <ref>` to `impact` and `check` when the
branch does not target `origin/main`. Read only `verdict`, `tiers[]` and `findings[]` from `--json`
output; full logs are in `.harness/runs/<run-id>/`, open them only to explain a specific finding.

## 1. Scope

1. `git diff --stat <base>...HEAD` plus uncommitted changes: which packages and which test files
   changed.
2. `"$SG" impact --json`: every changed Core, Client or Live module needs a test change or an
   exemption with a reason (`P9`). The push tier re-runs impact; fix a RED here to fail fast: write the missing test with
   `/swift-harness:tdd`, or, only when no behavior changed, add the exemption the finding names.

## 2. Push tier

Run `"$SG" check --tier push --json` (T0, every T1 target, affected T2, impact, diff coverage, T1
presence per module).

- `RED`: list each gating finding as `file:line rule — message`, fix the code or the test, re-run.
  Coverage below `diff_coverage_min` means changed lines no T1 test reaches (`§ 4` of the
  playbook): add a T1 test, don't move the logic out of reach.
- `BLOCKED`: the environment (Xcode pin, simulator runtime, disk). Run `"$SG" doctor` and fix what
  it names. Never change code to get past BLOCKED.
- `GREEN`: continue.

## 3. Test-slop judgment

The tools already reject assertion-free, tautological, existence-only, own-double, sleeping,
swallowed-error, duplicate, unnamed and misplaced-T2 tests (`testlint`). Read each new or changed test in the diff and judge what they can't:

| Smell | Ask |
|---|---|
| Vacuous or restated name (`P1`) | Does "catches …" name a symptom a user or caller would see? |
| Implementation coupling | Would a behavior-preserving refactor break it (private call order, internal state, exact log text)? |
| Over-mocking | Does it stub so many collaborators that it exercises the doubles rather than the unit? |
| Wrong tier | Could a T2/T3 test be a T1 test on Core logic? Is a T1 test secretly integration-heavy? |
| Missing edge | Empty input, duplicate calls, failure and cancellation paths, time boundaries: does the change need one it lacks? |

Report findings as `file:line — smell — concrete fix`. Fix the clear ones yourself. When a fix
changes what the test claims to cover, or you're unsure the smell is real, ask the user with
`AskUserQuestion` (batch every such question into one call). Re-run step 2 if tests changed.

## 4. Ready tier

Run `"$SG" check --tier ready --json`. It adds the T3 UI flows (closed list, `P11`), `prove` (each
new or changed host test fails with the source reverted, `P2`), `stress` (10 separate parallel
runs, `P8`) and per-test reach (each test covers its own module).

- `prove.not-proven`: the test passes with the source reverted, so it catches nothing; strengthen
  the assertion. `prove.compile-only` / `prove.crashed`: it must fail on an assertion, so land the
  API it calls in an earlier change. `prove.fails-at-head`: make it green first.
  `prove.no-evidence`: treat as BLOCKED.
- `reach.no-production-lines`: the test runs no code in the module it targets; test the module.
- `stress.failed` / `stress.crashed` is a flake: find the shared state or real time (`P6`, `P7`), never retry.
- `mutate.survived`: a changed line no test pins; add the assertion that kills it (or mark a truly
  equivalent mutant `// swiftgate:equivalent-mutant — <reason>`). `mutate not run: T1 is RED`
  clears once T1 is green.
- `swiftgate.not-run` notes list steps this build can't run yet (such as simulator prove and
  stress); report them as not run, never as passed.

## Report

Three to six lines: the push and ready verdicts with durations, the slop findings fixed or open,
and anything not run. `GREEN` at `ready` with nothing open is the only "ready for review". For the
PR evidence block, hand off to `/swift-harness:validate`.
