# Judge benchmark: Sonnet 5.5 against Jev 1.13.0

**The labels are an Opus agent's, not a person's.** An Opus agent labelled every case blind (`labeller: agent`;
the pages below show person 0). These results are for information only, and they may favour the Claude arm,
which is a model of the same family as the labeller. No result here decides whether Jev may block `ready`: the
user removed the block calibration on 2026-09-30, and Jev blocks on its own at `block_threshold`.

## What ran

| Dataset | Cases (report / tune) | Arms | Repeats |
|---|---|---|---|
| `test-quality` (`test-quality@1` labels) | 66 (44 / 22) | Claude `@1` at `claude-sonnet-5-5`; Jev `@1` and Jev `@2-jev` at `jev-1.13.0`; the cascade `jev-1.13.0,claude-sonnet-5-5` | 3 |
| `comments` (`comments@1` labels) | 80, 3 unlabelled (45 / 32) | Claude `@1`, Jev `@1` | 3 |

Every call skipped the cache, 1 request at a time. Each dataset ran as several `judge bench` commands over
disjoint `--case` chunks, so that each command fit in 10 minutes. The chunks were joined into 1 result per
dataset by `JudgeBenchmarkReport`'s own initializer, which recomputes every metric from the raw answers, and
`bench-render` verifies them. Claude and both Jev arms took turns within each repeat. The cascade ran after its
bands were set, below, so its answers come from a later run than the other 3 arms'. One chunk failed at its
3rd repeat on a Jev reply that couldn't be parsed, and was asked again from scratch.

Skipped: dataset 3, `calibrate design`'s judged labels. A live `calibrate design` run passed 23 of 23 seeds
and kept its replies, but the Claude arm can't answer that dataset: its question ids carry the
`<agent>/<seed>/` prefix, and Claude's structured-output schema refuses `/` in a property key (API error 400
on the first case). Dataset 4 waits for the evals owners' trial.

## Cascade bands, from the tune split only

The sweep reads only the `@2-jev` arm's 22 tune-split cases, at threshold 0.50. Its candidate bands run from
0.05 to 0.40 at the lower edge and 0.60 to 0.95 at the upper, in steps of 0.05, so every band holds 0.4 to 0.6,
where a rerun of the Jev request moved answers across 0.5. It picks the band with the fewest kept answers
wrong, then the fewest escalations, then the narrowest, then the lowest.

- `fails-if-broken`: band 0.40 < p < 0.90. Tune: 11 of 22 escalate, and 11 of 11 kept answers are right.
  The design's 0.2 to 0.8 band kept 10 of 11 right at the same 11 escalations.
- `asserts-implementation`: band 0.30 < p < 0.95. Tune: 4 of 21 escalate, and 17 of 17 kept answers are
  right. The 0.2 to 0.8 band kept 17 of 20 right.

With `block_threshold` 0.9, a kept Jev answer on `asserts-implementation` blocks only at 0.95 or above; a
Jev `fails-if-broken` answer from 0.9 up blocks with a Claude-written reason.

## Blocking questions, report split

The flag firing is the positive class. Each rate reads the majority decision over 3 repeats, with a Wilson 95%
interval.

| Question | Arm | True-positive rate | True-negative rate |
|---|---|---|---|
| `fails-if-broken` | Claude `@1` | 1.00 (10/10) [0.72, 1.00] | 1.00 (32/32) [0.89, 1.00] |
| `fails-if-broken` | Jev `@1` | 0.30 (3/10) [0.11, 0.60] | 1.00 (32/32) [0.89, 1.00] |
| `fails-if-broken` | Jev `@2-jev` | 0.90 (9/10) [0.60, 0.98] | 0.84 (27/32) [0.68, 0.93] |
| `fails-if-broken` | cascade | 1.00 (10/10) [0.72, 1.00] | 1.00 (32/32) [0.89, 1.00] |
| `asserts-implementation` | Claude `@1` | 0.50 (5/10) [0.24, 0.76] | 0.97 (33/34) [0.85, 0.99] |
| `asserts-implementation` | Jev `@1` | 0.60 (6/10) [0.31, 0.83] | 0.94 (32/34) [0.81, 0.98] |
| `asserts-implementation` | Jev `@2-jev` | 0.50 (5/10) [0.24, 0.76] | 0.79 (27/34) [0.63, 0.90] |
| `asserts-implementation` | cascade | 0.60 (6/10) [0.31, 0.83] | 0.97 (33/34) [0.85, 0.99] |

Jev `@2-jev` alone finds most `fails-if-broken` problems, but it flags 5 of 32 sound tests. On
`asserts-implementation` it's weak on both rates. The cascade matches Claude on `fails-if-broken` and is within
1 case of it on `asserts-implementation`, where every interval is wide: 10 positives can't separate the arms.

**Cost.** The cascade sent 56 of 132 answered case-repeats to Claude (0.42, [0.34, 0.51]): 32 of 126 on
`fails-if-broken` and 26 of 132 on `asserts-implementation`. Its cost per case was $0.00135 against Claude's
$0.00523 (n=132 each), about a quarter, and its p50 latency per case was 218 ms against 3808 ms. Jev `@2-jev`
alone cost $0.00007 per case.

**The spy-record shape.** The report split's `asserts-implementation` cases where a test reads what a spy
recorded, and the record is the feature's own output (here, requests the code sent), are all labelled `no`:

| Case | What it reads | Claude `@1` | Jev `@1` | Jev `@2-jev` | cascade |
|---|---|---|---|---|---|
| `case-5e44c5` | the sent request's `Accept` header | 0.32 (passes) | 0.44 (passes) | 0.74 (flags) | 0.27 (passes) |
| `case-1d1de2` | the number of requests sent | 0.35 (passes) | 0.45 (passes) | 0.93 (flags) | 0.32 (passes) |
| `case-bea4db` | a request counter left at 0 | 0.17 (passes) | 0.41 (passes) | 0.76 (flags) | 0.20 (passes) |

Jev `@2-jev` flags all 3; each lies inside the band, so the cascade escalated it and Claude's answer stood. The
design's open risk is a case of this shape above 0.95, which would stand and block; none appeared here.

On the comments set, the report split holds only 5 `loses-fact` positives and 2 `right-size` positives, so its
page ranks nothing: both arms find all 5 `loses-fact` cases, and their true-negative rates' intervals overlap.

## Recordings and baselines

`recording.json` (Claude `@1`, `claude-sonnet-5-5`) and `recording-jev.json` (Jev `@2-jev`, `jev-1.13.0`) were
recorded again over all 66 cases, with served models and usage. `baseline-jev.json` takes each minimum from the
tune split only: the lower Wilson 95% bound of the recording's tune-split precision and recall, rounded down to
0.05. `baseline.json` keeps 0.80 wherever Claude's new recording still meets it. Over the harder set, Claude's
`asserts-implementation` recall is 0.67 (8/12), so that one minimum falls to the tune-split bound, 0.30.

## Spend

Claude: $2.59 measured over the benchmark, the self-test recording and a 3-case smoke run, plus about $0.39 on
the chunk that failed. The `calibrate design` run's agents and judge report no cost. Jev: $0.05.

