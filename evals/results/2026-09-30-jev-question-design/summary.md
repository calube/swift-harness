# Jev question designs for test quality, 2026-09-30

A research run asked whether TypeSafe's Jev can match Claude Sonnet 5.5 as the test-quality judge
when someone writes the questions for Jev's primitives instead of reused from `test-quality@1`. Model:
`jev-1.13.0`, which every reply reported. Claude comparison: `claude-sonnet-5-5` through the exact
`ClaudeCLIJudge` prompt, schema and flags, 1 run on the dev set. Jev calls: 401 of a 600 budget.
Claude calls: 40. The run kept 39 replies; it didn't write the first call's output, so Claude has
n = 39 on dev.

The design that adopts these results is §13 of
[the Jev judge backend design](../../../docs/designs/2026-09-30-jev-judge-backend-design.md).

> **Agent-written, agent-labelled data.** An agent wrote every case in `dev-set/` and
> `dev-holdout/`, labelled them, and wrote the questions. Each case carries `labeller: agent`.
> These cases are for design exploration only. They never count toward a block calibration, a
> baseline or the reported benchmark, and no loader under `plugin/` reads them.

**Result: decomposed Nouls over a named-field state lift Jev's `fails-if-broken` recall on dev from
0.50 to 1.00, level with Claude's. A Choice over the parsed test name lifts `name-specificity`
recall from 0.00 to 0.92, and 3 Nouls cut `asserts-implementation`'s dev false positives from 3 to
0. A cascade that sends Jev's uncertain answers (0.2 to 0.8) to Claude matched Claude alone on dev
at about a fifth of Claude's calls. Every number rests on agent labels or 7 tune cases; the report
split is untouched.**

## Data and what each number can support

| Set | n | What it is | How it was used |
|---|---|---|---|
| dev | 40 | agent-written cases in `dev-set/`, agent-labelled | designs were iterated on it (round 1, then round 2). Optimistic |
| holdout | 14 | agent-written cases in `dev-holdout/`, written after round 2 froze the designs | scored once, no changes after. Same author as the questions, so not independent |
| tune | 7 | `plugin/gate/Fixtures/judge/` cases whose SHA-256 of the id starts below `0x55` | scored every round; only 2, 4 and 1 positives per question |
| report | 15 | the other `plugin/gate/Fixtures/judge/` cases | never opened or scored. An earlier probe's summary named a few of them and their probe answers; the run read no report case content or label |

Metrics mirror the benchmark design: positive means the flag fires on the label; the decision is at
p ≥ 0.5; proportions carry Wilson 95% intervals. Each number is the mean flagged probability over 2
repeats (`r2`, `r3`), each a request holding every candidate question. A third run sent **only the
proposed questions**, the request that would ship. It reproduced every decision except 1 borderline
case per question, listed below. Tier argmax was 61/61 correct in that run, so the new
sub-questions don't disturb it.

**The largest finding is in the baseline.** Today's adapter sends the `name-specificity` Score with
bare level names (`["vague", "partial", "specific"]`) as criteria. That scores recall 0.00 on dev
(0/12). An earlier probe's 0.62 came from its own request, which put the level descriptions in
criteria; that version scores 0.33 here.

## fails-if-broken (blocking)

**Design.** 2 Nouls over the named-field state, combined in code as an OR over the failure signals:
`p_no = max(1 - p(runs-changed-code), 1 - p(checks-named-result))`. The exact wording is in
`questions.json`.

| Design | Set | n | TP/FP/FN/TN | Recall | Precision | Accuracy | Brier |
|---|---|---|---|---|---|---|---|
| Jev today (adapter request) | dev | 40 | 10/0/10/20 | 0.50 [0.30,0.70] | 1.00 [0.72,1.00] | 0.75 [0.60,0.86] | 0.170 |
| Jev today | holdout | 14 | 4/0/3/7 | 0.57 [0.25,0.84] | 1.00 [0.51,1.00] | 0.79 [0.52,0.92] | 0.153 |
| Jev today | tune | 7 | 2/0/0/5 | 1.00 [0.34,1.00] | 1.00 [0.34,1.00] | 1.00 [0.65,1.00] | 0.041 |
| **proposed** | dev | 40 | 20/1/0/19 | 1.00 [0.84,1.00] | 0.95 [0.77,0.99] | 0.97 [0.87,1.00] | 0.041 |
| **proposed** | holdout | 14 | 7/0/0/7 | 1.00 [0.65,1.00] | 1.00 [0.65,1.00] | 1.00 [0.78,1.00] | 0.041 |
| **proposed** | tune | 7 | 2/1/0/4 | 1.00 [0.34,1.00] | 0.67 [0.21,0.94] | 0.86 [0.49,0.97] | 0.091 |
| Claude Sonnet 5.5 | dev | 39 | 20/1/0/18 | 1.00 [0.84,1.00] | 0.95 [0.77,0.99] | 0.97 [0.87,1.00] | 0.024 |

