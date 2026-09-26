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
| `evals/sessions/<area>/<name>/<case>/` | thin-runner cases for work that builds or tests Swift: `task.md` with frontmatter, `graders/*.md` (the `claude plugin eval` types plus `command`), and `scaffold.sh`. `claude plugin eval` can't run these: its Bash sandbox blocks the Xcode toolchain |
| `evals/scaffold/` | shared scaffold scripts. A case links to one as `scaffold.sh`, since `claude plugin eval` refuses a scaffold path outside the case |
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
node evals/runner/session.mjs evals/sessions/skills/tdd/* --runs 3 --max-cost-usd <cap> --out <dir>
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

## Lessons from the routing rounds

Each rule below cost a rerun or a wrong number once. The results summaries under
`evals/results/2026-09-26-routing-*` hold the evidence.

**Measuring**

- Price a round from the mean cost of a real batch, not from 1 run. The first routing estimate
  was 0.067 USD per run; the batch averaged 0.107, and the cost cap cut it at 162 of 216 runs.
- Routing runs use `max_turns: 1`. Every skill load in 300 trials came in the first turn. With 2
  turns, the agent spends turn 2 spawning a shell subagent, at up to 0.48 USD.
- `allowed_tools` doesn't stop `Agent` or `ToolSearch`. Only the turn cap keeps a run small.
- `--max-cost-usd` ends the run with exit 0. Read `partial` and `partialReason` in the JSON.
- `--case` takes 1 glob with no brace sets. To run a hand-picked set, add a temporary tag to
  those `case.yaml` files, run `--tag`, then `git checkout -- evals/cases`.
- `--tag round-N` matches every split. Select a split by tag before a tuning run, or the run
  spends money on held-out cases you then can't read.
- In zsh an unquoted `$FLAGS` stays 1 argument. Write the flags out, or use an array.
- Keep traces with `--keep-temp`, score them with `node evals/runner/routing.mjs`, then delete
  only the `e-*` directories that the result JSON names.
- Plug the laptop in for a long batch. The machine hibernated mid-run at 1% battery; the grades
  held, but that batch's wall time didn't.

**Designing cases**

- A prompt that says "my change", "my branch" or "staged" needs a scaffold with a change in it
  (`sampleapp-with-change.sh`). On a clean tree the agent answers, with reason, that there's nothing to
  review, and the case fails for the wrong reason.
- Tune on the 60 and report the 40. Once you have read a held-out prompt, it's no longer held
  out. Have a separate agent write each new held-out set from the skill descriptions and the
  app alone, before the change it checks. The independent sets found 2 shapes that the tuner's
  own cases missed.
- Run new cases red first: on the unchanged harness they must fail for the reason the change
  targets.
- A near-miss fails only on a wrong load, so a bait sentence in a description ("use it for every
  request that mentions a test") showed nothing: 0 wrong loads in 16. Prove precision with a
  description that claims its neighbours' jobs. That one caused 6 wrong loads in 8.
- Deciding to keep trials that ran by accident is fair only if you decide before you read them.

**Harness and repo**

- The plugin ships from `plugin/`, while `examples/`, `evals/` and `.gitignore` stay at the repo
  root. A scaffold needs both roots. The move broke every scaffold until they kept the 2 roots
  apart.
- `tests/skill_commands_test.mjs` needs a built `swiftgate`. It finds
  `plugin/gate/.build/debug/swiftgate`. In a fresh worktree, point `SWIFTGATE_BIN` at a built
  binary for the same `gate/` sources.
- Another session merges plan waves into `main`. Before you merge, run `git log main` and
  `git worktree list`, and message that session.

## Commit

1 commit per coherent step on the eval branch, message `test(evals): …` for cases and runners,
`docs(evals): …` for results and docs. The user merges eval branches to `main`.