# Judge benchmark: test-quality

- Dataset `test-quality`, question set `test-quality@1`, hash `93b60ea6d2cea5b0cc69a020b07762fe52ff7eb08465771025fcdec77cb190d4`
- Cases: 66, 0 unlabelled; split: tune 22, report 44
- Labellers: person 0, agent 66, seed 0
- Run: 66 cases, 3 repeats, decision threshold 0.50; swiftgate 0.1.0, started 2026-09-30T22:46:14Z

| Arm | Backend | Requested model | Served model | Asks | Scored against |
|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` | claude | claude-sonnet-5-5 | claude-sonnet-5-5 | test-quality@1 | test-quality@1 |
| `jev:jev-1.13.0` | jev | jev-1.13.0 | jev-1.13.0 | test-quality@1 | test-quality@1 |
| `jev:jev-1.13.0#test-quality@2-jev` | jev | jev-1.13.0 | jev-1.13.0 | test-quality@2-jev | test-quality@1 |
| `cascade:jev-1.13.0,claude-sonnet-5-5` | cascade | jev-1.13.0,claude-sonnet-5-5 | jev-1.13.0 | test-quality@2-jev | test-quality@1 |

Every number reads the report split only. A rate shows its count out of n with a Wilson 95% interval; Brier, calibration error, κ and each difference show a paired bootstrap 95% interval (2000 resamples, seed 20260930).

## Person labels

No person labels: every label in this dataset is an agent's or a seed's, so this view has no numbers. The all-labels view below is not a person-labelled result.

## All labels

Report-split cases: 44.

### fails-if-broken

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| Precision | 1.00 (n=10: 10/10), 95% [0.72, 1.00] | 1.00 (n=3: 3/3), 95% [0.44, 1.00] | 0.64 (n=14: 9/14), 95% [0.39, 0.84] | 1.00 (n=10: 10/10), 95% [0.72, 1.00] |
| True-positive rate (recall) | 1.00 (n=10: 10/10), 95% [0.72, 1.00] | 0.30 (n=10: 3/10), 95% [0.11, 0.60] | 0.90 (n=10: 9/10), 95% [0.60, 0.98] | 1.00 (n=10: 10/10), 95% [0.72, 1.00] |
| True-negative rate | 1.00 (n=32: 32/32), 95% [0.89, 1.00] | 1.00 (n=32: 32/32), 95% [0.89, 1.00] | 0.84 (n=32: 27/32), 95% [0.68, 0.93] | 1.00 (n=32: 32/32), 95% [0.89, 1.00] |
| Accuracy | 1.00 (n=42: 42/42), 95% [0.92, 1.00] | 0.83 (n=42: 35/42), 95% [0.69, 0.92] | 0.86 (n=42: 36/42), 95% [0.72, 0.93] | 0.98 (n=42: 41/42), 95% [0.88, 1.00] |
| Brier score | 0.037 (n=42), 95% [0.022, 0.057] | 0.210 (n=42), 95% [0.104, 0.339] | 0.245 (n=42), 95% [0.120, 0.400] | 0.070 (n=42), 95% [0.039, 0.112] |
| Calibration error | 0.113 (n=42), 95% [0.092, 0.138] | 0.125 (n=42), 95% [0.092, 0.232] | 0.185 (n=42), 95% [0.128, 0.293] | 0.130 (n=42), 95% [0.110, 0.171] |
| Flips over repeats | 0.00 (n=42: 0/42), 95% [0.00, 0.08] | 0.02 (n=42: 1/42), 95% [0.00, 0.12] | 0.02 (n=42: 1/42), 95% [0.00, 0.12] | 0.05 (n=42: 2/42), 95% [0.01, 0.16] |
| Mean SD of the flagged p | 0.012 (n=42) | 0.006 (n=42) | 0.008 (n=42) | 0.017 (n=42) |

| Difference (first − second) | κ | Brier | Calibration error | Accuracy | True-positive rate | True-negative rate |
|---|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0` | 0.395 (n=42), 95% [0.000, 0.706] | -0.173 (n=42), 95% [-0.304, -0.066] | -0.012 (n=42), 95% [-0.132, 0.033] | 0.167 (n=42), 95% [0.071, 0.286] | 0.700 (n=42), 95% [0.385, 1.000] | 0.000 (n=42), 95% [0.000, 0.000] |
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0#test-quality@2-jev` | 0.654 (n=42), 95% [0.380, 0.884] | -0.207 (n=42), 95% [-0.351, -0.094] | -0.072 (n=42), 95% [-0.162, -0.026] | 0.143 (n=42), 95% [0.048, 0.262] | 0.100 (n=42), 95% [0.000, 0.333] | 0.156 (n=42), 95% [0.036, 0.294] |
| `claude:claude-sonnet-5-5` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 1.000 (n=42), 95% [1.000, 1.000] | -0.032 (n=42), 95% [-0.065, -0.005] | -0.016 (n=42), 95% [-0.060, 0.008] | 0.024 (n=42), 95% [0.000, 0.071] | 0.000 (n=42), 95% [0.000, 0.000] | 0.000 (n=42), 95% [0.000, 0.000] |
| `jev:jev-1.13.0` − `jev:jev-1.13.0#test-quality@2-jev` | 0.267 (n=42), 95% [0.000, 0.552] | -0.035 (n=42), 95% [-0.218, 0.148] | -0.060 (n=42), 95% [-0.163, 0.079] | -0.024 (n=42), 95% [-0.190, 0.119] | -0.600 (n=42), 95% [-0.909, -0.273] | 0.156 (n=42), 95% [0.036, 0.294] |
| `jev:jev-1.13.0` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.395 (n=42), 95% [0.000, 0.706] | 0.140 (n=42), 95% [0.030, 0.270] | -0.005 (n=42), 95% [-0.062, 0.103] | -0.143 (n=42), 95% [-0.286, -0.024] | -0.700 (n=42), 95% [-1.000, -0.385] | 0.000 (n=42), 95% [0.000, 0.000] |
| `jev:jev-1.13.0#test-quality@2-jev` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.654 (n=42), 95% [0.380, 0.884] | 0.175 (n=42), 95% [0.065, 0.310] | 0.056 (n=42), 95% [-0.004, 0.142] | -0.119 (n=42), 95% [-0.214, -0.024] | -0.100 (n=42), 95% [-0.333, 0.000] | -0.156 (n=42), 95% [-0.294, -0.037] |

The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.132 to 0.033 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from 0.000 to 0.000 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.333 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.060 to 0.008 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.071 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.218 to 0.148 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.163 to 0.079 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.190 to 0.119 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.062 to 0.103 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.004 to 0.142 and crosses 0: these 42 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.333 to 0.000 and crosses 0: these 42 cases can't tell the 2 arms apart on it.

Reliability of the flagged probability:

