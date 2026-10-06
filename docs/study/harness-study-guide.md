# swift-harness study guide: questions and answers

Questions an engineer who builds with AI is likely to ask about swift-harness, with answers drawn
from the repo's own docs and measurements. Numbers come from the [README](../../README.md), the
[practice-app results](../results/2026-10-05-practice-app-results.md), the
[evals README](../../evals/README.md) and [ADR 0004](../adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md).

How to use it: read the question, answer out loud, then check the answer. The answers marked ⚠️
are the weak spots. Bring them up yourself before anyone presses on them.

## Contents

1. [The pitch](#1-the-pitch)
2. [Trust and verification](#2-trust-and-verification)
3. [Orchestration](#3-orchestration)
4. [Results and evaluation](#4-results-and-evaluation)
5. [Judgment and limits](#5-judgment-and-limits)
6. [How you built it: multi-agent workflows and loop engineering](#6-how-you-built-it-multi-agent-workflows-and-loop-engineering)
7. [How mutation testing works](#7-how-mutation-testing-works)
8. [How the stall watch works](#8-how-the-stall-watch-works)
9. [Cheat sheet: numbers to know](#9-cheat-sheet-numbers-to-know)

---

## 1. The pitch

**Q1. What is it, in 2 sentences?**

A Claude Code plugin that turns a spec into a merged, tested SwiftUI app with no human input. One
gate binary, `swiftgate`, decides every pass or fail, so the agents can't talk their way past a
check.

**Q2. Why build it? Why not just use Claude Code?**

Plain agents report green when it isn't, write tests that prove nothing, and drift from the
architecture. The harness turns "trust the agent" into "trust the gate." Every enforcement point
(hook, skill, git hook, eval) calls the same binary, so no rule can hold one way in a prompt
and another way in CI.

**Q3. Walk me through a run end to end.**

1. A `spec.md` goes into a fresh clone; `swiftgate run` starts headless.
2. Explore by minute 5, plan by minute 8, a contract commit by minute 12. The contract commit
   adds shared types and API surface with no behaviour.
3. Workers run in parallel, 1 git worktree and branch each, on disjoint write sets.
4. Each task runs through a workflow: worker, then reviewers, then independent verifiers, then at
   most 1 fix pass.
5. The orchestrator merges in id order; every merge passes the merge gate.
6. No new starts at minute 27, cutoff at 35; then the final gate and a simulator QA check.
7. A report with cost, wall time and video at minute 40.

---

## 2. Trust and verification

**Q4. How do you know the agent didn't game the tests?**

Five mechanical checks, all run by `swiftgate`, none of them self-reported:

- **`prove`**: each new or changed test must fail when `prove` reverts its source change. That
  catches a test that would pass whatever the code does.
- **`mutate`**: the tests must kill small injected bugs on the changed lines. That catches a test
  that is real but too shallow. See [section 7](#7-how-mutation-testing-works).
- **`testlint`**: rejects assertion-free, tautological, existence-only and sleep-based tests.
- **`check-return`**: the gate run a worker claims must exist in the recorded run history, at the
  right tier and verdict, started at the branch tip on a clean tree. `build merge` refuses
  otherwise.
- **The Stop hook**: blocks a RED stop up to 3 times. On the 4th stop the session may end, and
  `swiftgate` records it as RED, not done.

`surface-check` makes `prove` possible. A surface commit adds API and no behaviour, which gives
`prove` a real "before" to revert to.

**Q5. Who checks the checker?**

- The `swiftgate` verdict is never the only oracle for `swiftgate`. A grader must pass
  known-good output and fail known-bad output before its numbers count.
- Fixtures come from real tool runs, never written by hand.
- Every rule ships with a fixture, plus a check that can fail: the smallest input the
  rule exists to catch.
- Eval suites:
  - `checker-accuracy`: 104 cases; positive recall 12/12, 21/21 and 13/14.
  - `failure-modes`: 10 of 11 injected faults caught on the first run. The miss, an Xcode pin
    mismatch, became a gate change.
  - `skill-routing`: 421 requests; precision 1.00 on every held-out set.
  - `review-accuracy`: 5 of 5 verdicts right, 0 invented findings.

**Q6. Why a single gate binary instead of rules in prompts and CLAUDE.md?**

A prompt is advice; a binary is enforcement. The invariant "never re-implement a check" means
hooks, skills, git hooks and evals all call the same code, so the rules can't drift apart.
Deterministic checks decide. A model judge only handles the uncertain cases, it is opt-in, and it
blocks only at p ≥ 0.9.

**Q7. Can an agent get around your guards?** ⚠️

Yes, sometimes. The guard-conformance run caught 12 of 21 evasions. The guards stop accidental and
ordinary writes, including shell writes such as `sed -i` and redirects, but they aren't a sandbox.
The real backstop is that every merge must pass the gate, and an evasion can't fake a gate run
that `check-return` looks up in the recorded history.

---

## 3. Orchestration

**Q8. How do parallel agents avoid stepping on each other?**

- One worktree and branch per task, and the worker is its only committer.
- Write sets may not overlap.
- Only the orchestrator merges to `main`, in id order, through the merge gate.
- The full suite runs after each batch.

Be honest about what still happens: branches green on their own broke `main` about once per
batch. One example was an enum case added on 1 branch against an exhaustive switch on another.
That's why the merge gate runs on merged `main` and not only on the branch.

**Q9. What happens when an agent stalls or hangs?**

- A stall watch halts a task whose transcripts sit unchanged too long, with 3 options: Retry,
  Wait or Abandon. See [section 8](#8-how-the-stall-watch-works) for the timer.
- Hard deadlines: no new starts at minute 27, cutoff at minute 35.
- A real incident: shell aliases (`cat` mapped to `bat`, `cp -i`) hung a run for 600 s. Run
  sessions now clear aliases, turn off `noclobber` and close stdin.
- The harness answers subagent permission prompts itself, allow or deny, so a worker never waits
  on a prompt it can't show.

**Q10. How do you keep agents from inventing work and growing scope?**

- The time box is the brake.
- One fix pass per task, and a cap of 3 gate runs for a fixer.
- Deferred findings go to sibling tasks instead of becoming new work.
- The diff's risk sets the review depth.

**Q11. Where is the human in the loop?**

At the edges only:

- writing the spec;
- approving the design and plan in attended mode;
- approving pushes.

A brownfield run takes 0 inputs by design: it never asks a question and has no approval stage.
When the orchestrator approves something on the user's behalf, it records that in the plan so a
human can review it later.

---

## 4. Results and evaluation

**Q12. Does it work? How do you know?**

- 7 of 7 practice apps pass from a fresh clone with 0 human inputs. Getting there took 24 attempts
  in total.
- Passing runs: mean $5.53 (range $4.36 to $6.86) and 29.0 minutes (range 25.1 to 32.0).
- Every failed attempt became a *generic* harness fix, never an app-specific patch. The failures
  moved further down the pipeline on each attempt, which is evidence of real progress.

**Q13. How do you know it generalizes, rather than fitting those 7 apps?** ⚠️

Concede it. The same apps served as both training set and test set, with 1 passing run each.
"It shows the pipeline can reach green with 0 input; it doesn't yet give a reliability number.
Next is a held-out set of new specs with 3 or more trials each."

**Q14. Is it better than plain Claude Code?** ⚠️

Not measured yet. The harness-versus-no-harness eval (`task-lift`) hasn't run as a suite. On
2 small tasks both arms passed. On 1 test-gate task the harness scored 1.00 against 0.50 without
it. "I measured that it works as designed, not yet how much it lifts. That's the eval I'd run
first."

**Q15. What does it cost, and what did you optimize?**

Give measured wins only:

- contract slice gate: 240 s down to 55 s;
- final prove: about 60 s down to 9 s;
- QA capture per check: 1.2 s down to 0.4 s.

[ADR 0004](../adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md) is a deliberate cost trade. The timed preset moves `prove` and `mutate` from every task
to 1 run in the final gate. Run per task, they cost 13.7 of 32.8 critical-path minutes and
caught nothing the final gate missed. I parked changes with no measured win unmerged, on
`*-unmerged` branches.

---

## 5. Judgment and limits

**Q16. When would you *not* use it?**

- Exploratory or vague specs, where the human needs to iterate on *what* to build.
- Visual and product-judgment work: swipe-arcade passed the gate, but a manual run showed the
  score display overlapping the status bar and safe area.
- Tiny changes, where the gate overhead (a `prove` floor of about 55 s) is bigger than the work.
- Non-iOS stacks: multi-language brownfield support exists but has had few trials.
- Multi-day runs on a roadmap that keeps changing: I designed the harness for a time box of minutes; see Q20.

**Q17. What's the biggest weakness?** ⚠️

A green gate proves the tests are real, not that the spec's checks cover what a user would
notice. On some apps, the simulator verifies only part of the validation rows; the rest
pass with a recorded reason. "The gate proves tests are real; it can't prove the spec covers what
a user would notice. Spec coverage is the frontier."

**Q18. What would you do next?**

- A held-out eval set with repeated trials.
- The `task-lift` comparison.
- A flow check for visual layout such as the safe area.
- A per-task note in plan state, so an orchestrator can resume from state alone. This is already
  an open follow-up: "Halt decisions need a sanctioned `swiftgate plan note`".
- A smarter stall watch; see [section 8](#8-how-the-stall-watch-works).

**Q19. Isn't the timed preset cutting corners by deferring proof?**

It's a measured trade, recorded in [ADR 0004](../adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md). Under `task_proof = final`, a weak test surfaces at
the final gate and gets fixed after merge instead of before. The final gate stays mandatory in
every preset, so nothing ships unproved.

**Q20. How would it scale from a 40-minute box to runs that last days?**

The gate and the proof model carry over unchanged. What changes is memory and liveness, because
over days the orchestrator's context compacts or gets cleared many times:

- **Durable notes per task in plan state.** Record each halt, retry and deferral with its reason,
  so a fresh orchestrator can resume from state alone. This is the open follow-up
  "Halt decisions need a sanctioned `swiftgate plan note`".
- **A re-anchor at session start.** `orchestrator.lock` already holds the session id. The
  SessionStart hook can tell a compacted orchestrator which plan, run and in-progress tasks it holds.
- **Stall detection that reads transcript state**, not only file times; see
  [section 8](#8-how-the-stall-watch-works).
- **1 review of the whole plan against the spec** before finishing, with fixed lenses and PASS as
  the expected outcome, so review can't keep inventing work.
- **A growth ceiling on replans**, with every raise logged.

Keep proof mechanical and ceremony light: a check per merge, not extra ritual per task.

---

## 6. How you built it: multi-agent workflows and loop engineering

**Q21. How did you build it?**

In 4 stages, each feeding the next:

1. **Specs and design docs.** Each piece of the harness started as a design doc with numbered
   decisions and requirement ids, so later work could cite them.
2. **Decompose into a plan of waves.** A decomposer split each design into tasks with
   dependencies and write sets, then grouped tasks that don't overlap into waves.
3. **An orchestrator builds the waves.** 1 orchestrator session spawns up to 3 workers per wave,
   each in its own worktree. It checks each report, sends fix rounds, merges in id order, and runs
   the push gate on merged `main`. The [runbook](../process/orchestrator-runbook.md#the-wave-loop)
   draws this loop.
4. **Test rounds with a self-healing loop.** The harness ran real apps end to end. Every failure
   turned into fix workers that changed the harness, and the next attempt tested the fix.

Totals: 12 days, 2,752 commits, 84% co-authored with Claude, about 133k lines, 4,689 gate tests.

**Q22. What do you mean by loop engineering?**

A multi-agent workflow fans work out once: many agents in parallel, then a merge. A loop repeats
until a measured exit condition holds, and each pass feeds what it learned into the next. I
combined them: every pass of the loop fans out a workflow of parallel workers.

The harness has loops at 4 levels:

| Loop | 1 pass | Exit condition |
|---|---|---|
| Stop hook | the agent tries to stop; the gate runs | GREEN, or a 4th stop recorded as RED |
| Task workflow | worker, reviewers, verifiers, at most 1 fix pass | verified return, or a halt |
| Wave | spawn workers, check reports, fix rounds, merge, push gate | push gate GREEN on merged `main` |
| Self-healing | run an app, read the report, fix the harness, retry | the app passes inside the box |

**Q23. Walk me through the self-healing loop.**

It ran for about 36 hours, until all 7 practice apps passed. Each pass:

1. **Trial.** Pin a fresh app repo to a detached worktree of `main`, then run `swiftgate run
   spec.md` headless with 0 input and a 40-minute box.
2. **Report.** Read where the run stopped and why, from real telemetry: span timings, gate
   times, worker durations, load.
3. **Fix round.** Group the findings and spawn 1 fix worker per group, 3 to 6 at once, each in
   its own worktree. A worker must make a *generic* harness fix, never an app-specific patch.
4. **Merge.** Merge the batch, run the full suite on `main`, and send any red to a worker.
5. **Push.** Push after 2 clean full-suite runs in a row and a leak scan.
6. **Retry.** The next attempt runs on the new `main`. Its brief lists every fix since the last
   attempt, so the trial checks them too.

**Q24. How did you keep the loop converging instead of thrashing?**

- **A progress metric:** each failed attempt had to stop further down the pipeline than the one
  before. Pass or fail alone hides progress.
- **Generic fixes only**, so the loop improves the harness and not 1 app.
- **1 trial at a time.** 2 trials at once loaded the machine to 300 to 900 and starved the
  simulators.
- **1 worker per finding group.** A new finding goes to the worker that already owns that code,
  so 2 workers never edit the same files.
- **The full suite after every batch.** Branches that pass alone still broke `main` about once
  per batch.
- **Measured wins only.** Changes with no measured win stayed on unmerged branches.
- **Distrust a rule written from 1 failure.** One rule hid a real app defect an attempt later;
  see Q27.

**Q25. What did the loop produce?**

- 7 of 7 apps passing after 24 attempts in total. Each app took 1 to 7 attempts.
- 124 merges to `main` from the evening of 2026-10-04 to the freeze tag.
- 16 pushes on 2026-10-05, each after 2 clean full-suite runs and a leak scan.
- The gate suite grew from 4,534 to 4,689 tests.
- The [results page](../results/2026-10-05-practice-app-results.md) has every attempt, what
  stopped it, and its fix.

**Q26. Where were you in the loop, and how do you trust code agents wrote?**

I set the goals and the brakes, then let the loop run: run trials 1 at a time, keep fixes
generic, run no slow gates during the night. The orchestrator made routine calls itself: merge,
calibrate, push after a green suite. I froze the harness when all 7 apps passed.

Trust comes from the gate, not from the agents:

- The harness gates its own development with `swiftgate`.
- The orchestrator checks every worker report against a list where each line caught a real
  defect. One example: a worker reported "all 8 builders" done when it had delivered 3.
- No push without 2 clean full-suite runs plus a leak scan.

**Q27. What surprised you about working with agents?**

Pick 2 real stories:

- **Machine load was the hidden enemy.** Two trials at once pushed load averages to 300–900 and
  starved the simulators. `mutate --jobs 8` spawned 480 processes. Every load-dependent flake
  turned out to be a test waiting on wall-clock time. The fixes were running trials solo, 1
  machine-wide build lock, and stopping after 3 trials on a flake that won't reproduce.
- **A rule written from 1 failure hid a real bug.** The rule "treat a moving state as a timing
  race" hid a real app defect 1 attempt later. The fix was to require the fixer to reproduce
  what the frames show in a unit test before blaming timing.

**Q28. Is it over-engineered?**

About 133k lines for 1 person is a lot. Defend the structure:

- the code has layers: a pure domain, adapters behind protocols, a thin CLI;
- every rule ships a fixture and a rule-index row, so it stays reviewable.

Also concede the honest version: a small team would start with `prove` plus the merge gate.

---

## 7. How mutation testing works

**What it is.** A way to test your tests. You break the code on purpose and check that a test
notices.

1. Take 1 line of code you changed.
2. Make 1 small, plausible bug in it. That broken copy is a **mutant**.
3. Run the tests against the mutant.
   - A test fails: the mutant is **killed**. Your tests guard that line.
   - Every test still passes: the mutant **survived**. That bug could ship while CI stays green.

**Example.**

```swift
func canCheckout(cartTotal: Int) -> Bool {
    return cartTotal > 0
}
```

If the only test is `XCTAssertTrue(canCheckout(cartTotal: 50))`, the mutant `cartTotal >= 0`
survives. The finding says to add a test for `cartTotal: 0`.

**What `swiftgate mutate` does.** It only touches the lines your diff added, using 5 operators:

| Operator | Mutation |
|---|---|
| `negate-conditional` | `if c` → `if !(c)`; also `guard`, `while` and `repeat … while` |
| `relational-boundary` | `<` ↔ `<=`, `>` ↔ `>=` |
| `return-default` | a return value becomes `false`, `0`, `""`, `nil` or `[]` |
| `remove-call` | deletes a call whose result is unused, such as `save()` |
| `remove-effect` | in TCA, a reducer's effect becomes `.none`, or a `send` is removed |

Outcomes:

- **Killed:** good.
- **Survived:** a major finding, `mutate.survived`, which blocks the merge.
- **Unviable** (the mutant doesn't compile): a nit, not counted.
- **Equivalent:** a line no test could ever tell apart can carry
  `// swiftgate:equivalent-mutant — <reason>`. A marker with no reason is itself a finding.

**`prove` compared with `mutate`.**

- `prove` asks whether the test fails when `prove` reverts the whole change. It catches tests that
  pass no matter what.
- `mutate` asks whether some test fails for each small bug on each changed line. It catches tests
  that are real but shallow.

Writing a test that passes is easy for an agent. Writing one that also kills every mutant
without checking the behaviour is much harder.

**Cost.** Every mutant needs a test run, so mutation testing is slow. That's why the timed preset
runs it once at the final gate ([ADR 0004](../adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md)).

---

## 8. How the stall watch works

**Q: Is a 15-minute stall timer too long for a 40-minute run?**

**What the code does.** 15 minutes is only the default. Inside a time box, the limit shrinks as
the cutoff nears: half the minutes left until the cutoff, but never under 6. With the cutoff at
minute 35:

| Worker stalls at | Stall limit then | Detected around | Time left to cutoff |
|---|---|---|---|
| minute 12 (workers start) | ~11 min | minute 23 | 12 min |
| minute 20 | ~7 min | minute 27 | 8 min |
| minute 25+ | 6 min (the floor) | minute 31+ | 4 min or less |

**Why it can't be 2 minutes.** The watch looks at 1 signal: whether any transcript file changed.
That signal can't tell 2 cases apart:

- **Healthy silence:** a worker inside 1 long tool call, such as a cold gate build, which can
  run 5 minutes with no transcript write.
- **A real stall:** a permission prompt the worker can't show, or a hung shell.

Because of that, the limit has to be longer than the longest healthy silence.

**The better design.** Classify the silence instead of only timing it:

- The last entry is a tool call with no result yet: the worker is busy, so allow that tool's own
  timeout.
- The last turn ended but the workflow never returned: a real stall, so flag it within about a
  minute.
- The tool call waits on a permission prompt: flag it at once.

**How to say it.** "The stall watch is the weakest timer in the box. It only looks at transcript
mtime, so its limit has to cover a 5-minute cold build, which costs up to 11 minutes on an early
stall. I scale it down as the cutoff nears. The real fix is to read the transcript's state and tell
'mid tool call' apart from 'turn ended without returning'. Then the watch catches a
permission-prompt stall in seconds." In practice the observed causes are gone: run sessions clear
aliases and close stdin, and the harness answers subagent permission prompts itself.

---

## 9. Cheat sheet: numbers to know

| Fact | Value |
|---|---|
| Practice apps passing | 7 of 7, 0 human inputs, 24 attempts in total |
| Passing run, mean | 29.0 min, $5.53 |
| Time box | explore 5, plan 8, contract 12, no new starts 27, cutoff 35, report 40 (minutes) |
| Build | 12 days, 2,752 commits, 84% co-authored with Claude, about 133k lines, 4,689 gate tests |
| Parallel workers | up to 3 on a laptop |
| Self-healing loop | about 36 h, 24 attempts, 124 merges, 16 pushes on the last day |
| Build stages | spec and design doc, plan of waves, orchestrator builds waves, self-healing test rounds |
| `checker-accuracy` | 104 cases; recall 12/12, 21/21, 13/14 |
| `failure-modes` | 10 of 11 caught on the first run |
| `skill-routing` | 421 requests; precision 1.00 on held-out sets |
| `review-accuracy` | 5 of 5, 0 invented findings |
| `guard-conformance` | 12 of 21 evasions caught |
| `task-lift` | not run as a suite |
| [ADR 0004](../adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md) | per-task prove and mutate cost 13.7 of 32.8 critical-path minutes |
| Gate speedups | slice gate 240 s → 55 s; final prove ~60 s → 9 s |
| Stall watch | default 15 min; in a box, half the time to cutoff, floor 6 |
| Stop hook | blocks a RED stop up to 3 times |

**Answer shape that works.** Lead with the mechanism, give 1 number, name the trade-off, and say
what you'd do next. State the ⚠️ weak spots yourself.
