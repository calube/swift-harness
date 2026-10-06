# Evals

Evals measure the swift-harness plugin and `swiftgate` from the outside: with a real agent
driving, across many cases and repeated trials, and graded against something the harness didn't
produce.

**Status:** the runners, the cases and 25 dated result folders exist. Every suite but `task-lift`
has a recorded run, most of them 1 trial per case. Read each number below with its sample size.

## Why evals, when the gate already tests itself

`swiftgate`'s own tests, `self-test` and `calibrate` prove that each check works on its fixture.
The [end-to-end report](../docs/e2e-report.md) proves the whole plugin works on 1 app. Neither
answers the 2 questions this directory exists for:

1. **Does the harness work as designed when a real agent drives it?** Every invariant in
   [`AGENTS.md`](../AGENTS.md), every hook in [`hooks.md`](../plugin/docs/hooks.md) and every
   skill contract, across many tasks and trials.
2. **Does the harness make the work better, and at what cost?** Compared with the same model on
   the same tasks without the plugin.

Each run ends in error analysis: a person reads the failures, names a cause for each, and every
cause becomes a fix, a new seed or a documented limit.

## Ground rules

- **Grade against an independent oracle.** `swiftgate`'s verdict can't be the only oracle for
  `swiftgate`. Suites grade against labels by construction, hidden tests, pinned source or a
  person.
- **Keep the gate the gate.** The runner calls `swiftgate --json` and compares rule ids. It never
  re-implements a check.
- **Prove the grader first.** A grader must pass a known-good output and fail a known-bad output
  before its numbers count.

## Suites and results

| Suite | Question | Cases today | Latest recorded result |
|---|---|---|---|
| `checker-accuracy` | Does `swiftgate` flag what it should and nothing else? | 104 corpus cases: `prose` 36, `det.*` lint 41, `arch.*` 27 | Positive recall 12/12, 21/21 and 13/14; no model calls ([corpus](results/2026-09-25-corpus/summary.md)) |
| `guard-conformance` | Do the hooks decide as documented? | 93 hook payloads, 6 live sessions | Payloads, 51 at the recorded run (the corpus now has 93, not re-scored): every deny and control held, 12 of 21 evasions caught ([no-model](results/2026-09-26-no-model-suites/summary.md)). Live: 6 of 6 pass, 1 trial each ([live](results/2026-09-26-live-guards-faults/summary.md)) |
| `failure-modes` | When the environment breaks, does the harness say BLOCKED, not GREEN? | 14 injected faults (3 controls), 3 live sessions | 10 of 11 passed on the first run; the miss was a mismatched Xcode pin ([no-model](results/2026-09-26-no-model-suites/summary.md)). Live: 3 of 3 |
| `skill-routing` | Does the right skill load, and stay quiet otherwise? | 421 requests across 13 skills | Precision 1.00 on every held-out set. On each skill's latest held-out set, recall runs from 0.93 to 1.00 ([round 4](results/2026-09-26-routing-round-4/summary.md), [ship and build](results/2026-09-27-routing-ship-build-heldout/summary.md)) |
| `review-accuracy` | Do the review agents find seeded defects without inventing others? | 5 seeded diffs | 5 of 5 verdicts right, 0 invented findings, 1 trial; suite frozen ([confirm](results/2026-09-27-review-accuracy-confirm/summary.md)) |
| `design-honesty` | Does `/swift-harness:design` keep unproven claims out of Decision? | 1 session case | 1 run: a probe refuted an invented API and Decision never cited it ([e2e report](../docs/e2e-report.md#a-probe-refutes-an-invented-api)) |
| `task-lift` | Does an agent with the harness ship better Swift than one without? | 3 skill sessions, each run with and without the plugin | Not run as a suite. On 2 small `tdd` tasks both arms passed ([tdd](results/2026-09-27-tdd-latest-fact-wins/summary.md)). On 1 `test-gate` task, 1.00 with the plugin against 0.50 without ([changelog](CHANGELOG.md)) |

The Xcode-pin miss in `failure-modes` led to a gate change: `doctor.xcode-pin` now BLOCKS the T1
and simulator tiers on a mismatch, and the case expects BLOCKED. No recorded run has re-scored it
yet.

Other recorded runs:

- **Judge benchmark.** Sonnet, Jev and the Jev-to-Claude cascade on 66 labelled tests, 3 repeats.
  The cascade matched Claude at about a quarter of the cost, with 10 positives per question
  ([summary](results/2026-09-30-judge-benchmark/summary.md)).
- **Jev end to end.** A live check of the Jev backend, including an unreachable host and a bad
  key ([README](results/2026-10-03-jev-live-end-to-end/README.md)).
- **Brownfield trials.** One-shot `swiftgate run` attempts on 2 open-source repositories, with
  each attempt's findings (`results/2026-10-04-brownfield-*`).

[`CHANGELOG.md`](CHANGELOG.md) logs every change to cases and graders, with numbers before and
after.

## How to run

The runners are Node scripts with no dependencies. The header of each script documents its flags.

```sh
node evals/runner/corpus.mjs evals/corpora/prose evals/corpora/lint evals/corpora/arch --out <dir>
node evals/runner/hooks.mjs evals/corpora/hooks.json --out <dir>
node evals/runner/faults.mjs --out <dir>
node evals/runner/session.mjs evals/sessions/skills/tdd/* --runs 3 --max-cost-usd <cap> --out <dir>
```

The first 3 make no model calls. Session runs and routing cases call a model and cost money. The
[runbook](runbook.md) covers pins, cost caps, routing runs through `claude plugin eval`, and how
to write up a result.

## Files

| Path | What it holds |
|---|---|
| [`suites.md`](suites.md) | The 7 suites: question, cases, grader, metrics and pass bar |
| [`components.md`](components.md) | Evals per skill, agent, workflow and rule |
| [`design.md`](design.md) | Conditions, trials, graders, metrics, the run record and cost |
| [`research.md`](research.md) | What published eval practice says, and what this design takes from it |
| [`apps.md`](apps.md) | The eval apps and the task format |
| [`runbook.md`](runbook.md) | Rules, layout and steps for any eval session |
| `cases/` | `claude plugin eval` cases: skill routing |
| `sessions/` | Thin-runner cases for work that builds or tests Swift |
| `corpora/`, `faults/` | Rule corpora, hook payloads and injected faults |
| `runner/`, `scaffold/` | The runners and the scratch-app scaffolds |
| `results/` | 1 folder per run, with a summary; raw transcripts stay out of git |

## Open questions

- **Budget for `task-lift`.** A full pass at 20 tasks, 3 trials and 5 conditions is 300 agent
  runs. [`design.md`](design.md#cost) estimates it; a cap comes before the first run.
- **Who labels.** The judge benchmark's labels came from an Opus agent, not a person, and may
  favour Claude. Labelling a sample by hand needs an owner.
- **A clean control for `review-accuracy`.** Its only clean case turned out to hold a real race,
  so the suite has no clean control until a new one replaces it.
