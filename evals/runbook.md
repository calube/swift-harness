# Eval runbook

How to work on the evals in any session: build cases, run them, record results. Read
[`README.md`](README.md) for why, [`design.md`](design.md) for method, and [`suites.md`](suites.md)
and [`components.md`](components.md) for what to measure. The dated handoff for the current round
lives in `docs/handoffs/` and names the scope.

## Your role: operator

You run the evals and you own their quality. Measuring the harness is half the job. The other half
is checking that the evals measure it well, and fixing them when they don't. Every session ends
with a verdict on the evals themselves, not only on the harness.

### Check the evals every session

| Check | How | An eval fails the check when |
|---|---|---|
| Graders tell good from bad | run each grader on a known-good and a known-bad output | it passes both, or fails both |
| Cases fail for real reasons | trace every failure in error analysis to its layer | the failure traces to the case, the grader or the environment |
| Cases discriminate | compare conditions, and plugin on and off | every condition passes, or every condition fails, so the case shows no difference |
| Evals catch a broken harness | on a scratch branch, break 1 thing on purpose: blank a skill `description`, drop a rule from a corpus run, make a stand-in agent return malformed JSON, remove a reviewer from `review.js`. Rerun the cases that cover it | the score doesn't drop. An eval that can't see a planted break can't see a real one |
| Results hold still | rerun a sample of cases | a case flips between trials with nothing changed. Mark it flaky, find the cause, then fix it or add trials |
| Coverage matches the contracts | map cases to the rows in [`components.md`](components.md) and [`suites.md`](suites.md) | a contract has no case, or only cases on the side where the component must act |
| Signal is worth the cost | cost and wall time per finding that led to an action | a case costs a lot and has never led to an action |

The planted breaks never leave the scratch branch. Delete it after the rerun.

### What you may change

- **Change without asking:** cases, graders, corpora, the runner, and docs under `evals/`. Add
  cases, fix a broken grader, rewrite a vague prompt, add trials to a flaky case, split a case that
  tests 2 things.
- **Ask first:** remove a case, lower a pass bar, loosen a grader, or change a label. These make
  the harness look better, so they need the user's approval and a written reason.
- **Never:** tune a case or grader toward the result you expect or want. Tune it toward telling
  good from bad. If a fix raises the harness's score, show that the old eval was wrong, with the
  grader's known-good and known-bad runs.
- **Not on an eval branch:** harness code. List each harness defect the evals found, with its
  evidence, and ask the user whether to open a fix branch.

Record every eval change in `evals/CHANGELOG.md`: date, what changed, why, and the numbers before
and after.

### Report

End each session with this report, in the results summary and in your final message:

1. **Verdict on the evals.** 1 of:
   - *Working as designed and giving value:* graders separate good from bad, failures trace to
     real causes, planted breaks get caught, and the results led to at least 1 action.
   - *Working, value unproven:* the evals are sound but haven't yet found anything to act on.
     Say what would change that.
   - *Needs work:* name the checks above that failed, and what you fixed or propose.
2. **What the evals say about the harness.** Pass^k and counts per suite, the top causes from
   error analysis, and the harness defects found.
3. **What you changed in the evals,** from the changelog.
4. **What you recommend next,** in order, with the cost of each.

Be blunt. A finding that the evals aren't worth their cost is a useful result.

## Rules

- **Evals are not plan tasks.** Don't touch the plan, the ledger, `index.json` or a plan claim. The
  plan's orchestrator owns those.
- **Don't edit `gate/`, `skills/`, `agents/`, `workflows/` or `hooks/` on an eval branch.** An eval
  measures the harness as it is. A fix that an eval motivates goes on its own branch, through the
  normal process, and the eval's results name the finding that motivated it. A gate feature the
  evals need (such as the hook decision log) becomes a plan task.
- **Never re-implement a check.** Corpora and graders call `swiftgate --json` and compare rule ids.
  They don't parse Swift or match patterns of their own.
- **Model runs wait for a quiet machine.** Before a run that calls a model or builds Swift, run
  `git worktree list`. If a plan task worktree has work in progress, ask the user first. Wave builds
  and eval runs compete for memory.
- **Never touch the real `HOME`.** Every live run gets a scratch `HOME` and a throwaway copy of the
  app, as [`../docs/e2e-report.md`](../docs/e2e-report.md) did.
- **Pin every run.** Record the model id, the judge model id, `claude --version`, the harness
  commit and the Xcode version in the summary.
- **Cap the cost.** Pass `--max-cost-usd` to every `claude plugin eval` run. Ask the user before a
  run whose cap is above the handoff's budget.

## Layout

| Path | Holds |
|---|---|
| `evals/cases/<area>/<name>/<case>/` | `claude plugin eval` cases: `prompt.md` or `case.yaml`, and `graders/*.md`. `<area>` is `routing`, `skills` or `agents` |
| `evals/corpora/<gate>/<case>/` | rule corpus cases: the input files and `labels.json` (`{"kind": "positive" \| "evasion" \| "near-miss" \| "clean", "expect": ["rule.id", …]}`). `<gate>` names the `swiftgate` command. `evals/runner/seed_corpora.mjs` writes them; edit the seeds there, not the case files |
| `evals/runner/` | Node scripts (`.mjs`, no dependencies, the same style as `tests/`) that run corpora and summarize results |
| `evals/results/<date>-<suite>/` | `summary.md` and `summary.json`. Raw transcripts stay out of git; the summary names where the run kept them |
| `tests/*_test.mjs` | workflow orchestration cases. They are deterministic, so they live with the push-tier tests, not here |

Until the packaging wave moves the plugin into `plugin/`, the repo root is the plugin root, so
`claude plugin eval .` reads `evals/` by default and finds `evals/cases/**`. After the move, run
`claude plugin eval plugin --eval-dir evals` from the repo root so the fixtures never ship inside
`plugin/`. Check the flag against `claude plugin eval --help` before relying on it.

## Build a case

1. Pick the case from [`suites.md`](suites.md) or [`components.md`](components.md). Name it for what
   it checks: `tdd-red-before-fix`, not `case-3`.
2. Write the balanced pair: a case where the component must act and a case where it must not.
3. Prove the grader: run it on a known-good output and a known-bad one, and confirm it passes the
   first and fails the second. A grader nobody has seen fail proves nothing.
4. Record in the case what it tempts or tests, and the source section of the contract.

## Run and record

```sh
claude plugin eval . --case 'routing/*' --runs 3 --model <pinned> --judge-model <pinned> \
  --max-cost-usd <cap> --json <scratch>/result.json --no-publish
node evals/runner/corpus.mjs evals/corpora/prose evals/corpora/lint evals/corpora/arch --out <dir>
```

After each run:

1. Read every failing trial and a sample of passing ones.
2. Write 1 line per failing trial naming the first thing that went wrong, then group the lines
   into causes and count them.
3. Tag each cause with a layer (case, grader, skill, agent, workflow, gate, environment) and an
   action (fix the case, fix the harness, add a `self-test` seed, record a limit).
4. Write `evals/results/<date>-<suite>/summary.md` with the pins, counts, pass^k and the cause
   table, and `summary.json` with the same numbers.
5. Run `bin/swiftgate prose` on every markdown file you touched.

A case whose failures all trace to the case or the grader isn't a result. Fix it and rerun
before you report a number.

## Commit

1 commit per coherent step on the eval branch, message `test(evals): …` for cases and runners,
`docs(evals): …` for results and docs. The user merges eval branches to `main`.
