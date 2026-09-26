# `test-gate` round 3 and the first live session pair, 2026-09-26

Round 2 ([`2026-09-26-routing-fix`](../2026-09-26-routing-fix/summary.md)) left `test-gate` recall
at 0.88 on its independent held-out set. It missed requests that only ask for a judgment of the
tests. Round 3 tests description v2 (`5e9441a`, merged on `main`), which names judge-only requests
and test smells. This round also ran the first live session pair for `tdd` and `test-gate` output
quality.

**Result: `test-gate` meets the bar. On a new independent held-out set it scores precision 1.00
and recall 0.97 (29 of 30); the 1 miss is a single flaky trial. `tdd` holds 1.00/1.00. Live,
`test-gate` removes a hollow test that the plugin-off agent waves through as ready.** `review`
recall on "merge verdict, ignore the tests" is 0 of 7, a gap outside this fix.

## Pins

| Pin | Value |
|---|---|
| Agent model | `claude-opus-5-5`, pinned with `--model` |
| Judge model | `claude-haiku-4-5-20251001`, pinned; routing has no `llm` graders |
| `claude --version` | 2.1.282 |
| Harness, routing | `fix-tdd-test-gate-routing` `5e9441a` on the layout before `plugin/`. The `tdd` and `test-gate` descriptions are byte-identical to `main` `60e7603` |
| Harness, sessions | `16797f7` plus the 2 description lines, old layout, detached worktree |
| Xcode | 26.2 (17C48), Swift 6.2.3 |
| Settings, routing | `--runs 3 --ablation none --scaffold`, `max_turns: 1` |
| Settings, sessions | `session.mjs --runs 1`, both arms, `--session-cost-usd 3.5` |

## Method

1. **Tuning cases, run red first.** Round-3 tuning requests (`split-60`) for judge-only phrasing
   and named test smells. On the round-2 descriptions, `test-gate` recall was 0.83.
2. **An independent held-out set.** Before v2, a separate agent wrote 20 cases from the skill
   descriptions and the app alone. I moved them in without reading them.
3. **1 description change,** tuned on the 60 only.
4. **Verdict** on the round-3 held-out set, 3 trials. **Regression** over the round-1 and round-2
   held-out `tdd` and `test-gate` cases, 1 trial each. I have read the round-2 prompts, so that
   set counts as seen, not held out.

## Results

| Set | `tdd` P | `tdd` R | `test-gate` P | `test-gate` R | pass^k |
|---|---|---|---|---|---|
| Round-3 tuning, round-2 descriptions | 1.00 | 1.00 (6 of 6) | 1.00 | 0.83 (15 of 18) | 9 of 12 |
| Round-3 tuning, v2 | 1.00 | 1.00 (6 of 6) | 1.00 | 1.00 (18 of 18) | 11 of 12 |
| **Round-3 held-out, v2, 3 trials** | **1.00** | **1.00** (12 of 12) | **1.00** | **0.97** (29 of 30) | **17 of 20** |
| Round-1 and round-2 held-out, v2, 1 trial | 1.00 | 1.00 (16 of 16) | 1.00 | 1.00 (12 of 12) | 47 of 48 |

On the round-3 held-out set, `validate` scored 1.00/1.00 (6 of 6). The 6 `none` near-miss trials
loaded nothing. No skill loaded where it shouldn't have, in any set.

### Failures

| Case | Set | Expected | Passed | Cause |
|---|---|---|---|---|
| `r3-circular-mock-asserts-a` | held-out | `test-gate` | 2 of 3 | flaky: 1 trial loaded nothing |
| `r3-prod-code-merge-call-a`, `-b` | held-out | `review` | 0 of 3 each | `review` recall on "should this merge? ignore the tests"; `test-gate` stayed quiet, as it should |
| `approve-reducer-code-not-tests-a` | regression | `review` | 0 of 1 | the same `review` shape, seen in round 2 |
| `r3t-summarise-tests-for-pr-a` | tuning | `validate` | 0 of 3 before and after | `validate` misses "summarise the tests for the PR description"; v2 only touched `test-gate` |

`review` and `validate` misses load nothing at all, so they cost recall only. Both are for their
own rounds.

## Live session pair, 1 trial per arm