| Bin | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| 0.0–0.1 | predicted 0.07, observed 0.00 (n=18: 0/18), 95% [0.00, 0.18] | predicted 0.08, observed 0.00 (n=20: 0/20), 95% [0.00, 0.16] | predicted 0.07, observed 0.00 (n=8: 0/8), 95% [0.00, 0.32] | predicted 0.07, observed 0.00 (n=7: 0/7), 95% [0.00, 0.35] |
| 0.1–0.2 | predicted 0.14, observed 0.00 (n=8: 0/8), 95% [0.00, 0.32] | predicted 0.13, observed 0.20 (n=10: 2/10), 95% [0.06, 0.51] | predicted 0.13, observed 0.00 (n=12: 0/12), 95% [0.00, 0.24] | predicted 0.13, observed 0.00 (n=16: 0/16), 95% [0.00, 0.19] |
| 0.2–0.3 | predicted 0.22, observed 0.00 (n=4: 0/4), 95% [0.00, 0.49] | predicted 0.28, observed 0.50 (n=4: 2/4), 95% [0.15, 0.85] | predicted 0.24, observed 0.00 (n=3: 0/3), 95% [0.00, 0.56] | predicted 0.23, observed 0.00 (n=5: 0/5), 95% [0.00, 0.43] |
| 0.3–0.4 | predicted 0.35, observed 0.00 (n=2: 0/2), 95% [0.00, 0.66] | predicted 0.34, observed 0.33 (n=3: 1/3), 95% [0.06, 0.79] | predicted 0.34, observed 0.00 (n=3: 0/3), 95% [0.00, 0.56] | predicted 0.34, observed 0.00 (n=3: 0/3), 95% [0.00, 0.56] |
| 0.4–0.5 | none (n=0) | predicted 0.47, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.45, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] | none (n=0) |
| 0.5–0.6 | none (n=0) | predicted 0.58, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | none (n=0) | predicted 0.58, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] |
| 0.6–0.7 | none (n=0) | none (n=0) | none (n=0) | none (n=0) |
| 0.7–0.8 | none (n=0) | none (n=0) | predicted 0.77, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] | none (n=0) |
| 0.8–0.9 | predicted 0.88, observed 1.00 (n=4: 4/4), 95% [0.51, 1.00] | predicted 0.86, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.87, observed 0.50 (n=8: 4/8), 95% [0.22, 0.78] | predicted 0.89, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] |
| 0.9–1.0 | predicted 0.95, observed 1.00 (n=6: 6/6), 95% [0.61, 1.00] | none (n=0) | predicted 0.94, observed 1.00 (n=4: 4/4), 95% [0.51, 1.00] | predicted 0.94, observed 1.00 (n=8: 8/8), 95% [0.68, 1.00] |

Disagreements (mean flagged probability and majority decision):

| Case | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| cancel-on-dismiss | 0.12 (passes) | 0.33 (passes) | 0.85 (flags) | 0.13 (passes) |
| assert-constructed-value | 0.98 (flags) | 0.50 (passes) | 0.93 (flags) | 0.94 (flags) |
| snapshot-in-t1 | 0.20 (passes) | 0.19 (passes) | 0.86 (flags) | 0.22 (passes) |
| wrong-field | 0.88 (flags) | 0.39 (passes) | 0.90 (flags) | 0.92 (flags) |
| mock-returns-mock | 0.98 (flags) | 0.12 (passes) | 0.82 (flags) | 0.98 (flags) |
| case-ec67cf | 0.29 (passes) | 0.31 (passes) | 0.86 (flags) | 0.20 (passes) |
| case-1d1de2 | 0.85 (flags) | 0.28 (passes) | 0.40 (passes) | 0.59 (flags) |
| case-7e8258 | 0.89 (flags) | 0.45 (passes) | 0.94 (flags) | 0.94 (flags) |
| case-2e7a20 | 0.33 (passes) | 0.29 (passes) | 0.76 (flags) | 0.17 (passes) |
| case-b8c208 | 0.94 (flags) | 0.19 (passes) | 0.88 (flags) | 0.96 (flags) |
| case-d8b98a | 0.37 (passes) | 0.27 (passes) | 0.90 (flags) | 0.57 (passes) |
| case-89ea7f | 0.88 (flags) | 0.28 (passes) | 0.78 (flags) | 0.89 (flags) |

### tier

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| Precision | 1.00 (n=13: 13/13), 95% [0.77, 1.00] | 1.00 (n=12: 12/12), 95% [0.76, 1.00] | 1.00 (n=12: 12/12), 95% [0.76, 1.00] | 1.00 (n=12: 12/12), 95% [0.76, 1.00] |
| True-positive rate (recall) | 0.93 (n=14: 13/14), 95% [0.69, 0.99] | 0.86 (n=14: 12/14), 95% [0.60, 0.96] | 0.86 (n=14: 12/14), 95% [0.60, 0.96] | 0.86 (n=14: 12/14), 95% [0.60, 0.96] |
| True-negative rate | 1.00 (n=30: 30/30), 95% [0.89, 1.00] | 1.00 (n=30: 30/30), 95% [0.89, 1.00] | 1.00 (n=30: 30/30), 95% [0.89, 1.00] | 1.00 (n=30: 30/30), 95% [0.89, 1.00] |
| Accuracy | 0.98 (n=44: 43/44), 95% [0.88, 1.00] | 0.95 (n=44: 42/44), 95% [0.85, 0.99] | 0.95 (n=44: 42/44), 95% [0.85, 0.99] | 0.95 (n=44: 42/44), 95% [0.85, 0.99] |
| Brier score | 0.047 (n=44), 95% [0.005, 0.119] | 0.038 (n=44), 95% [0.005, 0.078] | 0.044 (n=44), 95% [0.006, 0.095] | 0.044 (n=44), 95% [0.006, 0.091] |
| Calibration error | 0.057 (n=44), 95% [0.036, 0.100] | 0.055 (n=44), 95% [0.021, 0.095] | 0.059 (n=44), 95% [0.022, 0.103] | 0.059 (n=44), 95% [0.023, 0.102] |
| Flips over repeats | 0.00 (n=44: 0/44), 95% [0.00, 0.08] | 0.02 (n=44: 1/44), 95% [0.00, 0.12] | 0.00 (n=44: 0/44), 95% [0.00, 0.08] | 0.00 (n=44: 0/44), 95% [0.00, 0.08] |
| Mean SD of the flagged p | 0.007 (n=44) | 0.003 (n=44) | 0.004 (n=44) | 0.004 (n=44) |

