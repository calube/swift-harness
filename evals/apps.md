# Eval apps

The apps the eval suites run agents against. Each app is a fixture: pinned to a commit, stamped by
`swiftgate bootstrap`, and copied into a throwaway repo before every trial, the same way
[`docs/e2e-report.md`](../docs/e2e-report.md) proved `examples/SampleApp`. A trial never runs in
this repo's checkout, and it never touches the real `HOME`.

## What an eval app needs

- **Pinned source.** A commit SHA and a `Package.resolved`. A trial that drifts to a newer TCA isn't
  the same trial.
- **A GREEN baseline.** `swiftgate check --tier push` passes on the untouched app. A task that starts
  RED can't tell a regression from the starting state.
- **Hidden tests per task.** The grader copies them in after the agent finishes. The agent never
  sees them, so it can't write to them or delete them.
- **A known violation inventory.** For brownfield apps, a labelled list of every violation already
  in the tree, so a finding on untouched code doesn't count against the agent.
- **A license that allows copying.** MIT or our own code.

## The set

| App | Source | Size | Why it's in the set |
|---|---|---|---|
| `SampleApp` | `examples/SampleApp` (ours) | 5 packages | Smoke tier. Every suite runs here first because a trial costs the least. It already has an end-to-end record. |
| `SyncUps` | TCA `Examples/SyncUps` at the pinned TCA tag (MIT) | 1 app, about 15 files | The canonical TCA 1.x app: navigation stacks, sheets, alerts, persistence, speech, a clock. It holds every kind of task the harness claims to help with. |
| `Todos`, `VoiceMemos`, `Search` | TCA `Examples/` (MIT) | small | Cheap variety. `Search` hits the network, `VoiceMemos` hits audio and the clock, so each tempts a different nondeterminism rule. |
| `Greenfield` | an empty repo plus a 1-page product brief (ours) | 0 files | Tests the path a new adopter takes: bootstrap, `architecture`, `design`, `plan`, then a first feature. |
| `Brownfield` | a SwiftUI MVVM app we write with singletons, `Date()`, `print`, UIKit in shared code (ours) | about 20 files | Tests adoption on code that breaks the rules today: false-positive noise, whether the agent fixes only what it touched, whether hooks block unrelated work. |
| `timed-build-starter` | `evals/apps/timed-build-starter` (ours) | 3 packages | A rehearsal fixture for timed `ship` runs, not a suite app: no hidden tests, no graded tasks. A warm, GREEN TCA starter plus 3 practice specs in `specs/`, for tuning the `timed` preset. |

The TCA examples need a light port before they qualify: split the feature into a Core package and
an app target, add `[[modules]]` entries, and route the clock and UUID through `@Dependency` where
the example doesn't already. The port lands as the app's pinned baseline commit. A port that has to
change behaviour to pass the gate is a finding about the harness, and the port notes record it.

`Greenfield` and `Brownfield` are ours, so no model has seen them in training. The TCA examples are
public and likely in training data. That matters less here than for a model benchmark, because the
tasks and hidden tests are ours, but the suite reports public-app and private-app results apart so
a gap between them is visible.

## Tasks

Planned: no `evals/tasks/` directory exists yet. A task will be a directory under
`evals/tasks/<app>/<task-slug>/` holding:

- `prompt.md`: what the user types, written the way a user would write it. No hints about harness
  rules unless the task is about them.
- `hidden-tests/`: tests the grader adds after the run. Each one fails on the baseline commit and
  passes on the reference solution, and the task records both runs.
- `reference/`: a patch that solves the task within the rules, written by a person. It proves the
  task is solvable and gives the hidden tests their green run.
- `labels.json`: what the task tempts (rule ids), what a compliant run must do (skills, hooks,
  commands), and what it must never do.
- `task.json`: app, baseline SHA, tier, time and token caps, and the suites that use it.

Task sources, in order of preference:

1. **Real history.** A commit from the app's own log (SWE-bench style): revert it, write the issue
   it fixed as the prompt, and use its tests as hidden tests.
2. **Temptation tasks.** Ordinary feature work whose easy path breaks a rule. For example "show the
   time the sync-up started" tempts `det.date-init`; "log when a meeting ends" tempts `obs.print`.
3. **Adversarial tasks.** A prompt that asks for the violation outright ("use `Date()` here,
   it's fine") to measure whether the harness holds when the user pushes.

Every task gets a person's review before it enters a suite: is the prompt clear, is the reference
solution right, do the hidden tests fail on the baseline for the reason the task names. An
ambiguous task produces noise that looks like a harness failure.
