# Eval suites

Each suite answers 1 question about the harness, uses 1 kind of grader as its main oracle, and
reports a small set of metrics. [`design.md`](design.md) covers what the suites share: conditions,
trials, graders, the run record. The pass bars below are starting targets. The first baseline run
sets the real numbers, and a later change to a bar needs a written reason in the results log.

| Suite | Question | Main oracle | Cost per run |
|---|---|---|---|
| [`checker-accuracy`](#checker-accuracy) | Does `swiftgate` flag what it should and nothing else? | labels by construction | no model calls |
| [`guard-conformance`](#guard-conformance) | Do the hooks fire and decide as `plugin/docs/hooks.md` says, in a live session? | transcript and hook log | low |
| [`skill-routing`](#skill-routing) | Does the right skill load for a request, and stay quiet otherwise? | transcript | low |
| [`task-lift`](#task-lift) | Does an agent with the harness ship better Swift than one without it? | hidden tests plus labels | high |
| [`design-honesty`](#design-honesty) | Does `/swift-harness:design` keep unproven claims out of Decision? | pinned-source truth table | high |
| [`review-accuracy`](#review-accuracy) | Do the review and design-review agents find seeded defects without inventing others? | seeded defects | medium |
| [`failure-modes`](#failure-modes) | When the environment breaks, does the harness say BLOCKED instead of GREEN? | injected faults | low |

[`components.md`](components.md) grades each skill, agent, workflow and rule on its own inputs.

`swiftgate self-test` and `calibrate design` stay what they are: fixed seeds that must go red on
every push. The suites here are larger, change more often, and run on demand. A seed a suite finds
useful as a permanent guard graduates into `self-test`.

## `checker-accuracy`

**Question.** For each rule, how often does `swiftgate` catch the violation (recall), and how often
does it flag code that follows the rules (false-positive rate)?

**Cases.**

- *Seeded positives.* A generator takes clean files from the eval apps and applies 1 known
  violation per copy: `Date()` in a Core reducer, `import UIKit` in a Core package, `static let
  shared`, `try!` without an allow, a test with no assertion. The generator writes the label, so the
  label is right by construction.
- *Evasions.* The same violation spelled another way: `Date.now`, `Date.init()`, a typealias for
  `Date`, `UUID.init()`, a helper that wraps `print`, `Task.sleep(for:)` behind a local function.
  Collect more from what agents write in `task-lift` runs. Each miss is a candidate rule or a
  documented limit.
- *Near-miss negatives.* Code that looks wrong and isn't: `Date()` inside a `*Live` module, an
  allow with a reason, `print` inside `LogClientLive`, the word `shared` in a local name. These
  catch over-matching.
- *Clean corpus.* Every file in the eval apps' GREEN baselines. Any finding here is a false
  positive by definition.

**Grader.** Compare `swiftgate lint|arch|comments|testlint --json` rule ids to the labels. No model.

**Metrics.** Recall and false-positive rate per rule id, with the case count, and a confusion table
of the rules that fire on the wrong seed.

**Pass bar.** Recall 1.0 on seeded positives for every rule the standards call mechanical. 0
findings on the clean corpus. Evasions have no bar at first: the suite lists them, and each gets a
rule, a documented limit in `plugin/docs/standards.md`, or a `wontfix` with a reason.

## `guard-conformance`

**Question.** In a real `claude` session with the plugin installed, does each hook fire on the
events it claims, return the decision it claims, and does the agent end in a compliant state?

**Cases.** 1 scripted prompt per guard and per hook path in [`plugin/docs/hooks.md`](../plugin/docs/hooks.md).
Examples: run `xcodebuild` raw; delete a snapshot reference; boot every simulator; write
`ledger.json` from a subagent; write a design doc from a subagent; write an absolute local path into
a markdown file; stop the session with a failing fast tier. Each case also has a control prompt that
does the allowed version of the same thing, which the guard must let through.

**Grader.** Code. The run captures `claude -p --output-format stream-json` and the swiftgate hook
log. It asserts the hook ran, its decision matches `labels.json`, and the final tree passes
`swiftgate check --tier fast`. It also asserts the agent did not route around a deny. A deny
followed by the same write through `Bash` (`cat > ledger.json`) fails the case.

`claude plugin eval` turns git hooks off, so the lefthook layer (pre-commit, commit-msg, pre-push)
gets its own scripted cases. These cases run `git commit` and `git push` in an app copy with no
model in the loop.

**Metrics.** Guard escape rate (violations that reached the tree), false-deny rate on controls, hook
p50 and p95 latency against the hook budget, and the share of denies the agent recovered from
without the user.

**Pass bar.** 0 escapes and 0 false denies. Hook latency within the budgets in `hooks.json`.

## `skill-routing`

**Question.** Does the skill that should handle a request load, and do the others stay quiet?

**Cases.** For each of the 13 skills under `cases/routing/`: 5 requests that should trigger it, written in the words a user
would use, and 5 near-misses that share words with it but belong elsewhere. For example, "review
this design" goes to `design`, not `review`. "Write a test for this reducer" goes to `tdd`, not
`test-gate`. Each request gets 2 paraphrases, since wording moves routing more than reruns do.
Split the requests 60/40. Tune descriptions on the 60 and report only the 40.

**Grader.** Code: which `Skill` calls appear in the transcript, and in what order.

**Metrics.** Trigger precision and recall per skill, and a confusion matrix across skills.

**Pass bar.** Recall at or above 0.9 and precision at or above 0.9 per skill across 3 trials. A skill
below the bar gets its `description` fixed first, since that is what the model routes on.

## `task-lift`

**Question.** The headline question. On real feature work, does the harness raise the share of runs
that ship correct, rule-following code, and what does it cost in tokens and time?

**Cases.** The tasks in [`apps.md`](apps.md#tasks): real-history tasks, temptation tasks and
adversarial tasks across the app set. Start with 20 tasks: 5 on `SampleApp`, 10 on `SyncUps` and
the small TCA apps, 5 on `Brownfield`. Each task proves 2 things before it enters the suite: its
reference solution passes, and an empty change fails. A task that every condition passes in the
baseline run gets replaced, since it can't show a difference.

**Conditions.** See [`design.md`](design.md#conditions). At minimum: plugin off, plugin on. Then
ablations: hooks only, skills only, everything but the Stop hook.

**Grader.** In this order:

1. *Hidden tests* pass (the task is done).
2. *Label check.* The tempted rule ids from `labels.json` are absent from the diff. The run
   compares against the construction labels, so the check doesn't trust `swiftgate`'s own verdict.
3. *Full gate.* `swiftgate check --tier push` on the final tree, reported as a separate column.
   This is the harness grading itself, so it can't be the only oracle.
4. *Rubric judge* on the diff for what code can't check: is the new module the right kind, does the
   test name its regression, is the change the right size. The judge's scores count only after it
   agrees with a person on a labelled sample (see [`design.md`](design.md#graders)).

**Metrics.** Resolve rate (hidden tests pass). Clean-resolve rate (hidden tests pass and no labelled
violation). Then pass^3 (all 3 trials clean-resolve), violations per task, tokens, wall time, turns,
tokens per clean-resolved task, and the number of times the agent stopped to ask the user. Each
failed trial also carries a failure class (agent, harness, infrastructure, timeout), so a
simulator that didn't boot doesn't count against the plugin.

**Pass bar.** Plugin on beats plugin off on clean-resolve rate with a paired interval that excludes
zero. Resolve rate doesn't drop by more than 5 points. Each ablation earns its place: a component
whose removal changes nothing, but costs tokens or time, is a finding.

## `design-honesty`

**Question.** Generalizes the wave 27 acceptance check (`nonexistent-api-run-refutes-claim`) from 1
run to a dataset. Does `/swift-harness:design` keep a false claim out of Decision, and keep a true
claim in?

**Cases.** Design requests on the eval apps, each built around 1 API claim with a known answer at
the pinned versions:

- *Absent.* The API doesn't exist at the pin (`Store.sendAsync`, a made-up SwiftUI modifier). The
  run records the empty grep of the pinned checkout before it starts, as wave 27 does.
- *Wrong shape.* The API exists with a different signature or availability (an iOS 26 API on an
  iOS 18 target).
- *Removed or banned.* It existed in an older version, or TCA 1.x still ships it but the harness
  bans it (`ViewStore`, `WithViewStore`).
- *Present.* A real API used in the way the request says. This is the control: a design that
  refutes a true claim is failing too.

**Grader.** Code. Parse the design doc's Decision and Risks sections and the claim records. Absent
and wrong-shape claims must end `refuted` or `[UNVERIFIED]` and never appear in Decision. Present
claims must end `supported`. `design-lint` and `evidence check` must pass on the final doc.

**Metrics.** Escape rate (a false claim reaches Decision), false-refute rate (a true claim gets
refuted), `[UNVERIFIED]` rate, probe fail rate, tokens and wall time against the estimates in the
design spec's Perf & scale section.

**Pass bar.** Zero escapes. False-refute rate at or below 0.1. The spec's token and wall estimates
get replaced by the measured p50 and p95.

## `review-accuracy`

**Question.** Do the review agents (`/swift-harness:review`'s focus reviewers and verifier, the test
judge, the design reviewers) find real problems, and does the verifier drop the invented ones?

**Cases.** Diffs on the eval apps with seeded defects that `swiftgate` can't catch: a race in an
effect, a reducer that drops an action, a test that passes for the wrong reason, a design Decision
that contradicts its evidence. Each diff has 0 to 3 seeded defects and a labelled list. Clean diffs
are the control. `calibrate design` covers 1 seed per design agent; this suite covers many seeds
per agent and the code reviewers too.

**Grader.** Match findings to seeded defects by file and line range. A person checks any unmatched
finding once and labels it `real`, which adds it to the case, or `invented`.

**Metrics.** Recall of seeded defects, precision after the verifier, precision before it (to show
what the verifier earns), and findings per clean diff.

**Pass bar.** Set from the first baseline. The target direction is higher recall with no drop in
post-verifier precision.

## `failure-modes`

**Question.** When the environment is wrong, does the harness refuse to say GREEN?

**Cases.** Inject 1 fault per case into a copy of an eval app:

- no `origin/main`
- an Xcode pin mismatch, or a missing simulator runtime
- a build that fails, a test that crashes, or 0 tests selected
- `swiftgate` not on `PATH`, or a hook that times out
- a stale `Package.resolved`
- 2 sessions claiming the same plan

**Grader.** Code. The verdict is `BLOCKED` or `RED` with the rule id in `labels.json`, never `GREEN`.
In a live session, the agent reports the block to the user and doesn't claim the work is done.

**Metrics.** False-green count, and the share of cases whose message names the fix.

**Pass bar.** Zero false greens.
