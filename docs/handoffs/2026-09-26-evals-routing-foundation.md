# Handoff: skill routing for the 6 foundation skills

<!-- RESUME
State (2026-09-27): routing rounds 1 to 5 and a round-6 red-first are done; every skill but ship and build is 1.00 precision held out, review recall 0.93. First runs of failure-modes (evals/faults, 15 cases, 0 false greens on main), guard-conformance (evals/corpora/hooks.json, 93 cases, all denies and controls right; 9 live session cases), review-accuracy (evals/sessions/review, 5 cases) and 2 tdd session cases. Results under evals/results/2026-09-2[67]-*. Lessons in evals/runbook.md.
Run evals from a stage: evals/runner/stage_plugin.sh <dir> [tag split newtag]..., then `claude plugin eval .` from <dir>/plugin. Session cases: node evals/runner/session.mjs. No-model suites: faults.mjs, hooks.mjs, corpus.mjs, review_accuracy.mjs.
Open, in order: (1) score the review-accuracy re-run against the source-line fix (a11a0aa): raw at the old session's scratchpad review5/raw (see the evals-in-flight memory), `node evals/runner/review_accuracy.mjs <raw>`; expect clean-reset to cite line 73 and the dismiss race as blocker; write the results. (2) ship/build routing: red-first on 16 tuning cases gave ship recall 0.75 (1 miss: formal "interview preset ... how long it took"), build 1.00; the 40-case independent held-out set (round-6, split-40) hasn't run: about 12 USD at 3 trials at 0.10 USD a run, so ask the user for budget. (3) ship output quality: score the build executor's wave 10-11 rehearsal artifacts with code graders when swift-harness-df sends the paths; a paid ship run is 5-20 USD, capped. (4) review round 6 for the narrowed-review shape; a Stop-hook case that starts RED.
Budget: batch 2 approved about 38 USD; about 25.6 reported spent before the review re-run, not counting Workflow agents.
Peers: swift-harness-fe (sub-project 2 orchestrator) and swift-harness-df (build executor, sub-project 5) own plugin/; send findings by SendMessage and re-run when they ping.
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