| Difference (first − second) | κ | Brier | Calibration error | Accuracy | True-positive rate | True-negative rate |
|---|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0` | 0.832 (n=44), 95% [0.633, 1.000] | 0.010 (n=44), 95% [-0.052, 0.081] | 0.002 (n=44), 95% [-0.037, 0.042] | 0.023 (n=44), 95% [-0.045, 0.091] | 0.071 (n=44), 95% [-0.167, 0.312] | 0.000 (n=44), 95% [0.000, 0.000] |
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0#test-quality@2-jev` | 0.832 (n=44), 95% [0.633, 1.000] | 0.003 (n=44), 95% [-0.067, 0.080] | -0.002 (n=44), 95% [-0.044, 0.042] | 0.023 (n=44), 95% [-0.045, 0.091] | 0.071 (n=44), 95% [-0.167, 0.312] | 0.000 (n=44), 95% [0.000, 0.000] |
| `claude:claude-sonnet-5-5` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.832 (n=44), 95% [0.633, 1.000] | 0.004 (n=44), 95% [-0.062, 0.078] | -0.002 (n=44), 95% [-0.043, 0.040] | 0.023 (n=44), 95% [-0.045, 0.091] | 0.071 (n=44), 95% [-0.167, 0.312] | 0.000 (n=44), 95% [0.000, 0.000] |
| `jev:jev-1.13.0` − `jev:jev-1.13.0#test-quality@2-jev` | 1.000 (n=44), 95% [1.000, 1.000] | -0.007 (n=44), 95% [-0.020, 0.001] | -0.004 (n=44), 95% [-0.010, 0.001] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] |
| `jev:jev-1.13.0` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 1.000 (n=44), 95% [1.000, 1.000] | -0.006 (n=44), 95% [-0.018, 0.001] | -0.004 (n=44), 95% [-0.010, -0.000] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] |
| `jev:jev-1.13.0#test-quality@2-jev` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 1.000 (n=44), 95% [1.000, 1.000] | 0.001 (n=44), 95% [-0.003, 0.005] | -0.000 (n=44), 95% [-0.003, 0.002] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] |

The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.052 to 0.081 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.037 to 0.042 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.045 to 0.091 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.167 to 0.312 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.067 to 0.080 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.044 to 0.042 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.045 to 0.091 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.167 to 0.312 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.062 to 0.078 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.043 to 0.040 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.045 to 0.091 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.167 to 0.312 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.020 to 0.001 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.010 to 0.001 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.018 to 0.001 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.003 to 0.005 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.003 to 0.002 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.

Reliability of the flagged probability:

| Bin | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| 0.0–0.1 | predicted 0.03, observed 0.00 (n=29: 0/29), 95% [0.00, 0.12] | predicted 0.00, observed 0.00 (n=30: 0/30), 95% [0.00, 0.11] | predicted 0.00, observed 0.00 (n=30: 0/30), 95% [0.00, 0.11] | predicted 0.00, observed 0.00 (n=30: 0/30), 95% [0.00, 0.11] |
| 0.1–0.2 | predicted 0.19, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] | none (n=0) | none (n=0) | none (n=0) |
| 0.2–0.3 | none (n=0) | none (n=0) | none (n=0) | none (n=0) |
| 0.3–0.4 | none (n=0) | none (n=0) | predicted 0.38, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.39, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] |
| 0.4–0.5 | none (n=0) | predicted 0.46, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.40, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.44, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] |
| 0.5–0.6 | none (n=0) | none (n=0) | none (n=0) | none (n=0) |
| 0.6–0.7 | none (n=0) | predicted 0.67, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.69, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.66, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] |
| 0.7–0.8 | predicted 0.73, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.79, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.79, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.78, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] |
| 0.8–0.9 | none (n=0) | predicted 0.83, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.85, observed 1.00 (n=3: 3/3), 95% [0.44, 1.00] | predicted 0.88, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] |
| 0.9–1.0 | predicted 0.97, observed 1.00 (n=11: 11/11), 95% [0.74, 1.00] | predicted 0.95, observed 1.00 (n=8: 8/8), 95% [0.68, 1.00] | predicted 0.95, observed 1.00 (n=7: 7/7), 95% [0.65, 1.00] | predicted 0.95, observed 1.00 (n=7: 7/7), 95% [0.65, 1.00] |

Disagreements (mean flagged probability and majority decision):

| Case | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| case-e64c8b | 0.95 (flags) | 0.50 (passes) | 0.38 (passes) | 0.39 (passes) |
| case-a6f159 | 0.96 (flags) | 0.43 (passes) | 0.40 (passes) | 0.44 (passes) |
| case-9e63a6 | 0.18 (passes) | 0.67 (flags) | 0.69 (flags) | 0.66 (flags) |

### name-specificity

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| Precision | 1.00 (n=11: 11/11), 95% [0.74, 1.00] | 1.00 (n=6: 6/6), 95% [0.61, 1.00] | 1.00 (n=14: 14/14), 95% [0.78, 1.00] | 1.00 (n=14: 14/14), 95% [0.78, 1.00] |
| True-positive rate (recall) | 0.79 (n=14: 11/14), 95% [0.52, 0.92] | 0.43 (n=14: 6/14), 95% [0.21, 0.67] | 1.00 (n=14: 14/14), 95% [0.78, 1.00] | 1.00 (n=14: 14/14), 95% [0.78, 1.00] |
| True-negative rate | 1.00 (n=30: 30/30), 95% [0.89, 1.00] | 1.00 (n=30: 30/30), 95% [0.89, 1.00] | 1.00 (n=30: 30/30), 95% [0.89, 1.00] | 1.00 (n=30: 30/30), 95% [0.89, 1.00] |
| Accuracy | 0.84 (n=44: 37/44), 95% [0.71, 0.92] | 0.77 (n=44: 34/44), 95% [0.63, 0.87] | 0.75 (n=44: 33/44), 95% [0.61, 0.85] | 0.75 (n=44: 33/44), 95% [0.61, 0.85] |
| Brier score | 0.250 (n=44), 95% [0.172, 0.334] | 0.321 (n=44), 95% [0.176, 0.489] | 0.348 (n=44), 95% [0.199, 0.514] | 0.347 (n=44), 95% [0.195, 0.510] |
| Calibration error | 0.137 (n=44), 95% [0.102, 0.201] | 0.147 (n=44), 95% [0.099, 0.242] | 0.061 (n=44), 95% [0.038, 0.087] | 0.060 (n=44), 95% [0.038, 0.085] |
| Flips over repeats | 0.07 (n=44: 3/44), 95% [0.02, 0.18] | 0.07 (n=44: 3/44), 95% [0.02, 0.18] | 0.00 (n=44: 0/44), 95% [0.00, 0.08] | 0.02 (n=44: 1/44), 95% [0.00, 0.12] |
| Mean SD of the flagged p | 0.020 (n=44) | 0.009 (n=44) | 0.006 (n=44) | 0.007 (n=44) |

