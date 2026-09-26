# Routing round 5: `review` and `validate`, 2026-09-26

Rounds 2 and 3 found 2 routing gaps in held-out sets. `review` didn't load for merge or approval
verdicts that set the tests aside, and `validate` missed "summarise the tests for the PR
description". Round 5 tests a description change for both skills. The orchestrator owns
`plugin/`, so the change lives in [`proposed-descriptions.txt`](proposed-descriptions.txt) and ran
only in a staged copy; it goes to the orchestrator as a wave.

**Result: on 44 independent held-out cases the proposed descriptions score `validate` 1.00/1.00
and `review` precision 1.00, recall 0.93 (39 of 42). The 3 misses are 1 prompt that narrows the
review to 1 concern. No skill loaded where it shouldn't.**

## Pins

| Pin | Value |
|---|---|
| Agent model | `claude-opus-5-5`, pinned with `--model` |
| `claude --version` | 2.1.282 |
| Harness | `main` `90e3524`, staged with `evals/runner/stage_plugin.sh`; the 2 proposed descriptions applied in the stage |
| Settings | `--ablation none --scaffold -j 2`, `max_turns: 1`, tools `Read, Glob, Grep, Skill` |

## Method

1. **An independent held-out set first.** Before any change, a separate agent wrote 22 requests
   (44 cases) for `review` and `validate` from the 11 skill descriptions and the app alone. It
   dropped 5 candidates as ambiguous. I didn't read its prompts until the verdict was in.
2. **Tuning cases, run red first.** 9 requests (18 cases) in the shapes rounds 2 and 3 found,
   1 trial on the current descriptions.
3. **1 description change per skill,** tuned on the 18 only. `review` now names the verdict
   intents (approve, sign off, what blocks it, "leave the tests out of it") and its neighbours.
   `validate` adds "summarise the tests for the PR description".
4. **Verdict:** the 44 held-out cases, 3 trials.

## Results

| Set | `review` P | `review` R | `validate` P | `validate` R | pass^k |
|---|---|---|---|---|---|
| Tuning, current descriptions, 1 trial | 1.00 | 0.67 (4 of 6) | 1.00 | 1.00 (4 of 4) | 16 of 18 |
| Tuning, proposed, 3 trials | 1.00 | 1.00 (18 of 18) | 1.00 | 1.00 (12 of 12) | 18 of 18 |
| **Held-out, proposed, 3 trials** | **1.00** | **0.93** (39 of 42) | **1.00** | **1.00** (42 of 42) | **43 of 44** |

On the held-out set, the near-misses whose answer is a neighbour loaded that neighbour every time:
`test-gate` 12 of 12, `tdd` 12 of 12, `comment-audit` 6 of 6, `bootstrap` 6 of 6. The 12 trials
that should load nothing loaded nothing.

Red first, the current `review` description missed the 2 terse sign-off requests: "yes or no, would
you sign off on my branch" and "anything blocking on this diff before it goes in?". The
`validate` shape that failed 0 of 3 in round 3 passed 1 of 1 here, so 1 trial can't say whether the
current `validate` description already handles it.

### The held-out miss

`r5-review-concurrency-tca-a`, 0 of 3: "Before I merge, please go through the code on my branch and
point out any concurrency or TCA misuse in the CounterFeature changes." The agent reads the reducer
itself each time. Its terse paraphrase loaded `review` 3 of 3. The request narrows the review to 1
concern, and it's the `review` twin of the judge-only shape that `test-gate` missed in round 2. A
fix would name "point out the concurrency, TCA or other problems in my change before I merge". Now
that I have read the prompt, testing that fix needs a new independent set.

## Checks on the evals

| Check | Result |
|---|---|
| Cases fail for real reasons | **Pass.** Every red-first miss loaded nothing; the proposed descriptions fix both |
| Independent held-out set | Found 1 shape the tuning cases missed, as in rounds 2 and 3 |
| Evals catch a broken harness | Not re-run; round 4's planted break stands for the method |
| Results hold still | 0 flaky held-out cases |

## Cost

| Step | USD |
|---|---|
| Tuning, current descriptions, 18 × 1 | 1.30 |
| Tuning, proposed, 18 × 3 | 3.31 |
| Held-out verdict, 44 × 3 | 7.22 |
| **Total** | **11.83** |

## Verdict

1. **Verdict on the evals: working.** The red-first run, the independent set and the tuning split
   each did their job.
2. **What the evals say about the harness.** The proposed descriptions close both known gaps with
   no loss of precision. `review` recall is 0.93 held out, below the 1.00 bar the user holds `tdd`
   and `test-gate` to; the gap is 1 shape.
3. **What to do next:**
   1. The orchestrator ships `proposed-descriptions.txt` as a wave.
   2. A round 6 for the narrowed-review shape: a fix, and a new independent set.
