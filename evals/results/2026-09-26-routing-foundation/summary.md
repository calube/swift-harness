# Skill routing, foundation skills, 2026-09-26

Tests whether the right skill loads, and only that skill, for `tdd`, `architecture`, `review`,
`test-gate`, `validate` and `comment-audit`. There are 120 cases: 5 should-trigger and 5
near-miss requests per skill, with 2 paraphrases each. The split is 60/40 by request: 72
cases tune the descriptions and 48 form the held-out set. Every number under "Held-out result" comes from the 48 held-out
cases only. `summary.json` has the same numbers and every case's trials.

**Result: 5 of the 6 skills meet the bar at 1.00 precision and 1.00 recall. `tdd` misses it
with recall 0.67:** it doesn't load when a user asks to fix a failing or flaky test.

## Pins

| Pin | Value |
|---|---|
| Agent model | `claude-opus-5-5`, pinned with `--model` |
| Judge model | `claude-haiku-4-5-20251001`, pinned; routing has no `llm` graders |
| `claude --version` | 2.1.282 |
| Harness commit | `7052d8d` on `main`; the branch changes only `evals/` |
| Xcode | 26.2 (17C48), Swift 6.2.3 |
| Settings | `--runs 3 --ablation none --scaffold`, `max_turns: 1`, tools `Read, Glob, Grep, Skill` |

## Held-out result (split-40)

48 cases, 144 trials, 7.99 USD, 19 minutes at `-j 4`. The bar is 0.9 precision and 0.9 recall
per skill.

| Skill | Precision | Recall | Expected trials | Loaded trials | Bar |
|---|---|---|---|---|---|
| `tdd` | 1.00 | **0.67** | 24 | 16 | **misses** |
| `architecture` | 1.00 | 1.00 | 12 | 12 | meets |
| `review` | 1.00 | 1.00 | 12 | 12 | meets |
| `test-gate` | 1.00 | 1.00 | 18 | 18 | meets |
| `validate` | 1.00 | 1.00 | 18 | 18 | meets |
| `comment-audit` | 1.00 | 1.00 | 12 | 12 | meets |

Near-misses routed to other skills too: `prose` 6 of 6, `status` 6 of 6. Of the 36 trials
expected to load no harness skill, all 36 loaded none.

Confusion table: the expected skill down the side, the first skill the trial loaded across the top.

| Expected \ loaded | `architecture` | `comment-audit` | `prose` | `review` | `status` | `tdd` | `test-gate` | `validate` | none |
|---|---|---|---|---|---|---|---|---|---|
| `architecture` | 12 | | | | | | | | |
| `comment-audit` | | 12 | | | | | | | |
| `prose` | | | 6 | | | | | | |
| `review` | | | | 12 | | | | | |
| `status` | | | | | 6 | | | | |
| `tdd` | | | | | | 16 | | | **8** |
| `test-gate` | | | | | | | 18 | | |
| `validate` | | | | | | | | 18 | |
| none | | | | | | | | | 36 |

No trial loaded a wrong skill. Every error is a miss, where the agent loaded nothing.

**pass^3: 44 of 48 cases.** Flaky cases, which passed some trials and not others:
`tdd/failing-client-test-b` (2 of 3), `test-gate/flaky-engine-test-a` (1 of 3) and
`test-gate/flaky-engine-test-b` (1 of 3). `tdd/failing-client-test-a` failed 3 of 3.

## Error analysis

| Cause | Trials | Layer | Action |
|---|---|---|---|
| "Fix a failing test" and "make a flaky test stable" go straight to a Glob, and `tdd` never loads | 8 held-out | skill (`tdd` description) | fix the harness; see "Proposed description changes" |
| "Look at the tests on this branch and tell me whether any are fake" reads the tests without loading `test-gate` | 6 tuning, 3 per setting | skill (`test-gate` description) | fix the harness |
| "Review the design for offline sync" searches for a design doc and loads nothing | 6 tuning, 3 per setting | case or skill (`design`); no design exists in the scaffold | record a limit; reword before the `design` round |
| "Would you merge this diff" on a scaffold with no diff: the agent correctly said there was nothing to review | 2 tuning | case | **fixed**: the routing scaffold now carries a branch change and a staged edit. After the fix: 3 of 3 |

**Checking the 1-turn cap.** The `tdd` misses could have been an artifact of `max_turns: 1`. I
reran the 4 cases at `max_turns: 3`. Every trial that skipped the skill in turn 1 also skipped it
in turns 2 and 3, and started reading and fixing code instead. The misses are real.

## Tuning set (split-60)

These numbers show where descriptions need work. They don't count toward the result.

| Skill | Precision | Recall | Expected trials |
|---|---|---|---|
| `tdd` | 1.00 | 1.00 | 30 |
| `architecture` | 1.00 | 1.00 | 18 |
| `review` | 1.00 | 1.00 | 42 |
| `test-gate` | 1.00 | 0.90 | 30 |
| `validate` | 1.00 | 1.00 | 24 |
| `comment-audit` | 1.00 | 1.00 | 30 |
| `design` | 1.00 | 0.75 | 12 |

pass^3: 70 of 72. The set ran in 2 batches. 45 cases ran at `max_turns: 2` on the plain
SampleApp. The run stopped at its cost cap, and I then fixed the scaffold. The other 27 ran on
the final settings. In the first batch, all 136 skill loads came in the first assistant turn, so
the 2 settings grade the same.