| Difference (first − second) | κ | Brier | Calibration error | Accuracy | True-positive rate | True-negative rate |
|---|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0` | 0.643 (n=44), 95% [0.313, 0.879] | -0.071 (n=44), 95% [-0.217, 0.044] | -0.009 (n=44), 95% [-0.067, 0.029] | 0.068 (n=44), 95% [-0.068, 0.205] | 0.357 (n=44), 95% [0.125, 0.615] | 0.000 (n=44), 95% [0.000, 0.000] |
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0#test-quality@2-jev` | 0.833 (n=44), 95% [0.637, 1.000] | -0.098 (n=44), 95% [-0.271, 0.067] | 0.077 (n=44), 95% [0.043, 0.137] | 0.091 (n=44), 95% [-0.068, 0.250] | -0.214 (n=44), 95% [-0.455, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] |
| `claude:claude-sonnet-5-5` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.833 (n=44), 95% [0.637, 1.000] | -0.096 (n=44), 95% [-0.265, 0.064] | 0.077 (n=44), 95% [0.044, 0.138] | 0.091 (n=44), 95% [-0.068, 0.250] | -0.214 (n=44), 95% [-0.455, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] |
| `jev:jev-1.13.0` − `jev:jev-1.13.0#test-quality@2-jev` | 0.506 (n=44), 95% [0.204, 0.760] | -0.027 (n=44), 95% [-0.254, 0.232] | 0.086 (n=44), 95% [0.044, 0.176] | 0.023 (n=44), 95% [-0.182, 0.205] | -0.571 (n=44), 95% [-0.842, -0.308] | 0.000 (n=44), 95% [0.000, 0.000] |
| `jev:jev-1.13.0` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.506 (n=44), 95% [0.204, 0.760] | -0.026 (n=44), 95% [-0.253, 0.235] | 0.087 (n=44), 95% [0.046, 0.176] | 0.023 (n=44), 95% [-0.182, 0.205] | -0.571 (n=44), 95% [-0.842, -0.308] | 0.000 (n=44), 95% [0.000, 0.000] |
| `jev:jev-1.13.0#test-quality@2-jev` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 1.000 (n=44), 95% [1.000, 1.000] | 0.002 (n=44), 95% [-0.010, 0.013] | 0.001 (n=44), 95% [-0.001, 0.003] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] | 0.000 (n=44), 95% [0.000, 0.000] |

The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.217 to 0.044 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.067 to 0.029 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.068 to 0.205 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.271 to 0.067 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.068 to 0.250 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.455 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.265 to 0.064 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.068 to 0.250 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.455 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.254 to 0.232 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.182 to 0.205 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.253 to 0.235 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.182 to 0.205 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.010 to 0.013 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.001 to 0.003 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.

Reliability of the flagged probability:

| Bin | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| 0.0–0.1 | predicted 0.05, observed 0.00 (n=20: 0/20), 95% [0.00, 0.16] | predicted 0.04, observed 0.00 (n=23: 0/23), 95% [0.00, 0.14] | predicted 0.03, observed 0.00 (n=28: 0/28), 95% [0.00, 0.12] | predicted 0.03, observed 0.00 (n=27: 0/27), 95% [0.00, 0.12] |
| 0.1–0.2 | predicted 0.11, observed 0.00 (n=8: 0/8), 95% [0.00, 0.32] | predicted 0.12, observed 0.33 (n=6: 2/6), 95% [0.10, 0.70] | predicted 0.10, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | predicted 0.11, observed 0.00 (n=2: 0/2), 95% [0.00, 0.66] |
| 0.2–0.3 | predicted 0.22, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] | predicted 0.24, observed 0.25 (n=4: 1/4), 95% [0.05, 0.70] | predicted 0.26, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | predicted 0.25, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] |
| 0.3–0.4 | predicted 0.35, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] | predicted 0.36, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | none (n=0) | none (n=0) |
| 0.4–0.5 | predicted 0.43, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.45, observed 1.00 (n=4: 4/4), 95% [0.51, 1.00] | none (n=0) | none (n=0) |
| 0.5–0.6 | predicted 0.56, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.54, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | none (n=0) | none (n=0) |
| 0.6–0.7 | predicted 0.60, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | none (n=0) | predicted 0.63, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.65, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] |
| 0.7–0.8 | predicted 0.77, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.76, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.73, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.75, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] |
| 0.8–0.9 | predicted 0.84, observed 1.00 (n=6: 6/6), 95% [0.61, 1.00] | none (n=0) | predicted 0.85, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.86, observed 1.00 (n=3: 3/3), 95% [0.44, 1.00] |
| 0.9–1.0 | none (n=0) | predicted 0.96, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.97, observed 1.00 (n=9: 9/9), 95% [0.70, 1.00] | predicted 0.97, observed 1.00 (n=8: 8/8), 95% [0.68, 1.00] |

Disagreements (mean flagged probability and majority decision):

| Case | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| logger-text-coupling | 0.37 (passes) | 0.36 (passes) | 0.84 (flags) | 0.85 (flags) |
| case-db1b45 | 0.23 (passes) | 0.41 (passes) | 0.76 (flags) | 0.77 (flags) |
| case-fe09f3 | 0.58 (flags) | 0.11 (passes) | 0.86 (flags) | 0.87 (flags) |
| case-ec67cf | 0.76 (flags) | 0.45 (passes) | 0.63 (flags) | 0.65 (flags) |
| case-7e8258 | 0.43 (passes) | 0.18 (passes) | 1.00 (flags) | 1.00 (flags) |
| case-fa9b3c | 0.82 (flags) | 0.27 (passes) | 0.90 (flags) | 0.87 (flags) |
| case-a07140 | 0.53 (flags) | 0.46 (passes) | 0.97 (flags) | 0.97 (flags) |
| case-e0ffb4 | 0.78 (flags) | 0.49 (passes) | 1.00 (flags) | 1.00 (flags) |

### asserts-implementation

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| Precision | 0.83 (n=6: 5/6), 95% [0.44, 0.97] | 0.75 (n=8: 6/8), 95% [0.41, 0.93] | 0.42 (n=12: 5/12), 95% [0.19, 0.68] | 0.86 (n=7: 6/7), 95% [0.49, 0.97] |
| True-positive rate (recall) | 0.50 (n=10: 5/10), 95% [0.24, 0.76] | 0.60 (n=10: 6/10), 95% [0.31, 0.83] | 0.50 (n=10: 5/10), 95% [0.24, 0.76] | 0.60 (n=10: 6/10), 95% [0.31, 0.83] |
| True-negative rate | 0.97 (n=34: 33/34), 95% [0.85, 0.99] | 0.94 (n=34: 32/34), 95% [0.81, 0.98] | 0.79 (n=34: 27/34), 95% [0.63, 0.90] | 0.97 (n=34: 33/34), 95% [0.85, 0.99] |
| Accuracy | 0.89 (n=44: 39/44), 95% [0.76, 0.95] | 0.84 (n=44: 37/44), 95% [0.71, 0.92] | 0.73 (n=44: 32/44), 95% [0.58, 0.84] | 0.86 (n=44: 38/44), 95% [0.73, 0.94] |
| Brier score | 0.179 (n=44), 95% [0.100, 0.278] | 0.274 (n=44), 95% [0.189, 0.372] | 0.433 (n=44), 95% [0.233, 0.644] | 0.236 (n=44), 95% [0.091, 0.405] |
| Calibration error | 0.156 (n=44), 95% [0.104, 0.233] | 0.155 (n=44), 95% [0.103, 0.264] | 0.189 (n=44), 95% [0.102, 0.329] | 0.117 (n=44), 95% [0.071, 0.221] |
| Flips over repeats | 0.02 (n=44: 1/44), 95% [0.00, 0.12] | 0.05 (n=44: 2/44), 95% [0.01, 0.15] | 0.00 (n=44: 0/44), 95% [0.00, 0.08] | 0.02 (n=44: 1/44), 95% [0.00, 0.12] |
| Mean SD of the flagged p | 0.018 (n=44) | 0.008 (n=44) | 0.005 (n=44) | 0.012 (n=44) |

