# Component evals

Evals for each skill, agent, workflow and rule on its own inputs. The suites in
[`suites.md`](suites.md) grade whole sessions. When a whole task fails, they can't say which part
failed. A component eval can, and it costs less to run. `task-lift` then checks that the parts add
up.

## How component evals differ from the suites

- **Fixed inputs.** Each case hands the component the exact input it gets in production: a
  diff, a claim record, a design doc, a context pack. No upstream agent runs, so upstream noise
  doesn't reach the grade.
- **The contract is the spec.** Each component's grader checks the promise its own file makes (the
  skill's `description` and steps, the agent's output schema, the workflow's header), plus the
  design section that owns it.
- **Balanced case sets.** Each set has cases where the component must act and cases where it
  must not: a clean diff for a reviewer, a true claim for the claim checker, a compliant comment
  for `comment-audit`.
- **Same trials and statistics as the suites.** 3 trials per case, pass^3 as the headline,
  intervals over cases. See [`design.md`](design.md#trials-and-statistics).

What already exists, and stays: `tests/*.mjs` check agent and workflow files for structure
(model, tools, output schema) with no model calls. `calibrate design` runs 1 labelled seed per
design agent on every push. `gate/Fixtures/judge` holds labelled cases for the test judge. The
evals below grow those seeds into sets large enough to measure a rate.

## Skills

Graded on behaviour after the skill loads. `skill-routing` covers whether it loads.

| Skill | Contract to grade | Cases | Grader |
|---|---|---|---|
| `tdd` | names the regression; the test fails on an assertion, not a build error, before the fix; green after; `prove` passes | 10 small behaviour changes on the eval apps; 3 where the right test already exists | trajectory: `swiftgate` RED on the new test before any production edit, then GREEN; hidden tests; `prove.*` clean |
| `architecture` | picks the module kind from fit signals; scaffolds the right pair; `swiftgate arch` passes | 12 module requests with a labelled kind (2 or more per kind: feature, engine, render, library, client); 3 that belong in an existing module | kind matches the label; `arch` GREEN; no new module for the 3 negatives |
| `bootstrap` | shows the diff and asks before writing; infers `.swiftgate.toml`; a second run changes nothing | the eval apps with harness files removed; 1 app already bootstrapped | `AskUserQuestion` or a stop comes before any write; file set matches the label; second run reports 0 to write |
| `comment-audit` | KEEP, TRIM or CUT per added comment, with evidence; never blocks | 40 labelled comments from real diffs: 15 keep, 10 trim, 15 cut | agreement with a person per label, reported as precision and recall per decision |
| `test-gate` | runs push, judges changed tests for slop, then ready; reports what didn't run | 8 diffs: 4 with slop the tools miss (a test that asserts its own double, a name that doesn't say what broke), 4 clean | slop flagged in the 4, none in the clean 4; tiers ran in order |
| `validate` | runs ready; the PR block carries verdicts, counts and durations that match the run report; lists anything not run | 5 changes, 1 with a tier BLOCKED | every number in the block matches `report.json`; a BLOCKED tier appears as not run, never as passed |
| `review` | gathers evidence, runs the right reviewers (SwiftUI only when touched), synthesizes 1 verdict | the `review-accuracy` diffs, run through the skill | reviewer set matches the diff; verdict matches the label; see the review agents below |
| `design` | frame questions go through `AskUserQuestion`; tier comes from `design-scope`; nothing unproven reaches Decision | the `design-honesty` requests, plus 4 at each tier | question tool used; tier matches `design-scope`; the `design-honesty` grader |
| `plan` | refuses without the claim or with a mismatched `designSha`; ledger passes `plan-lint` | 4 approved designs; 2 with a stale approval; 1 with no claim | refusal on the 3 negatives; `plan-lint` GREEN on the 4; every requirement covered |
| `prose` | a draft written under the skill passes `swiftgate prose` on the first run | 10 writing tasks (an ADR, a design section, a doc) | first-run `prose` finding count, compared with the same tasks without the skill |
| `status` | lists every active plan across registered repos with its RESUME line | a scratch `HOME` with 3 repos: 2 with plans, 1 with a stale entry | listed plans match the index files; the stale repo is reported, not skipped |

## Agents

Graded on fixed inputs through the workflow's own schema check. A reply that fails the schema is a
failed case.

### Review agents

