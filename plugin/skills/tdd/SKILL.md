---
name: tdd
description: This skill should be used for test-first work on Swift code in a swift-harness app — name the regression, write a Swift Testing test, watch it fail on an assertion with swiftgate, implement, go green, then prove it. Load it before reading code whenever the user wants a feature, bug fix or behavior change in Swift code, wants a test written, or has a test that is failing, red, broken or flaky and must pass again or be made reliable, including a snapshot test: "add a test for", "TDD this", "write the reducer", "fix this bug", "this test fails, get it passing", "make it green", "this test is flaky", "fix the snapshot test". Also use it when swiftgate reports test.* testlint findings, impact.untested-change, or low diff coverage. Not for judging whether a change's existing tests are real before a PR (use test-gate), or for only finding or explaining tests.
---

# TDD

Every behavior starts as a failing test. Rules cited as `P1`–`P11` live in the plugin's
`docs/testing-playbook.md` (§ 7 has a worked example per pattern); `D1`, `G1` in
`docs/standards.md`.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Read `--json` reports for `verdict` and `findings[]`
only; logs stay in `.harness/runs/<run-id>/`.

## 1. Name the regression (P1)

Write the name before the body: `@Test("<behavior> — catches <regression>")`. The regression is a
symptom a user or caller would see ("catches the total ignoring discounts"), never the behavior
restated ("catches increment not incrementing") or "catches bugs". If you can't name one, the test
isn't needed.

## 2. Pick the tier and the pattern

Lowest tier that can see the behavior. If only the simulator can see it, the logic is in the wrong
module: move it to Core or a client and test it at T1.

| Code under test | Tier | Pattern (playbook § 7) |
|---|---|---|
| TCA reducer | T1 | Exhaustive `TestStore`: assert every state change in `send`/`receive` closures (`P5`). Override only the dependency endpoints the behavior uses |
| Anything advancing a `TestClock` | T1 | Suite `@Suite(.serialized, .timeLimit(.minutes(1)))`, body in `withMainSerialExecutor { … }` (`P6`) |
| `FooClientLive` | T1 | Drive it through the interface of the transport it depends on (`HTTPClient` under `APIClientLive`), with `TestClock` for retries |
| Engine | T1 | Replay: seed + input log → identical final state (`P10`, `G1`); properties over seeded random inputs |
| View rendering | T2 | Snapshot with recording off (`P4`); record only via `"$SG" snapshots record` |
| End-to-end flow | T3 | XCUITest named after a `[[flows]]` entry (`P11`); rare |

Never in a test: `Task.sleep`/`usleep`, `try?` or an empty `catch`, `Date()`/`UUID()`/`.random`
read directly (`P7`, `D1`), asserting only what the test configured on its own double, `!= nil` as
the only assertion.

## 3. Red

1. Write the test and only the declarations it needs to compile (a stub that returns the wrong
   thing), so it fails on an **assertion**, not a compile error (`P2`).
2. Run `"$SG" test --tier t1 --affected-since HEAD --json` (T2: `--tier t2`).
3. Expect `verdict` `RED` with a finding on your test's line and assertion. RED for any other
   reason (build error, a different test) is not your red: fix that first. GREEN means the test
   can't catch the regression: rewrite it.

## 4. Green

1. Write the least code that passes. Nondeterminism goes through `@Dependency` (`D1`).
2. Re-run the same command until `GREEN`, then `"$SG" check --tier fast --json` (T0 lint,
   testlint, format, affected T1). Fix every gating finding; waive only with
   `// swiftgate:allow <rule-id> — <reason>` on the same line when the rule is truly wrong here.

## 5. Prove

Before calling the change done, run `"$SG" prove --json`: in a scratch worktree it restores
production source to the merge base with `origin/main` (`--base` to change) and requires each new
or changed **host** test to fail on an assertion; compile-only failures count as not proven. T2
snapshot tests aren't covered: check their red by hand in step 3. A test it reports
as passing without the change is a test that catches nothing; fix the test, not the gate.

Two shapes `prove` rejects even though the test is useful:

- **A boundary test on its own.** A test that pins unchanged behavior at a boundary (a 120-character
  fact is kept) passes with the change reverted, but `mutate` needs it to kill `>` → `>=`. Put it
  in the same test as an assertion that fails on the revert (a 121-character fact is cut), so both
  sides of the boundary are one proven test.
- **An assertion that calls API the change adds.** The reverted tree doesn't compile, so `prove`
  reports `prove.compile-only`. Assert with literals (`120`, `"Too long"`), not the new constant or
  helper, so the test compiles against both trees.

For more
confidence on concurrency-heavy tests, `"$SG" stress --json` runs new and changed host tests 10 times (`--n`), each as a separate
parallel process so order varies (`P8`).

## 6. Refactor

With the test green, clean up. Re-run step 4's commands after every change, and `prove` again
before handoff.

When the change is ready for review, hand off to `/swift-harness:test-gate`.
