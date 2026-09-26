# Routing fix for `tdd` and `test-gate`, 2026-09-26

The first round ([`2026-09-26-routing-foundation`](../2026-09-26-routing-foundation/summary.md))
found `tdd` recall at 0.67 on held-out requests to fix a failing or flaky test. It also found
`test-gate` missing "are these tests fake" in the tuning set. This round tests the description fix
on branch `fix-tdd-test-gate-routing` (commit `c5522b6`). That branch changes only the 2
`description` lines.

**Result: `tdd` meets the bar on every held-out set, at 1.00 precision and 1.00 recall.
`test-gate` holds 1.00 precision everywhere. Its recall is 1.00 on the round-1 held-out set but
0.88 on the independent round-2 set, under the 0.9 bar.** It misses requests that ask only
to judge the tests ("just point them out"). No skill lost ground, and nothing loaded where it
shouldn't.

## Pins

| Pin | Value |
|---|---|
| Agent model | `claude-opus-5-5`, pinned with `--model` |
| Judge model | `claude-haiku-4-5-20251001`, pinned; routing has no `llm` graders |
| `claude --version` | 2.1.282 |
| Harness | `main` `7052d8d` with the 2 description lines from `c5522b6`, applied on a scratch branch |
| Xcode | 26.2 (17C48), Swift 6.2.3 |
| Settings | `--runs 3 --ablation none --scaffold`, `max_turns: 1`, tools `Read, Glob, Grep, Skill` |

## Method

1. **New tuning cases, run red first.** 9 round-2 requests in the `split-60` set, with 2
   paraphrases each, cover the shapes round 1 found: fixing a red, flaky or snapshot test, and
   judging whether tests are real. On the old descriptions, `tdd` recall was 0.40 and `test-gate`
   recall was 0.33, both at precision 1.00.
2. **A held-out set the tuner didn't write.** Before the fix, an independent agent wrote 16
   requests for `tdd` and `test-gate`, 32 cases in all. It worked only from the skill descriptions
   and the app. I moved them into the seed without reading them. The agent dropped 3 candidates
   and reworded a fourth as ambiguous.
3. **1 description change, tuned on the 60 only.** Each description now names the intents it
   missed and names the neighbouring skill that owns the requests around it.
4. **Verdict on 2 held-out sets:** all 48 round-1 held-out cases, and the 32 round-2 cases.

A slip during step 3: a `--tag round-2` run also matched the round-2 held-out cases, and 16 of them
ran on the final descriptions. I kept those trials, since the descriptions never changed after
that run, and I decided to keep them before reading any result. The other 16 ran in the verdict
batch.

## Results

| Set | `tdd` precision | `tdd` recall | `test-gate` precision | `test-gate` recall | pass^3 |
|---|---|---|---|---|---|
| Round-2 tuning, old descriptions | 1.00 | 0.40 (12 of 30) | 1.00 | 0.33 (6 of 18) | 7 of 18 |
| Round-2 tuning, new descriptions | 1.00 | 1.00 (40 of 40) | 1.00 | 1.00 (28 of 28) | 64 of 66 |
| **Round-1 held-out, new** | **1.00** | **1.00** (24 of 24) | **1.00** | **1.00** (18 of 18) | **48 of 48** |
| **Round-2 held-out, new** | **1.00** | **1.00** (30 of 30) | **1.00** | **0.88** (21 of 24) | **28 of 32** |

The same round-1 held-out set scored `tdd` recall 0.67 on the old descriptions and 1.00 on the new
ones. In round 1, every other skill held 1.00/1.00 on both. The tuning row after the fix mixes 3-trial
round-2 cases with 1-trial round-1 cases for `tdd`, `test-gate`, `validate` and `review`. Its 2
failures were 1 trial each of `review` and `design`, outside this fix.

### Round-2 held-out failures

| Case | Expected | Trials passed | First move | Cause |
|---|---|---|---|---|
| `claude-written-tests-padding-sweep-b` | `test-gate` | 1 of 3 | Glob the tests | judge-only request ("just point them out"); the agent reads the tests itself |
| `gut-dismiss-would-tests-notice-a` | `test-gate` | 2 of 3 | Grep for the handler | the same shape |
| `approve-reducer-code-not-tests-a`, `-b` | `review` | 0 of 3 each | read the reducer | `review` recall on "would you approve this"; `test-gate` stayed quiet as it should |