| Agent | Cases | Metrics |
|---|---|---|
| `concurrency` | seeded data races, actor isolation leaks, a `Sendable` claim that is false, missing cancellation; clean async code | recall, precision, findings per clean diff |
| `architecture` | a feature importing a `*Live` module in a way the gate can't see, wrong module kind, a reducer doing IO; clean diffs | same |
| `test-quality` | tests that pass for the wrong reason, over-mocked tests, a name that doesn't say what broke; the `gate/Fixtures/judge` cases as a start | same, plus agreement with the existing judge labels |
| `api-errors` | swallowed errors, a public type that leaks an implementation detail, an error with no recovery path; clean APIs | same |
| `swiftui` | state held in the wrong place, identity bugs in `ForEach`, work in `body`; plus a diff with no SwiftUI, where the agent must not run | same, plus a run check on the no-SwiftUI diff |
| `verifier` | each reviewer's findings on the diffs above, half real and half invented, labelled | real findings kept (it must not drop them) and invented findings dropped, reported apart |

The verifier's 2 rates matter more than any one reviewer's. A verifier that drops real findings
hides every reviewer's recall.

### Design agents

| Agent | Cases | Grader |
|---|---|---|
| `design-lane-codebase`, `design-lane-packages`, `design-lane-apple-docs`, `design-lane-prior-decisions` | 10 questions per lane with a known answer in the pinned sources; 3 per lane with no answer | every citation resolves and its quote matches the file (`evidence check`); the answer matches the label; the 3 with no answer come back `[UNVERIFIED]`, not guessed |
| `design-claim-checker` | 30 claim records: accurate quotes, overstated claims, quotes out of context | agreement with labels, as precision and recall on `refuted` |
| `design-drafter` | 6 frame-and-research bundles | `design-lint` and `docs-lint` finding count on the first draft; every Decision bullet cites a supported claim |
| `design-decomposer` | 4 approved designs with a labelled reference plan | `plan-lint` GREEN; every requirement mapped; write sets that don't overlap within a wave; task count within 30% of the reference |
| `design-evidence-auditor` | designs with a Decision that contradicts its evidence; clean designs | recall and precision by section anchor |
| `design-standards-conformance` | designs that put UIKit in Core, skip `@Dependency` for a clock, add a singleton; clean designs | same |
| `design-challenger`, `design-pre-mortem` | designs that rest on a probe-refuted API or a risk nobody listed; clean designs | same; a finding a person marks real but unlabelled joins the case |

## Workflows

2 kinds of case per workflow. Orchestration cases replace each agent with a scripted stand-in
that returns a fixed reply, a malformed reply or a failure, so they need no model calls and run in
seconds. End-to-end cases run the real agents on 1 eval app.

| Workflow | Orchestration cases | End-to-end cases |
|---|---|---|
| `design-research.js` | 1 lane fails: result says `NOT RESEARCHED` for it, the others finish, the design can't reach ready. A lane asks the user: the workflow halts, and on resume only that lane re-runs. 4 lanes: no more than 3 run at once. A lane returns an unknown citation kind: rejected. | 3 design requests on `SampleApp`; every lane's citations pass `evidence check` |
| `design-review.js` | each tier runs its reviewer set; each reviewer's findings go to its own verifier; a dead reviewer yields `NOT REVIEWED` and blocks ready; a revise round re-runs only the reviewers it names | the `review-accuracy` design cases |
| `review.js` | SwiftUI reviewer only when the diff touches SwiftUI; a dead reviewer yields `NOT REVIEWED` and the verdict can't be merge; synthesis goes through `swiftgate review-synth` | the `review-accuracy` code diffs |

The orchestration cases are deterministic, so they belong in `tests/*.mjs` next to the structure
tests and run on every push. Only the end-to-end cases are evals.

## Rules

`checker-accuracy` in [`suites.md`](suites.md#checker-accuracy) covers the Swift code rules. The
same method, planted defects plus near-miss and clean corpora with no model calls, extends to the
doc and plan gates:

| Gate | Planted defects | Clean corpus |
|---|---|---|
| `prose` | 1 per rule, plus evasions (an em-dash as `--`, an adverb in a heading) | this repo's `evals/` docs and every design doc that passes today |
| `docs-lint` | dangling id, unreachable doc, local path, over-budget file | a stamped consumer repo's docs |
| `design-lint` | untagged Decision, citation to a refuted claim, Architecture without Mermaid | the designs the `design-honesty` runs approve |
| `plan-lint` | cycle, overlapping wave, oversize task, uncovered requirement | the ledgers the `plan` skill produces |
| `evidence check` | forged quote, wrong file, wrong pin, tampered capture | the evidence of every approved design |

`self-test` already holds 1 seed per rule for each of these. The eval adds the evasions and the
clean corpus, which is where a false positive shows up.

The `judge.*` rules come from a model, so they need judge calibration instead: at least 30
labelled cases per rule, with true-positive and true-negative rates, rechecked when the judge's
prompt or model changes. `gate/Fixtures/judge` is the start of that set.

## Order

1. Workflow orchestration cases and rule corpora: no model calls, run on every push.
2. Verifier, claim checker and research lanes: the agents the others lean on.
3. The remaining review and design agents.
4. Skill behaviour, after `skill-routing` shows each skill loads.