| Difference (first − second) | κ | Brier | Calibration error | Accuracy | True-positive rate | True-negative rate |
|---|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0` | 0.492 (n=44), 95% [0.059, 0.808] | -0.095 (n=44), 95% [-0.146, -0.042] | 0.001 (n=44), 95% [-0.122, 0.092] | 0.045 (n=44), 95% [-0.045, 0.136] | -0.100 (n=44), 95% [-0.562, 0.333] | 0.029 (n=44), 95% [0.000, 0.094] |
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0#test-quality@2-jev` | 0.321 (n=44), 95% [-0.013, 0.616] | -0.253 (n=44), 95% [-0.431, -0.098] | -0.032 (n=44), 95% [-0.170, 0.079] | 0.159 (n=44), 95% [0.045, 0.295] | 0.000 (n=44), 95% [-0.400, 0.417] | 0.176 (n=44), 95% [0.061, 0.314] |
| `claude:claude-sonnet-5-5` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.730 (n=44), 95% [0.337, 1.000] | -0.057 (n=44), 95% [-0.160, 0.033] | 0.039 (n=44), 95% [-0.067, 0.113] | 0.023 (n=44), 95% [-0.045, 0.091] | -0.100 (n=44), 95% [-0.455, 0.250] | 0.000 (n=44), 95% [0.000, 0.000] |
| `jev:jev-1.13.0` − `jev:jev-1.13.0#test-quality@2-jev` | 0.488 (n=44), 95% [0.154, 0.760] | -0.159 (n=44), 95% [-0.314, -0.016] | -0.033 (n=44), 95% [-0.162, 0.085] | 0.114 (n=44), 95% [0.000, 0.227] | 0.100 (n=44), 95% [0.000, 0.333] | 0.147 (n=44), 95% [0.000, 0.297] |
| `jev:jev-1.13.0` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.759 (n=44), 95% [0.421, 1.000] | 0.038 (n=44), 95% [-0.065, 0.133] | 0.038 (n=44), 95% [-0.079, 0.144] | -0.023 (n=44), 95% [-0.091, 0.045] | 0.000 (n=44), 95% [-0.286, 0.286] | -0.029 (n=44), 95% [-0.094, 0.000] |
| `jev:jev-1.13.0#test-quality@2-jev` − `cascade:jev-1.13.0,claude-sonnet-5-5` | 0.539 (n=44), 95% [0.202, 0.808] | 0.196 (n=44), 95% [0.072, 0.341] | 0.071 (n=44), 95% [-0.001, 0.151] | -0.136 (n=44), 95% [-0.250, -0.045] | -0.100 (n=44), 95% [-0.333, 0.000] | -0.176 (n=44), 95% [-0.314, -0.061] |

The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.122 to 0.092 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.045 to 0.136 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.562 to 0.333 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from 0.000 to 0.094 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.170 to 0.079 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.400 to 0.417 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.160 to 0.033 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.067 to 0.113 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.045 to 0.091 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.455 to 0.250 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from -0.162 to 0.085 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.227 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.333 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0` and `jev:jev-1.13.0#test-quality@2-jev` runs from 0.000 to 0.297 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the Brier difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.065 to 0.133 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.079 to 0.144 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.091 to 0.045 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.286 to 0.286 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `jev:jev-1.13.0` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.094 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the calibration error difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.001 to 0.151 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `jev:jev-1.13.0#test-quality@2-jev` and `cascade:jev-1.13.0,claude-sonnet-5-5` runs from -0.333 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.

Reliability of the flagged probability:

| Bin | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| 0.0–0.1 | predicted 0.07, observed 0.00 (n=11: 0/11), 95% [0.00, 0.26] | predicted 0.07, observed 0.00 (n=7: 0/7), 95% [0.00, 0.35] | predicted 0.06, observed 0.15 (n=20: 3/20), 95% [0.05, 0.36] | predicted 0.06, observed 0.15 (n=20: 3/20), 95% [0.05, 0.36] |
| 0.1–0.2 | predicted 0.14, observed 0.06 (n=17: 1/17), 95% [0.01, 0.27] | predicted 0.15, observed 0.17 (n=6: 1/6), 95% [0.03, 0.56] | predicted 0.13, observed 0.10 (n=10: 1/10), 95% [0.02, 0.40] | predicted 0.12, observed 0.00 (n=9: 0/9), 95% [0.00, 0.30] |
| 0.2–0.3 | predicted 0.26, observed 0.00 (n=4: 0/4), 95% [0.00, 0.49] | predicted 0.24, observed 0.09 (n=11: 1/11), 95% [0.02, 0.38] | none (n=0) | predicted 0.23, observed 0.20 (n=5: 1/5), 95% [0.04, 0.62] |
| 0.3–0.4 | predicted 0.35, observed 0.50 (n=4: 2/4), 95% [0.15, 0.85] | predicted 0.33, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | predicted 0.35, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] | predicted 0.31, observed 0.00 (n=2: 0/2), 95% [0.00, 0.66] |
| 0.4–0.5 | predicted 0.45, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.45, observed 0.25 (n=12: 3/12), 95% [0.09, 0.53] | none (n=0) | none (n=0) |
| 0.5–0.6 | predicted 0.50, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.57, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] | none (n=0) | predicted 0.50, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] |
| 0.6–0.7 | predicted 0.60, observed 1.00 (n=3: 3/3), 95% [0.44, 1.00] | predicted 0.68, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | none (n=0) | none (n=0) |
| 0.7–0.8 | predicted 0.72, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | predicted 0.78, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | predicted 0.75, observed 0.00 (n=2: 0/2), 95% [0.00, 0.66] | predicted 0.72, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] |
| 0.8–0.9 | predicted 0.86, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | predicted 0.83, observed 1.00 (n=2: 2/2), 95% [0.34, 1.00] | predicted 0.87, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | none (n=0) |
| 0.9–1.0 | predicted 0.96, observed 1.00 (n=1: 1/1), 95% [0.21, 1.00] | none (n=0) | predicted 0.95, observed 0.56 (n=9: 5/9), 95% [0.27, 0.81] | predicted 0.97, observed 0.83 (n=6: 5/6), 95% [0.44, 0.97] |

Disagreements (mean flagged probability and majority decision):

| Case | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| retry-backoff | 0.28 (passes) | 0.44 (passes) | 0.87 (flags) | 0.30 (passes) |
| case-574e3a | 0.25 (passes) | 0.45 (passes) | 0.91 (flags) | 0.26 (passes) |
| case-db1b45 | 0.45 (passes) | 0.68 (flags) | 0.98 (flags) | 0.98 (flags) |
| case-fe09f3 | 0.38 (passes) | 0.50 (flags) | 0.19 (passes) | 0.20 (passes) |
| case-a4d740 | 0.27 (passes) | 0.45 (passes) | 0.94 (flags) | 0.50 (passes) |
| case-9e63a6 | 0.18 (passes) | 0.55 (flags) | 0.35 (passes) | 0.20 (passes) |
| case-7bbfdf | 0.60 (flags) | 0.40 (passes) | 0.35 (passes) | 0.72 (flags) |
| case-5e44c5 | 0.32 (passes) | 0.44 (passes) | 0.74 (flags) | 0.27 (passes) |
| case-1d1de2 | 0.35 (passes) | 0.45 (passes) | 0.93 (flags) | 0.32 (passes) |
| case-e88fb3 | 0.50 (passes) | 0.68 (flags) | 0.97 (flags) | 0.97 (flags) |
| case-387fa2 | 0.60 (flags) | 0.49 (passes) | 0.06 (passes) | 0.05 (passes) |
| case-bea4db | 0.17 (passes) | 0.41 (passes) | 0.76 (flags) | 0.20 (passes) |