Errors of the proposed design: dev false positive `countdown-stops-on-dismiss`, a cancellation that
only TestStore exhaustivity proves (0.79); tune false positive `ui-flow-in-t1`, an XCUITest that
drives a Button (0.58). In the standalone run, `private-state-coupling` (tune) moved from 0.48 to
0.57, a second false positive. Claude's 1 dev false positive was `encoder-args`. The cases near 0.5
are the internal-state tests (0.45 to 0.57), which the cascade band sends on.

The same design over today's state (`subject` and `context`, with the name referred to in words):
dev 19/2/1/18, holdout 7/1/0/6, tune 2/2/0/3. Close, but the parsed name and assertion list help
precision.

**Cascade** (Jev decides outside 0.2 to 0.8, Claude inside): escalates 7/40 dev (0.17
[0.09,0.32]), 3/14 holdout and 2/7 tune. Jev's kept answers are 1.00 accurate on all 3 sets; the
combined dev result is 20/1/0/19, the same as Claude alone.

## name-specificity (advisory)

**Design.** 1 Choice over the code-parsed name parts, whose options map onto the levels:
`vague = p(nothing)`, `partial = p(condition)`, `specific = p(symptom)`. The question is "What does
`test_name.catches` say beyond `test_name.behavior`?", with contrastive criteria and invented
examples, none taken from a case.

| Design | Set | n | TP/FP/FN/TN | Recall | Precision | Accuracy | Brier |
|---|---|---|---|---|---|---|---|
| Jev today (bare level names) | dev | 40 | 0/0/12/28 | 0.00 [0.00,0.24] | - | 0.70 [0.55,0.82] | 0.172 |
| Jev today | holdout | 14 | 1/0/3/10 | 0.25 [0.05,0.70] | 1.00 [0.21,1.00] | 0.79 [0.52,0.92] | 0.123 |
| Jev today | tune | 7 | 1/0/3/3 | 0.25 [0.05,0.70] | 1.00 [0.21,1.00] | 0.57 [0.25,0.84] | 0.233 |
| level descriptions in criteria | dev | 40 | 4/0/8/28 | 0.33 [0.14,0.61] | 1.00 [0.51,1.00] | 0.80 [0.65,0.90] | 0.098 |
| **proposed** | dev | 40 | 11/0/1/28 | 0.92 [0.65,0.99] | 1.00 [0.74,1.00] | 0.97 [0.87,1.00] | 0.029 |
| **proposed** | holdout | 14 | 4/0/0/10 | 1.00 [0.51,1.00] | 1.00 [0.51,1.00] | 1.00 [0.78,1.00] | 0.004 |
| **proposed** | tune | 7 | 4/0/0/3 | 1.00 [0.51,1.00] | 1.00 [0.51,1.00] | 1.00 [0.65,1.00] | 0.019 |
| Claude Sonnet 5.5 | dev | 39 | 10/0/2/27 | 0.83 [0.55,0.95] | 1.00 [0.72,1.00] | 0.95 [0.83,0.99] | 0.059 |

The proposed design's miss: `existence-parse`, whose name catches "problems parsing prices", which
Jev reads as a condition. `spy-call-order` sits at 0.44 to 0.51 and flipped between runs.

## asserts-implementation (blocking)

**Design.** 3 Nouls over `assertions`, combined as an OR in code:
`p_yes = max(call-details, private-state, log-text)`.

| Design | Set | n | TP/FP/FN/TN | Recall | Precision | Accuracy | Brier |
|---|---|---|---|---|---|---|---|
| Jev today | dev | 40 | 6/3/0/31 | 1.00 [0.61,1.00] | 0.67 [0.35,0.88] | 0.93 [0.80,0.97] | 0.100 |
| Jev today | holdout | 14 | 1/4/1/8 | 0.50 [0.09,0.91] | 0.20 [0.04,0.62] | 0.64 [0.39,0.84] | 0.147 |
| Jev today | tune | 7 | 1/0/0/6 | 1.00 [0.21,1.00] | 1.00 [0.21,1.00] | 1.00 [0.65,1.00] | 0.063 |
| **proposed** | dev | 40 | 6/0/0/34 | 1.00 [0.61,1.00] | 1.00 [0.61,1.00] | 1.00 [0.91,1.00] | 0.021 |
| **proposed** | holdout | 14 | 2/1/0/11 | 1.00 [0.34,1.00] | 0.67 [0.21,0.94] | 0.93 [0.69,0.99] | 0.072 |
| **proposed** | tune | 7 | 1/0/0/6 | 1.00 [0.21,1.00] | 1.00 [0.21,1.00] | 1.00 [0.65,1.00] | 0.004 |
| Claude Sonnet 5.5 | dev | 39 | 6/1/0/32 | 1.00 [0.61,1.00] | 0.86 [0.49,0.97] | 0.97 [0.87,1.00] | 0.034 |