The 3 `test-gate` misses share a cause. The user asks only for a judgment of the tests, with no
mention of a gate, a PR or readiness. That is the skill's step 3, and the new description names it,
but the agent still reads the tests itself 3 times in 12. None of the round-2 tuning requests has
this "judge only, run nothing" shape, and I have now read the held-out prompts, so tuning it
needs a round 3: new tuning requests, and a fresh held-out set that someone else writes.

## Checks on the evals

| Check | Result |
|---|---|
| Graders tell good from bad | Round 1 proved the routing graders. Round 2 adds the `test-gate` session graders: the judge rubric passed a good transcript 3 of 3 and failed 4 bad ones 0 of 3. The T0 regex failed the BLOCKED run where the agent made up a GREEN |
| Cases fail for real reasons | **Pass.** On the old descriptions, every new tuning case that failed loaded nothing. On the new descriptions it passes |
| Evals catch a broken harness (recall) | Round 1 proved it: a blank `tdd` description took recall from 1.00 to 0.00 |
| Evals catch a broken harness (precision) | **Caught, but the break had to be strong.** Appending "Use it for every request that mentions a test… or a PR" to either description changed nothing: 0 wrong loads in 16 near-miss trials. Rewriting the `tdd` description to claim its neighbours' jobs caused 6 wrong loads in 8 trials. `tdd` precision fell from 1.00 to 0.00 and `validate` recall from 1.00 to 0.00 |
| Results hold still | 2 flaky round-2 held-out cases, both with the `test-gate` judge-only shape |
| Coverage | The independent held-out set found a shape that neither the round-1 nor the round-2 tuning set covers. Writing held-out sets independently is paying off |

## Cost

| Step | USD |
|---|---|
| Red-first baseline, 18 cases × 3 | 2.93 |
| Tuning on the new descriptions, including the 16 held-out cases that ran early | 8.83 |
| Held-out verdict, 64 cases × 3 | 10.91 |
| Planted precision breaks, 3 runs of 8 cases | 1.31 |
| `test-gate` session grader proof, synthetic, Haiku | 0.09 |
| **Total** | **24.07** |

## Output quality: the `test-gate` session case

`evals/sessions/skills/test-gate/hollow-test-before-ready` checks what the skill does, beyond
whether it loads. The scaffold branch floors decrement at zero and adds 2 tests. `floorAtZero`
fails when someone reverts the change. `decrementWorks` passes either way under a name that restates
the behavior. The graders require 3 things. A real `check` report must reach the agent. The agent
must name the hollow test with a fix and leave the real test alone. It mustn't call the branch
ready while the hollow test stands. The case hasn't run live yet: it builds Swift and runs the
ready tier, and waits for a quiet machine.

## Verdict

1. **Verdict on the evals: working as designed and giving value.** The red-first baseline, the
   independent held-out set and 2 planted breaks each did their job. The independent set found
   a gap that the tuner's own cases missed. One weakness: a weak precision break went undetected,
   so these near-misses detect only a skill that oversteps by a wide margin.
2. **What the evals say about the harness.** The fix branch takes `tdd` to 1.00/1.00 on both
   held-out sets, up from 0.67 recall, with no regressions. `test-gate` precision is 1.00. Its
   recall is 1.00 on round 1 and 0.88 on the independent round-2 set: judge-only requests still
   miss 1 time in 4.
3. **What to do next:**
   1. Merge `fix-tdd-test-gate-routing`: every held-out number improves or holds.
   2. Round 3 for `test-gate`: tuning requests for judge-only phrasing, a new independent
      held-out set, and a description change. About 6 USD.
   3. The live session runs for output quality, on a quiet machine: the `tdd` rubric proof and
      the `test-gate` hollow-test case, 1 trial per arm. About 7 USD.
   4. `review` recall on "would you approve this": a new finding, for the `review` round.