### Usage

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` | `jev:jev-1.13.0#test-quality@2-jev` | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|---|---|---|
| Request latency p50 / p95 | 3808 / 5741 ms (n=132) | 184 / 276 ms (n=132) | 191 / 268 ms (n=132) | 200 / 3126 ms (n=188) |
| Case latency p50 / p95 | 3808 / 5741 ms (n=132) | 184 / 276 ms (n=132) | 191 / 268 ms (n=132) | 218 / 3510 ms (n=132) |
| Backend latency p50 / p95 | 3146 / 4604 ms (n=132) | none (n=0) | none (n=0) | 2015 / 3201 ms (n=56) |
| Input tokens per case | 3151 (n=132) | 782 (n=132) | 1739 (n=132) | 2777 (n=132) |
| Output tokens per case | 401 (n=132) | 97 (n=132) | 202 (n=132) | 275 (n=132) |
| Cost per case (USD) | 0.00523 (n=132) | 0.00003 (n=132) | 0.00007 (n=132) | 0.00135 (n=132) |
| Cost per 1,000 judgments (USD) | 1.3220 (n=522) | 0.0083 (n=522) | 0.0185 (n=522) | 0.3422 (n=522) |

### Escalations to Claude

Answered cases, per repeat, whose question Jev sent to Claude; each case's cost and latency above sum both calls.

| Question | `cascade:jev-1.13.0,claude-sonnet-5-5` |
|---|---|
| fails-if-broken | 0.25 (n=126: 32/126), 95% [0.19, 0.34] |
| tier | 0.00 (n=132: 0/132), 95% [0.00, 0.03] |
| name-specificity | 0.00 (n=132: 0/132), 95% [0.00, 0.03] |
| asserts-implementation | 0.20 (n=132: 26/132), 95% [0.14, 0.27] |
| Any question | 0.42 (n=132: 56/132), 95% [0.34, 0.51] |

# Judge benchmark: comments

- Dataset `comments`, question set `comments@1`, hash `c97d0744bcff4373d7783c41876808f8b2e3606d675c8c4766f8b37a06e8fb2d`
- Cases: 80, 3 unlabelled; split: tune 32, report 45
- Labellers: person 0, agent 77, seed 0
- Run: 77 cases, 3 repeats, decision threshold 0.50; swiftgate 0.1.0, started 2026-09-30T23:20:06Z

| Arm | Backend | Requested model | Served model | Asks | Scored against |
|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` | claude | claude-sonnet-5-5 | claude-sonnet-5-5 | comments@1 | comments@1 |
| `jev:jev-1.13.0` | jev | jev-1.13.0 | jev-1.13.0 | comments@1 | comments@1 |

Every number reads the report split only. A rate shows its count out of n with a Wilson 95% interval; Brier, calibration error, κ and each difference show a paired bootstrap 95% interval (2000 resamples, seed 20260930).

## Person labels

No person labels: every label in this dataset is an agent's or a seed's, so this view has no numbers. The all-labels view below is not a person-labelled result.

## All labels

Report-split cases: 45.

### loses-fact

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` |
|---|---|---|
| Precision | 0.29 (n=17: 5/17), 95% [0.13, 0.53] | 0.33 (n=15: 5/15), 95% [0.15, 0.58] |
| True-positive rate (recall) | 1.00 (n=5: 5/5), 95% [0.57, 1.00] | 1.00 (n=5: 5/5), 95% [0.57, 1.00] |
| True-negative rate | 0.68 (n=38: 26/38), 95% [0.53, 0.81] | 0.74 (n=38: 28/38), 95% [0.58, 0.85] |
| Accuracy | 0.72 (n=43: 31/43), 95% [0.57, 0.83] | 0.79 (n=43: 34/43), 95% [0.65, 0.89] |
| Brier score | 0.358 (n=43), 95% [0.274, 0.442] | 0.354 (n=43), 95% [0.283, 0.425] |
| Calibration error | 0.315 (n=43), 95% [0.244, 0.397] | 0.380 (n=43), 95% [0.325, 0.431] |
| Flips over repeats | 0.09 (n=43: 4/43), 95% [0.04, 0.22] | 0.09 (n=43: 4/43), 95% [0.04, 0.22] |
| Mean SD of the flagged p | 0.022 (n=43) | 0.008 (n=43) |

| Difference (first − second) | κ | Brier | Calibration error | Accuracy | True-positive rate | True-negative rate |
|---|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0` | 0.404 (n=43), 95% [0.112, 0.653] | 0.005 (n=43), 95% [-0.080, 0.096] | -0.065 (n=43), 95% [-0.122, -0.004] | -0.070 (n=43), 95% [-0.209, 0.070] | 0.000 (n=43), 95% [0.000, 0.000] | -0.053 (n=43), 95% [-0.231, 0.128] |

The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.080 to 0.096 and crosses 0: these 43 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.209 to 0.070 and crosses 0: these 43 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from 0.000 to 0.000 and crosses 0: these 43 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.231 to 0.128 and crosses 0: these 43 cases can't tell the 2 arms apart on it.

Reliability of the flagged probability:

| Bin | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` |
|---|---|---|
| 0.0–0.1 | predicted 0.08, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | none (n=0) |
| 0.1–0.2 | predicted 0.15, observed 0.00 (n=3: 0/3), 95% [0.00, 0.56] | none (n=0) |
| 0.2–0.3 | predicted 0.23, observed 0.00 (n=10: 0/10), 95% [0.00, 0.28] | predicted 0.26, observed 0.00 (n=7: 0/7), 95% [0.00, 0.35] |
| 0.3–0.4 | predicted 0.33, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | predicted 0.35, observed 0.00 (n=11: 0/11), 95% [0.00, 0.26] |
| 0.4–0.5 | predicted 0.41, observed 0.00 (n=10: 0/10), 95% [0.00, 0.28] | predicted 0.45, observed 0.00 (n=10: 0/10), 95% [0.00, 0.28] |
| 0.5–0.6 | predicted 0.55, observed 0.00 (n=6: 0/6), 95% [0.00, 0.39] | predicted 0.56, observed 0.00 (n=7: 0/7), 95% [0.00, 0.35] |
| 0.6–0.7 | predicted 0.66, observed 0.45 (n=11: 5/11), 95% [0.21, 0.72] | predicted 0.65, observed 0.25 (n=4: 1/4), 95% [0.05, 0.70] |
| 0.7–0.8 | predicted 0.73, observed 0.00 (n=1: 0/1), 95% [0.00, 0.79] | none (n=0) |
| 0.8–0.9 | none (n=0) | predicted 0.83, observed 1.00 (n=4: 4/4), 95% [0.51, 1.00] |
| 0.9–1.0 | none (n=0) | none (n=0) |

