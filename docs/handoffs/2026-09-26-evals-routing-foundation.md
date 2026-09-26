# Handoff: skill routing for the 6 foundation skills

<!-- RESUME
State (2026-09-26): NOT STARTED. The first eval round is merged on main (53644b5). Worktree ../swift-harness-evals exists; its branch evals-foundation is fully merged.
Next action: in the worktree, `git switch -c evals-routing-foundation main`, then follow "Steps" below.
Read first: evals/runbook.md (operator role and rules), then the skill-routing section of evals/suites.md.
Needs the user: approval before spending past 35 USD in total; answers to the open decisions below.
-->

## Scope

`skill-routing` from [`suites.md`](../../evals/suites.md#skill-routing) for the 6 foundation skills:
`tdd`, `architecture`, `review`, `test-gate`, `validate`, `comment-audit`. For each skill, 5
requests that should trigger it and 5 near-misses that share its words but belong elsewhere, 2
paraphrases each: 20 prompts per skill, 120 in all. Split them 60/40, run 3 trials, and report
per-skill precision and recall on the 40 only.

The user approved this round at about 35 USD in total. Ask before spending more.

## What the first round established

The [first round's handoff](2026-09-25-evals-foundation.md) has its full scope.

Read these results before building anything. Each one changes how you write a routing case.

- `claude plugin eval` fits routing. [Spike results](../../evals/results/2026-09-25-runner-spike/summary.md).
- **Put execution settings in `prompt.md` frontmatter.** The runner ignores `max_turns`,
  `timeout_seconds` and `allowed_tools` in `case.yaml` when `prompt.md` exists.
- **Run with `--ablation none`.** Without the plugin no `swift-harness:*` skill exists, so the
  plugin-off arm scores 0 by construction. The negative side comes from the near-misses.
- **Match the whole skill id.** Use `tool_used` with `tool: Skill` and
  `input_match: "\"skill\":\"swift-harness:tdd\""`. Matching `tdd` alone also passes a `test-gate`
  call whose args mention tdd. A near-miss case sets `min: 0, max: 0` on the wrong skill. It adds a
  second grader for the skill that should load, if any.
- **Link the scaffold.** A case links `scaffold.sh` to `../../../../scaffold/sampleapp.sh`. The
  runner refuses a scaffold path outside the case. The scaffold seeds `swiftgate` into the scratch
  `HOME`; without it every hook is off. Pass `--scaffold`.
- **The existing case** `evals/cases/routing/tdd/add-test-for-reducer` is the template. It passed 4
  of 4 with the plugin, at 0.19 to 0.54 USD per run.

## Steps

1. **Measure the per-run cost first.** Run the existing routing case once with `max_turns: 2` and
   once with `max_turns: 4`. The model picks a skill on its first turn, so pick the cheaper setting if
   both grade the same. Multiply by 120 prompts and 3 trials. If the product passes 35 USD, tell
   the user the number and ask: fewer trials on the 60, or fewer paraphrases.
2. **Write the 120 prompts** under `evals/cases/routing/<skill>/<case>/`. Phrase them as a user
   would, not as the description does. Near-misses follow `suites.md`: "write a test for this reducer"
   goes to `tdd`, not `test-gate`; "review this design" goes to `design`, not `review`. Tag each
   case `split-60` or `split-40`, and tag it with the skill it should load or `none`.
3. **Prove the graders** on 1 should-trigger and 1 near-miss case: a known-good and a known-bad
   run each.
4. **Run the 60, then the 40,** with `--tag`, `--runs 3`, `--ablation none`, `--scaffold`,
   `--no-publish` and a `--max-cost-usd` cap. Pin `--model` and `--judge-model`.
5. **Tuning a description is a harness change.** `skills/` is off limits on an eval branch.
   Write each proposed description change with the 60-split evidence behind it, and ask the user
   about a fix branch. Report only the 40.
6. **Record the results.** Write `evals/results/<date>-routing-foundation/summary.md` and
   `summary.json`: per-skill precision and recall with case counts, a confusion table, pass^3,
   flaky cases, cost and wall time. Add a line to `evals/CHANGELOG.md`. End with the runbook's
   report.

## Open decisions from the first round

These are the user's to make. Ask them at the start; routing doesn't depend on them.

- Confirm the operator's prose labels: `evals/results/2026-09-25-corpus/prose-audit.json` and the
  near-miss corpus cases marked `labelledBy: operator`. The prose fix on main already relies on
  them.
- Approve loosening the `tdd` judge rubric in
  `evals/sessions/skills/tdd/decrement-floors-at-zero/graders/red-then-green.md`. It names
  `swiftgate`, so the plugin-off arm can never pass it.

## Machine hazards

- **Shell aliases.** The user's shell aliases `cp` and `rm` to their interactive forms. A command
  that overwrites or deletes hangs on the prompt. Use `/bin/cp -f` and `/bin/rm -f`.
- **Other work on the machine.** Wave 24 (the move into `plugin/`) is in progress in another
  worktree. Run `git worktree list` before a model run, per the runbook. After wave 24 merges,
  run `claude plugin eval plugin --eval-dir evals` from the repo root. Check the flag against
  `--help` first.
- **Cleanup.** `claude plugin eval --keep-temp` leaves sealed directories in the system temp dir, named
  `e-*`. Open them with `chmod`, and delete them after reading.

## Kickoff prompt

> You are the eval operator for swift-harness, not an observer. Read
> `docs/handoffs/2026-09-26-evals-routing-foundation.md` and `evals/runbook.md`, and follow the
> runbook's operator role. Work in the `../swift-harness-evals` worktree on a new branch
> `evals-routing-foundation` off main. Run the skill-routing round for the 6 foundation skills
> within the approved 35 USD. Start with the per-run cost measurement and report it before writing
> the 120 prompts.
