# Routing round 4: `bootstrap`, `design`, `plan`, `prose`, `status`, 2026-09-26

`skill-routing` for the 5 skills that rounds 1 to 3 didn't cover. An independent agent wrote the
100 cases (tag `round-4`) from the skill descriptions and the app alone, before any run: 10
requests per skill, half should-trigger and half near-miss, 2 paraphrases each, split 60/40.

**Result: every skill scores 1.00 precision and 1.00 recall on the 40 held-out cases, 40 of 40
at pass^3. Nothing loaded where it shouldn't have.** The tuning set found 1 flaky trial, for
`plan`. No description change is needed.

## Pins

| Pin | Value |
|---|---|
| Agent model | `claude-opus-5-5`, pinned with `--model` |
| Judge model | `claude-haiku-4-5-20251001`, pinned; routing has no `llm` graders |
| `claude --version` | 2.1.282 |
| Harness | `main` `60e7603`, the first routing run on the `plugin/` layout, staged with `evals/runner/stage_plugin.sh` |
| Settings | `--runs 3 -j 2 --ablation none --scaffold`, `max_turns: 1`, tools `Read, Glob, Grep, Skill` |

## Results

| Skill | Held-out P | Held-out R | Tuning P | Tuning R |
|---|---|---|---|---|
| `bootstrap` | 1.00 | 1.00 (12 of 12) | 1.00 | 1.00 (18 of 18) |
| `design` | 1.00 | 1.00 (12 of 12) | 1.00 | 1.00 (24 of 24) |
| `plan` | 1.00 | 1.00 (12 of 12) | 1.00 | 0.96 (23 of 24) |
| `prose` | 1.00 | 1.00 (12 of 12) | 1.00 | 1.00 (18 of 18) |
| `status` | 1.00 | 1.00 (18 of 18) | 1.00 | not run, see below |

Near-misses whose right answer is a skill from an earlier round loaded that skill every time on
the held-out set: `tdd` 12 of 12, `review` 6 of 6. The tuning set did the same for `architecture`
(12 of 12) and `comment-audit` (6 of 6). 36 held-out and 53 tuning near-miss trials that should
load nothing loaded nothing.

| Set | Cases | Trials | pass^3 | Flaky |
|---|---|---|---|---|
| **Held-out (split-40)** | **40** | **120** | **40 of 40** | **none** |
| Tuning (split-60) | 52 of 60 | 155 of 180 | 51 of 52 | `plan-after-design-skill-a`, 2 of 3; 1 trial loaded nothing |

**The tuning run is incomplete.** The cost cap stopped it at 155 of 180 trials. The 8 `status`
tuning cases that never ran are `plans-in-flight`, `git-staged`, `fresh-session-pick` and
`resume-lines`, `-a` and `-b` each, and `ci-status-b` ran 2 of 3. The held-out verdict for
`status` is complete (18 of 18) and doesn't depend on them. Running them costs about 1.8 USD.

## Checks on the evals

| Check | Result |
|---|---|
| Graders tell good from bad | The routing graders are the ones rounds 1 to 3 proved; the smoke run on the new staging loaded `status` and scored it |
| Cases fail for real reasons | The 1 tuning miss loaded nothing, which is a real recall miss, not a scaffold or harness failure |
| Evals catch a broken harness | Not re-run for these 5 skills. A perfect score doesn't prove the near-misses would catch an overreaching description; round 2 found only a strong break shows up. **Owed:** a planted break for 1 of these skills |
| Results hold still | 0 flaky held-out cases; 1 flaky tuning case |
| Coverage | 20 prompts per skill, written independently |

## Cost

| Step | USD |
|---|---|
| Smoke, 1 case × 1 | 0.05 |
| Tuning, 155 trials | 11.00 |
| Held-out, 120 trials | 7.53 |
| **Total** | **18.58** |

**The estimate was low.** I priced the round at 0.058 USD per run, the round-3 mean. Round 4
averaged 0.067, likely because these prompts load longer skills. The caps summed to 18.05, and the
run went 0.53 over, which is the runs already in flight when the cap hit.

## Verdict

1. **Verdict on the evals: working, with 1 gap.** The independent set and the staging both held.
   With every score at 1.00, precision still owes a planted break for these 5 skills.
2. **What the evals say about the harness.** All 5 descriptions route correctly on held-out
   requests, and none of them takes a neighbour's request. Across rounds 1 to 4, all 11 skills
   are at 1.00 held-out precision. `review` recall on merge-verdict requests and the `validate` PR
   summary shape are still open.
3. **What to do next:**
   1. A planted precision break for 1 of these skills, about 0.5 USD.
   2. The 8 unrun `status` tuning cases, about 1.8 USD, only if `status` changes.
   3. A `review` round and a `validate` fix for the open shapes.
