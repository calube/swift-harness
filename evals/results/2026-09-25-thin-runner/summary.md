# Thin runner, 2026-09-25

`evals/runner/session.mjs` runs cases that build or test Swift through `claude -p`, outside the
`claude plugin eval` sandbox. It ran the `tdd` case in both arms. **Result: the runner works.
The agent's own `swiftgate` runs return real verdicts, the hooks record, and a planted break in
the `tdd` skill dropped the score from 1.00 to 0.25.**

## Pins

| Pin | Value |
|---|---|
| Agent model | `claude-opus-5-5` (session default, not pinned by flag) |
| Judge model | `haiku` |
| `claude --version` | 2.1.282 |
| Harness commit | `d652a83` for runs 1 and 2; the planted break ran on a scratch branch off `efbf167` |
| Xcode | 26.2, Swift 6.2.3 |

## Runs

| Run | Arm | Score | Graders passed | Cost (USD) | Wall |
|---|---|---|---|---|---|
| 1 | with | 1.00 | hidden test, judge, `swiftgate` RED seen, test before reducer | 0.18 + 0.03 judge | 210 s |
| 2 | without | 0.50 | hidden test, test before reducer | 0.15 + 0.04 judge | 208 s |
| 3 | with, `tdd` skill body replaced by "make the change directly" | 0.25 | hidden test only | 0.14 incl. judge | 150 s |

Total about 0.60 USD, plus 0.05 USD of auth and flag probes. The runner kept transcripts, hook
records and diffs in the session's scratch directory, outside git.

## What the runs show

- **The agent's Bash reaches the toolchain.** Run 1 called `swiftgate test`, saw RED on its new
  test, fixed the reducer, saw GREEN, then ran `prove`. Under `claude plugin eval` the same calls
  came back BLOCKED.
- **Hooks record.** Run 1 left 9 hook payloads and outcomes (SessionStart, PreToolUse,
  PostToolUse, Stop) through the gate's existing `SWIFTGATE_HOOK_RECORD_DIR`. `design.md` says
  `guard-conformance` needs a new gate log, but this recorder already covers it.
- **Isolation holds.** The without arm loaded no plugin: its `Skill` call returned "Unknown skill".
- **The case discriminates on process, not on outcome.** Both arms wrote the test first and
  passed the hidden test. Only the `swiftgate` grader (now `with-only`) and the judge's
  swiftgate-specific rubric separate them. This task is too easy to show the skill changes the
  result.
- **Outcome graders alone miss a broken skill.** In run 3 the agent skipped the test and edited
  the reducer, and the hidden test still passed. Only the process graders caught the break.

## Grader checks

| Grader | Known-good | Known-bad | Verdict |
|---|---|---|---|
| `hidden-floor-test` (`command`) | baseline plus the fix: pass, GREEN (74 s) | baseline: fail, RED (69 s) | separates |
| `swiftgate-red-seen` (`regex`) | run 1: pass | run 3, and the spike's all-BLOCKED run: fail | separates |
| `test-before-reducer` (`tool_order`) | run 1: pass | run 3, no test edit: fail | separates |
| `red-then-green` (`llm`) | run 1: 3 PASS votes | run 3: 3 FAIL votes | separates. Its rubric names `swiftgate`, so the without arm can't pass it (see open questions) |

`session_test.mjs` covers the runner's grading with no model calls. While I wrote it, it failed on
2 real bugs: a glob converter that rewrote its own `**`, and a block parser that ended at
the first blank line.

## Open questions for the user

- **The judge rubric names `swiftgate`.** For the with/without comparison, a rubric that asks
  "did a test run show the new test failing on an assertion before the fix" would judge both
  arms on the same discipline. That loosens a grader, so it waits for your approval.
- **The case needs a harder sibling.** A task where a straight edit is tempting and wrong, such as
  a change whose obvious fix breaks an existing test, would show whether the skill changes
  outcomes and not only the process.