Clock-driven good tests such as retry and backoff: proposed 0.09 to 0.12, baseline 0.33 to 0.41.
The earlier probe's retry-backoff false positive is a report-split case, so the run didn't check it.

**Open weakness: a spy's record as the feature's output.** The proposed design's holdout false
positive is `h-reminder-schedule` (0.84), where a spy's record of scheduled notifications *is* what
the feature produces. The same shape sits at 0.42 on dev (`autosave-draft`). 0.84 lies outside any
sensible cascade band, so the cascade doesn't catch it. In the standalone run `mock-session-task`
moved to 0.53, 1 dev false positive.

**Cascade** 0.2 to 0.8: escalates 4/40 dev, 1/14 holdout and 0/7 tune.

## What didn't work

- `fails-if-broken`:
  - A counterfactual Noul, whether an assertion would fail if the changed lines produced a wrong
    value, reached recall 0.55.
  - A Choice over the parsed assertions reached 0.55 to 0.60 with 4 false positives. It asked for
    the assertion that checks a changed value, or `none`.
  - A Noul on whether an assertion checks a value the changed lines compute gave 4 false positives
    on spy tests. It also passed wrong-field TCA tests, since the changed reducer also sets the
    asserted field.
  - A Noul on whether every asserted value comes from the test or a double gave 6 false positives,
    since spies are doubles.
  - A read-back Noul reached 0.40 to 0.45. An existence-only Noul adds nothing once
    `checks-named-result` exists. The base wording over the named state was no better (0.40).
- `name-specificity`: a structured Score with examples per level reached 0.42 to 0.50 on dev (1.00
  on tune). A "restates" Noul alone reached 0.50 to 0.58. `restates OR (no symptom AND no
  condition)` matched the Choice on dev (0.92) but missed 1 on tune and 1 on holdout, with 3
  questions instead of 1.
- `asserts-implementation`: the base question plus criteria and exclusions kept the same 3 dev false
  positives. The same 3 sub-questions over today's state gave 2 holdout false positives.

## Cost and speed

The proposed request is 1.6K to 1.9K input tokens, about $0.00007 per test at $0.042 per million,
with a p50 latency of 0.23 s. A Claude call cost $0.0066 on average (39 calls, $0.26).

## Caveats

- An agent labelled the dev and holdout cases and wrote the questions, so labels and designs share
  1 view of what "vague" or "fails if broken" means. The repo's labels agree on 7 tune cases, which
  is little, and those carry the tuning agent's labels too.
- Dev numbers are optimistic, since the designs changed after round 1. Holdout is the fairer
  estimate; only the report split is untouched.
- 2 repeats plus 1 standalone run: 0 or 1 decision flips per question, all at p from 0.44 to 0.57.
- The run read the cascade band 0.2 to 0.8 off dev. The benchmark's tune split sets the real one.

## Files

| File | What it holds |
|---|---|
| `questions.json` | the proposed question set: the Jev sub-questions verbatim, the combine rules, the state fields and the cascade band |
| `results.json` | the shortlisted designs per case and per run, the cascade tables, the standalone run and call counts |
| `tables.md` | every shortlisted design's table, with flips and 3 cascade bands per question |
| `dev-set/`, `dev-holdout/` | the agent-written cases (`Test.swift.txt`, `Change.diff`) and their agent labels |
| `raw.tar.gz` | every Jev and Claude reply, with the request that produced it |
| `ledger.jsonl` | 1 line per Jev call: tag, time, status |
| `scripts/` | the code that wrote the cases, sent the requests and scored them |

To re-run, with `TYPESAFE_API_KEY` in the environment and Python 3.12:

```
cd evals/results/2026-09-30-jev-question-design
tar xzf raw.tar.gz                  # the kept replies, to re-score without the network
python3 scripts/make_dev_set.py && python3 scripts/make_holdout.py
PYTHONPATH=scripts python3 scripts/run_round.py questions_r2 r2 s0,s1
PYTHONPATH=scripts python3 scripts/run_round.py questions_final final s1
PYTHONPATH=scripts python3 scripts/run_claude.py
PYTHONPATH=scripts python3 scripts/score.py r2 && PYTHONPATH=scripts python3 scripts/final.py
```

`run_round.py` skips a reply already in `raw/`, and `lib.py` stops at 600 Jev calls counted in
`ledger.jsonl`. Delete `raw/` and the ledger to re-run from nothing. The scripts never write the key.

Re-scoring the kept replies with `final.py` reproduces `results.json`'s `runs`, `questions` and
`jev_calls_used` byte for byte. A one-off step the run didn't keep added `standalone_final_request`,
`claude_calls` and `splits`; the standalone run's replies are in `raw/final/`.