## Proposed description changes

`skills/` is off limits on an eval branch. Each change below needs a fix branch.

1. **`tdd`: the defect the held-out set found.** The tuning set has no "fix a failing test" or
   "flaky test" request, so it holds no evidence to tune on. Tuning on the 40 would leak it into
   the result. Proposal: first add 2 such requests to the tuning split, then change the `Use when`
   clause to lead with the missed intents, for example: *"Use when fixing a failing, flaky or
   broken test, implementing any feature, bug fix or behavior change…"*. A fresh held-out set
   then confirms the change.
2. **`test-gate`:** 6 of 6 tuning trials missed "tell me whether any of these tests are fake".
   Add that intent: *"…'are these tests real', 'are any of my tests fake or trivial', 'review
   my tests'…"*.
3. **`design`** is outside this round. "Review the design for X" loads nothing when no design
   exists. Settle the case wording in the `design` round before changing the description.

## Checks on the evals

| Check | Result |
|---|---|
| Graders tell good from bad | **Pass.** Should-trigger `loads-tdd`: plugin on passed, plugin off failed. Near-miss `skips-tdd` and `loads-no-harness-skill`: real prompt passed both, and a swapped tdd prompt failed both. `routing.mjs` has 4 unit tests, and 2 planted scorer bugs each failed 1 of them |
| Cases fail for real reasons | **Pass after 1 fix.** One case failed because the scaffold had no diff. I fixed the scaffold and reran it |
| Cases discriminate | **Pass on recall; precision is unproven.** Precision is 1.00 everywhere. No break has shown that a near-miss can catch a wrong load in a live run, apart from the synthetic swap above |
| Evals catch a broken harness | **Pass.** On a scratch branch, blanking the `tdd` description took 6 `tdd` cases from recall 1.00 to 0.00. The branch is deleted |
| Results hold still | **3 flaky held-out cases,** all with the same request shape as the `tdd` defect. The flakiness is the defect showing up, not noise in the case |
| Coverage matches the contracts | **Gap.** The held-out set tests a request shape the tuning set lacks, so the tuning set can't fix it. The seed now needs coverage per intent across both splits |
| Signal is worth the cost | **Yes.** 31.81 USD found 1 harness defect below the bar, 2 more description gaps and 1 case flaw |

## Cost and time

| Step | USD |
|---|---|
| Per-run cost measurement (4 runs) | 0.44 |
| Grader proofs (4 runs) | 0.29 |
| `tdd` rubric proof (synthetic, Haiku) | 0.10 |
| Split-60 (243 runs, 3 of them reruns) | 21.62 |
| Split-40 (144 runs) | 7.99 |
| `max_turns: 3` probe (12 runs) | 1.05 |
| Planted break (6 runs) | 0.32 |
| **Total** | **31.81** of 35 approved |

The measured per-run cost was too low. At `max_turns: 2` the mean run cost 0.107 USD, not
0.067. After loading a skill, the agent had no shell and spent its second turn on a subagent,
at up to 0.48 USD. The first split-60 batch hit its 17 USD cap after 162 of 216 runs. At
`max_turns: 1` a run averages 0.055 USD.

Wall time: split-60 took 22 minutes for the first batch. The second batch spent 3.4 hours in wall
time because the machine hibernated on a flat battery mid-run. 4 runs spanned the hibernation. They
ended at their turn cap as usual, with normal cost and a first-turn skill load, so their grades stand. Split-40
took 19 minutes.

Transcripts were in the runner's kept `e-*` temp directories. `routing.mjs` read the skill calls
out of them into `summary.json`, and then I deleted them.

## Findings about the runner

- `allowed_tools` in `prompt.md` doesn't stop the agent from calling `Agent` or `ToolSearch`.
  With `max_turns` above 1, routing runs spawn general-purpose subagents.
- `--case` takes 1 glob with no brace sets. To run a hand-picked set, add a temporary tag.
- `--max-cost-usd` stops the run and still exits 0. Check `partial` in the JSON.

## Verdict

1. **Verdict on the evals: working as designed and giving value.** The graders separate good from
   bad, and the evals caught the planted break. Every failure traces to a named cause. The run led
   to 2 actions: a case fix, and a harness defect to fix. There are 2 weaknesses. Precision has no
   planted-break proof, and the tuning split lacks the request shape where the defect sits.
2. **What the evals say about the harness.** On the held-out set, 5 of the 6 foundation skills
   route at 1.00 precision and 1.00 recall. `tdd` recall is 0.67: requests to fix a failing or
   flaky test skip the skill. No trial loaded a wrong skill. pass^3 is 44 of 48.
3. **What changed in the evals.** See `evals/CHANGELOG.md` for 2026-09-26.
4. **What to do next, in order:**
   1. Add 2 fix-a-test requests to the tuning split and open a fix branch for the `tdd` and
      `test-gate` descriptions. Rerun both skills' 40 cases, about 7 USD.
   2. Prove the precision side: on a scratch branch, widen a description to claim every test
      request, and rerun the near-misses, about 1 USD.
   3. Prove the loosened `tdd` rubric on 1 real session run per arm, 2 to 4 USD.
   4. Route the other 5 skills (`design`, `plan`, `prose`, `status`, `bootstrap`): 100 cases at
      about 0.055 USD a trial, about 17 USD for 3 trials.
