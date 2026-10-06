# `ship` and `build` routing, independent held-out set, 2026-09-27

The 40-case held-out set (tags `round-6`, `split-40`) an independent agent wrote for `ship` and
`build`: 20 cases for each skill, half should-trigger and half near-misses that belong to `plan`,
`design`, `tdd`, `review`, `status`, `validate`, `architecture` or no skill. 3 trials each,
`claude-opus-5-5`, `max_turns: 1`, `--ablation none`, harness on `evals-round-7` (main at
`1b2f9b9` plus eval results; `plugin/skills` unchanged since the red-first). Staged with
`evals/runner/stage_plugin.sh` and scored with `evals/runner/routing.mjs`.

**Result: `build` 1.00 precision and 1.00 recall; `ship` 1.00 precision and 0.93 recall. Not 1
trial in 120 loaded a wrong skill. The 2 `ship` misses are 1 trial each in 2 flaky cases. In both,
the agent read the spec before it loaded anything, and the 1-turn cap ended the trial first.**

| Skill | Trials expected | Loaded | Precision | Recall |
|---|---|---|---|---|
| `build` | 30 | 30 | 1.00 | 1.00 |
| `ship` | 30 | 28 | 1.00 | 0.93 |
| near-miss owners (`plan` 12, `architecture`, `design`, `review`, `status`, `tdd`, `validate` 6 each) | 48 | 48 | 1.00 | 1.00 |
| `none` near-misses | 12 | 12 loaded nothing | | |

pass^3: 38 of 40 cases. Confusion: every row is on the diagonal except `ship` → `none`, 2 trials.

## The 2 misses

| Case | Prompt | Trials that loaded `ship` | Turn 1 in the miss |
|---|---|---|---|
| `ship-r6-favorites-spec-to-main-b` | "specs/favorites.md is done. get it all the way to main, green" | 2 of 3 | `Read specs/favorites.md` |
| `ship-r6-leaderboard-spec-unattended-a` | "…turn that spec into working, merged code on main while I'm away from the keyboard." | 2 of 3 | `Read specs/leaderboard.md`, then `Glob` |

Neither miss chose another skill. Each spent its only turn reading the spec the prompt named. A
real session has more turns and may load `ship` on turn 2, so a 1-turn trial counts this pattern
against the skill. That matches the red-first miss on the tuning set, a formal "timed preset"
request that also loaded nothing.

## Against the red-first

| Set | `ship` recall | `build` recall | Precision |
|---|---|---|---|
| Tuning, 16 cases × 1 (red-first) | 0.75 | 1.00 | 1.00 |
| Held-out, 40 cases × 3 | 0.93 | 1.00 | 1.00 |

## Cost

7.33 USD for 120 runs, 0.061 USD a run, against the 0.099 measured on the red-first. The estimate
was 11.9 USD. Wall time 818 seconds.

## Verdict

1. **Verdict on the evals: working.** The independent set exercised 8 neighbouring skills and none
   drew a wrong load. The 1-turn cap can't tell "reads the spec, then loads" from "never loads".
2. **What the evals say about the harness.** `ship` and `build` meet the precision bar. `ship`
   recall sits above the 0.90 trigger set for a fix task, so none goes out. A description line
   telling the agent to load `ship` before reading the spec might close the gap, but that is a
   `plugin/` change, and the numbers don't call for it.
3. **Unmeasured:** whether a missed trial loads `ship` on turn 2, and what `ship` produces once
   loaded.
