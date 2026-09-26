# Evals

Evals for the swift-harness plugin and `swiftgate`. Status: planning. No suite runs yet.

## Why evals, when the gate already tests itself

The gate's unit tests, `swiftgate self-test` and `calibrate design` prove that each check works on
its own fixture. The acceptance runs in [`docs/e2e-report.md`](../docs/e2e-report.md) prove the
whole plugin works once, on 1 app, with a person watching. Neither answers the 2 questions this
directory exists for:

1. **Does the harness work as designed when a real agent drives it?** Every invariant in
   [`AGENTS.md`](../AGENTS.md), every hook in [`docs/hooks.md`](../docs/hooks.md), every skill
   contract, measured across many tasks and repeated trials, not 1 run.
2. **Does the harness make the work better, and at what cost?** Compared with the same model and
   the same tasks without the plugin, and with each component turned off in turn.

The first question keeps the harness honest. The second tells us what to change next: an eval that
only reports a pass rate doesn't make the harness better. Each suite ends in a list of failures a
person has read and sorted into causes, and each cause becomes a fix, a new seed, or a documented
limit.

## Objectives

- **Prove conformance.** For each rule, guard, hook and skill, measure whether it does what the
  standards and designs say, in a live session. The bar for the guards is 0 escapes.
- **Measure lift.** Report clean-resolve rate, violations per task, tokens and wall time with the
  plugin on and off, on the same tasks and trials.
- **Find what to fix.** Every run ends in error analysis: read the failing transcripts, name the
  failure, count it. The counts pick the next harness change.
- **Stay independent of the thing under test.** `swiftgate`'s verdict can't be the only oracle for
  `swiftgate`. Every suite grades against something the harness didn't produce: labels by
  construction, hidden tests, pinned source, or a person.
- **Keep the gate the gate.** The eval runner calls `swiftgate` and reads its JSON. It never
  re-implements a check (see the first invariant in [`AGENTS.md`](../AGENTS.md)). A check the evals
  need that `swiftgate` lacks becomes a `gate/` task.

## When to run

After wave 27 of the sub-project 2 plan
([`nonexistent-api-run-refutes-claim`](../docs/plans/2026-09-25-design-plan-workflows-plan.md#nonexistent-api-run-refutes-claim)).
By then the plugin installs through the marketplace, lives under `plugin/`, and has refuted 1
fabricated claim in a real run. The `design-honesty` suite extends that single run into a dataset.

Order of first runs, cheapest first, each one a precondition for trusting the next:

1. `checker-accuracy`: no model calls. It confirms the oracle the other suites lean on.
2. `failure-modes` and `guard-conformance`: short live sessions.
3. `skill-routing`.
4. `task-lift` on `SampleApp` only, 3 trials, plugin on and off. This is the first baseline.
5. `design-honesty` and `review-accuracy`.
6. `task-lift` across the full app set, with ablations.

Wave 28 (`sampleapp-standard-design-to-plan`) needs a person at the keyboard, so it can run next to
steps 1 to 3.

## Files

| File | What it holds |
|---|---|
| [`research.md`](research.md) | What published eval practice says (Anthropic, LangChain, Vercel, SWE-bench and others) and what we take from each |
| [`design.md`](design.md) | How the evals work: conditions, trials, graders, metrics, the run record, cost, the error-analysis loop |
| [`suites.md`](suites.md) | The 7 suites: question, cases, grader, metrics and pass bar for each |
| [`components.md`](components.md) | Evals per skill, agent, workflow and rule, on fixed inputs |
| [`apps.md`](apps.md) | The eval apps and the task format |

Planned, not yet created: `evals/tasks/` (task fixtures), `evals/runner/` (the harness that runs
trials and grades them), `evals/results/` (1 summary per run; transcripts stay out of git).

## Decisions still open

- **Runner.** Use `claude plugin eval` if it can express the suites, or write a thin runner around
  `claude -p --output-format stream-json`. [`design.md`](design.md#runner) has the trade-off.
- **Where the runner lives.** `evals/runner/` in this repo, or as `swiftgate eval` in `gate/`. The
  runner drives agents and grades results, which is not a gate check, so this plan puts it outside
  `gate/`.
- **Budget.** A full `task-lift` pass at 20 tasks, 3 trials, 5 conditions is 300 agent runs.
  [`design.md`](design.md#cost) estimates it. We need a cap before the first full run.
- **Who labels.** The rubric judge and `review-accuracy` need a person to label a sample. The
  labelling time needs an owner.
