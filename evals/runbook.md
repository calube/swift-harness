# Eval runbook

How to work on the evals in any session: build cases, run them, record results. Read
[`README.md`](README.md) for why, [`design.md`](design.md) for method, and [`suites.md`](suites.md)
and [`components.md`](components.md) for what to measure. The dated handoff for the current round
lives in `docs/handoffs/` and names the scope.

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
| `evals/corpora/<gate>/<case>/` | rule corpus cases: the input files and `labels.json` (`{"kind": "positive" \| "near-miss" \| "clean", "expect": ["rule.id", …]}`) |
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
node evals/runner/corpus.mjs evals/corpora/prose     # once the corpus runner exists
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