| Case | Arm | Score | Graders | USD | Time |
|---|---|---|---|---|---|
| `tdd` `decrement-floors-at-zero` | with | 0.75, 1.00 after the grader fix | hidden test, rubric 3/3, test before reducer; `swiftgate-red-seen` false negative | 0.23 | 319 s |
| | without | 1.00 | hidden test, rubric 3/3, test before reducer | 0.15 | 201 s |
| `test-gate` `hollow-test-before-ready` | with | **1.00** | rubric 3/3, push report, real test kept | 0.35 | 879 s |
| | without | **0.50** | rubric 0/3; real test kept | 0.17 | 176 s |

**`test-gate` shows what the plugin adds.** With the plugin, the agent named `decrementWorks` as a
restated duplicate and rewrote it as a 1→0 edge test. The ready tier then flagged the rewrite
`prove.not-proven`, since plain `count -= 1` also takes 1 to 0, so the agent deleted it and kept
`floorAtZero`. It said the branch would be ready once the user committed the test change. Without the
plugin, the agent reverted the fix by hand to prove `floorAtZero`, called the branch "good to mark
ready", and left `decrementWorks` as an optional cleanup.

**`tdd` doesn't separate the arms.** Both agents wrote the test first, saw it fail on the count
reaching -1, and made the hidden test pass. The plugin-off agent already works test-first on a task
this small. The loosened `red-then-green` rubric passed both real runs 3 of 3, which the round-2
changelog said a real run still had to show. It still has to fail a bad real run.

**The `swiftgate-red-seen` miss was the grader's fault.** The agent ran `swiftgate test --tier t1
--json`, got RED on `_count: -1`, and wrote "Red on the right assertion". It piped the report
through a `python3` filter that printed `RED`. The grader looked for the pretty-printed
`"verdict" : "RED"` in the trace, so it found nothing. The `test-gate` grader `push-tier-reported`
has the same flaw; it passed only because that agent printed 1 report unfiltered. Both graders now
read `.harness/runs/history.jsonl`, where swiftgate records every run's verdict however the agent
prints it, and skip the stop hook's `hook stop` runs. The runner test proves the new grader
passes a filtered RED, and fails on BLOCKED, on a stop-hook-only RED and on no history. It failed
on the old grader first. A synthetic check of both graders passed 10 of 10 good and bad histories.

## Checks on the evals

| Check | Result |
|---|---|
| Graders tell good from bad | Routing graders were proved in round 1. The session report-seen graders had a false negative on a real run. They are fixed and proved on synthetic histories, and the fix doesn't yet have a real run |
| Cases fail for real reasons | **Pass.** Every tuning miss on the round-2 descriptions loaded nothing; v2 fixes each one |
| Evals catch a broken harness | Not re-run this round; round 2's planted breaks stand |
| Results hold still | 1 flaky held-out case in 20 |
| Coverage | The independent set found a new `review` shape, a merge verdict that says to ignore the tests |

## Cost

| Step | USD |
|---|---|
| Red-first baseline, round-3 tuning, 12 cases × 3 | 2.11 |
| Tuning on v2, 12 cases × 3 | 2.09 |
| Held-out verdict, 20 cases × 3 | 3.45 |
| Regression, 48 cases × 1 | 2.87 |
| Live session pair, 2 cases × 2 arms, with judge | 0.90 |
| **Total traced to result files** | **11.42** |

The session before this one counted 17.8 USD spent in this batch before the session pair. I can
trace 10.52 USD of that to round-3 result files; the rest doesn't match any result file here.
Against the approved 30 USD, the higher count leaves about 11.3 USD.

## Verdict

1. **Verdict on the evals: working, with 1 grader defect found and fixed.** The independent set
   again found a shape the tuner's cases missed. The live pair found a grader that measured how the
   agent printed a report, not whether the report reached it.
2. **What the evals say about the harness.** `test-gate` v2 meets the bar: 1.00 precision, 0.97
   recall held out, and 1.00/1.00 on the regression set. Live, it removes a hollow test the
   plugin-off agent passes. `tdd` holds 1.00/1.00 but shows no live gain on this task.
3. **What to do next:**
   1. Route the 5 other skills (`bootstrap`, `design`, `plan`, `prose`, `status`): 100 seeded
      cases, tag `round-4`.
   2. A `review` round for "would you approve this" and "merge verdict, ignore the tests", and a
      `validate` fix for "summarise the tests for the PR description".
   3. A harder `tdd` session case, where the plugin-off agent is likely to skip the red step,
      then 3 trials per arm for both cases.
