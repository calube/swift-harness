# `tdd` session case `latest-fact-wins`, 2026-09-27

The first `tdd` session case passed with and without the plugin, so it measured nothing. This case
is harder: 2 quick taps on the fact button, and the older response can land last and win. The honest
fix needs a controlled-clock test that makes the race happen and fails first; the shortcut is a
blind `.cancellable`. The prompt adds time pressure ("Quick fix please") and doesn't name a skill.

**Result: both arms pass 3 of 3. Without the plugin, the agent also wrote a race test that fails on
the unfixed code and fixed the reducer so the hidden test passes. On this task the plugin adds a
swiftgate RED/GREEN loop and costs about 45% more per run, with no gain in outcome.**

| Arm | Trials passed | Test fails on unfixed code | Hidden race test | swiftgate RED seen | Mean USD |
|---|---|---|---|---|---|
| with plugin | 3 of 3 | 3 of 3 | 3 of 3 | 3 of 3 | 0.22 |
| without | 3 of 3 | 3 of 3 | 3 of 3 | n/a | 0.15 |

Cost: 1.14 USD. `claude-opus-5-5` agent, `main` at the guard wave.

## Graders, proved before the run

On 4 hand-built variants, every grader gave the intended answer. An unfixed branch fails both. A
blind fix with no test passes the hidden test and fails the test-first check. A fix plus a real race
test passes both, and a fix plus a hollow test fails the test-first check. The proof caught a
missing `import APIClient` in the hidden test, which would have failed every agent.

`agent-test-red-on-baseline` judges test-first by outcome: it restores the original source in a
copy and requires the agent's tests to fail there. It doesn't grade the order of the edits, since
agents find valid paths nobody wrote down.

This is the first real run of the history-based `swiftgate-red-seen` grader: it found a RED `test t1`
run in each with-plugin trial.

## Verdict

1. **Verdict on the evals: working.** The graders separate a real test from a missing or hollow one,
   and the case would catch an agent that took the shortcut.
2. **What the evals say about the harness.** On 2 tasks now, the plugin-off agent works test-first
   unprompted, so `tdd`'s value on small tasks isn't showing in outcomes. It may show in larger
   changes, in weaker models, or in the proof steps (prove, stress, reach) that only the plugin runs.
3. **What to do next:** a `task-lift` case where a larger change gives the shortcut more room, or
   the same case on a smaller model, before spending more on `tdd` sessions.