Disagreements (mean flagged probability and majority decision):

| Case | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` |
|---|---|---|
| case-0303c5 | 0.63 (flags) | 0.31 (passes) |
| case-074c1f | 0.40 (passes) | 0.50 (flags) |
| case-082803 | 0.53 (flags) | 0.26 (passes) |
| case-0f0620 | 0.33 (passes) | 0.56 (flags) |
| case-12ed08 | 0.58 (flags) | 0.39 (passes) |
| case-15e38c | 0.45 (passes) | 0.65 (flags) |
| case-273fcd | 0.57 (flags) | 0.41 (passes) |
| case-346de8 | 0.42 (passes) | 0.55 (flags) |
| case-8b989d | 0.73 (flags) | 0.37 (passes) |
| case-94f09b | 0.70 (flags) | 0.26 (passes) |
| case-b3ab21 | 0.20 (passes) | 0.56 (flags) |
| case-eb015d | 0.63 (flags) | 0.36 (passes) |

### right-size

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` |
|---|---|---|
| Precision | 0.12 (n=8: 1/8), 95% [0.02, 0.47] | 0.09 (n=11: 1/11), 95% [0.02, 0.38] |
| True-positive rate (recall) | 0.50 (n=2: 1/2), 95% [0.09, 0.91] | 0.50 (n=2: 1/2), 95% [0.09, 0.91] |
| True-negative rate | 0.83 (n=42: 35/42), 95% [0.69, 0.92] | 0.76 (n=42: 32/42), 95% [0.61, 0.87] |
| Accuracy | 0.84 (n=44: 37/44), 95% [0.71, 0.92] | 0.75 (n=44: 33/44), 95% [0.61, 0.85] |
| Brier score | 0.244 (n=44), 95% [0.166, 0.331] | 0.321 (n=44), 95% [0.253, 0.408] |
| Calibration error | 0.246 (n=44), 95% [0.186, 0.318] | 0.314 (n=44), 95% [0.269, 0.390] |
| Flips over repeats | 0.09 (n=44: 4/44), 95% [0.04, 0.21] | 0.07 (n=44: 3/44), 95% [0.02, 0.18] |
| Mean SD of the flagged p | 0.030 (n=44) | 0.009 (n=44) |

| Difference (first − second) | κ | Brier | Calibration error | Accuracy | True-positive rate | True-negative rate |
|---|---|---|---|---|---|---|
| `claude:claude-sonnet-5-5` − `jev:jev-1.13.0` | 0.133 (n=44), 95% [-0.179, 0.471] | -0.078 (n=44), 95% [-0.162, 0.006] | -0.068 (n=44), 95% [-0.148, -0.016] | 0.091 (n=44), 95% [-0.068, 0.250] | 0.000 (n=44), 95% [0.000, 0.000] | 0.071 (n=44), 95% [-0.098, 0.233] |

The 95% interval of the Brier difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.162 to 0.006 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the accuracy difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.068 to 0.250 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-positive rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from 0.000 to 0.000 and crosses 0: these 44 cases can't tell the 2 arms apart on it.
The 95% interval of the true-negative rate difference between `claude:claude-sonnet-5-5` and `jev:jev-1.13.0` runs from -0.098 to 0.233 and crosses 0: these 44 cases can't tell the 2 arms apart on it.

Reliability of the flagged probability:

| Bin | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` |
|---|---|---|
| 0.0–0.1 | predicted 0.09, observed 0.00 (n=3: 0/3), 95% [0.00, 0.56] | none (n=0) |
| 0.1–0.2 | predicted 0.15, observed 0.00 (n=14: 0/14), 95% [0.00, 0.22] | predicted 0.17, observed 0.11 (n=9: 1/9), 95% [0.02, 0.43] |
| 0.2–0.3 | predicted 0.21, observed 0.11 (n=9: 1/9), 95% [0.02, 0.43] | predicted 0.25, observed 0.00 (n=7: 0/7), 95% [0.00, 0.35] |
| 0.3–0.4 | predicted 0.35, observed 0.00 (n=6: 0/6), 95% [0.00, 0.39] | predicted 0.35, observed 0.00 (n=13: 0/13), 95% [0.00, 0.23] |
| 0.4–0.5 | predicted 0.40, observed 0.00 (n=4: 0/4), 95% [0.00, 0.49] | predicted 0.47, observed 0.00 (n=4: 0/4), 95% [0.00, 0.49] |
| 0.5–0.6 | predicted 0.51, observed 0.00 (n=3: 0/3), 95% [0.00, 0.56] | predicted 0.55, observed 0.00 (n=9: 0/9), 95% [0.00, 0.30] |
| 0.6–0.7 | predicted 0.64, observed 0.20 (n=5: 1/5), 95% [0.04, 0.62] | predicted 0.60, observed 0.50 (n=2: 1/2), 95% [0.09, 0.91] |
| 0.7–0.8 | none (n=0) | none (n=0) |
| 0.8–0.9 | none (n=0) | none (n=0) |
| 0.9–1.0 | none (n=0) | none (n=0) |

Disagreements (mean flagged probability and majority decision):

| Case | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` |
|---|---|---|
| case-0303c5 | 0.15 (passes) | 0.53 (flags) |
| case-15e38c | 0.62 (flags) | 0.36 (passes) |
| case-6d4b47 | 0.70 (flags) | 0.37 (passes) |
| case-8e29f0 | 0.35 (passes) | 0.60 (flags) |
| case-94f09b | 0.67 (flags) | 0.37 (passes) |
| case-98f528 | 0.20 (passes) | 0.58 (flags) |
| case-99a3f6 | 0.52 (flags) | 0.49 (passes) |
| case-9c5063 | 0.35 (passes) | 0.57 (flags) |
| case-a85e6a | 0.18 (passes) | 0.55 (flags) |
| case-b57aa5 | 0.33 (passes) | 0.54 (flags) |
| case-b7e45c | 0.18 (passes) | 0.58 (flags) |
| case-c717c8 | 0.50 (flags) | 0.32 (passes) |
| case-ca3116 | 0.20 (passes) | 0.54 (flags) |

### Usage

| Metric | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0` |
|---|---|---|
| Request latency p50 / p95 | 2527 / 4199 ms (n=135) | 181 / 243 ms (n=135) |
| Case latency p50 / p95 | 2527 / 4199 ms (n=135) | 181 / 243 ms (n=135) |
| Backend latency p50 / p95 | 2355 / 3663 ms (n=135) | none (n=0) |
| Input tokens per case | 2527 (n=135) | 468 (n=135) |
| Output tokens per case | 216 (n=135) | 39 (n=135) |
| Cost per case (USD) | 0.00327 (n=135) | 0.00002 (n=135) |
| Cost per 1,000 judgments (USD) | 1.6894 (n=261) | 0.0102 (n=261) |
