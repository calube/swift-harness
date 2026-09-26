# Handoff: first eval round, the parts that are stable today

<!-- RESUME
State (2026-09-26): DONE, merged on main at 53644b5. Runner spike, rule corpora, thin runner and review.js orchestration tests landed; results under evals/results/2026-09-25-*.
Next action: the routing round in docs/handoffs/2026-09-26-evals-routing-foundation.md.
-->

## Scope

The eval areas that don't depend on work the sub-project 2 plan still has in flight:

| Area | What to build | Where |
|---|---|---|
| Rule corpora | planted, near-miss and clean cases for the Swift code rules and for `prose`, `docs-lint`, `design-lint`, `plan-lint`, `evidence check`, plus a runner | `evals/corpora/`, `evals/runner/` |
| Workflow orchestration | the stand-in agent cases in [`components.md`](../../evals/components.md#workflows) that the existing workflow tests don't cover yet | new `tests/*_orchestration_test.mjs` files |
| Skill routing | should-trigger and near-miss prompts for the 11 skills | `evals/cases/routing/` |
| Foundation skills | behaviour cases for `tdd`, `architecture`, `review`, `test-gate`, `validate`, `comment-audit` | `evals/cases/skills/` |
| Review agents | seeded-defect and clean diffs for `concurrency`, `architecture`, `test-quality`, `api-errors`, `swiftui`, and the `verifier` set | `evals/cases/agents/` |

Out of scope until later waves land: design agents and the `design` and `plan` skills (wave 22
recalibrates their prompts), `bootstrap` and `status` (paths move in wave 24), `guard-conformance`
(needs the hook decision log, a plan task), and `task-lift`.

## First steps

1. **Spike the runner** before building any case set. Write 1 routing case and 1 `tdd` case under
   `evals/cases/`. Run each with `claude plugin eval . --runs 1 --max-cost-usd 2`. Find out, and
   write down in `evals/results/`:
   - whether the Bash sandbox lets `swift build`, `swift test` and `bin/swiftgate` run;
   - whether a scaffold script can copy `examples/SampleApp` into the run's workspace;
   - whether the `trace` target shows `Skill` and `Agent` calls in a form a `regex` grader can match.

   If the sandbox blocks Swift builds, the `tdd`, `test-gate` and `validate` cases use a thin runner
   around `claude -p` instead ([`design.md`](../../evals/design.md#runner)). Stop and tell the user
   which way it went before building more.
2. **Rule corpora and runner.** No model calls. Start with `prose` and the `det.*` and `arch.*`
   rules, since their labels are simplest. Report recall and false-positive rate per rule.
3. **Workflow orchestration.** Read `tests/design_research_workflow_test.mjs`,
   `tests/design_review_workflow_test.mjs` and `tests/review_workflow_test.mjs` first. They already
   stub agents. List which cases in [`components.md`](../../evals/components.md#workflows) they
   cover and add only the missing ones. Each new test must fail on a broken workflow first (the
   red-first invariant in [`AGENTS.md`](../../AGENTS.md)).
4. **Skill routing.** 5 should-trigger and 5 near-miss prompts per skill, 2 paraphrases each, split
   60/40. Run 3 trials. Report per-skill precision and recall on the 40.
5. **Review agents,** then **Foundation skills.** Seeded diffs on `examples/SampleApp` copies.
   Each set gets its clean controls. `comment-audit` and `verifier` need a person's labels, so
   draft the cases and ask the user to label them.

## Budget

Until the user sets one: `--max-cost-usd 10` per run, and ask before any run over that. Record the
cost of every run in its summary, so the next handoff can set a real budget from data.

## Merge hazards

- Wave 24 rewrites workflow and agent paths in `tests/*.mjs`. New orchestration test files need
  the same rewrite. Merge this branch before wave 24, or rebase onto it and move the paths.
- The repo root stops being the plugin root at wave 24. See the layout note in
  [`runbook.md`](../../evals/runbook.md#layout).

## Kickoff prompt

> You are the eval operator for swift-harness, not an observer. Read
> `docs/handoffs/2026-09-25-evals-foundation.md` and `evals/runbook.md`, and follow the runbook's
> operator role: run the evals, check that the evals themselves work, fix them where they don't,
> and end with its report. Work in the `../swift-harness-evals` worktree on branch
> `evals-foundation`. Do the first step (the runner spike) and report what you found before
> building case sets.
