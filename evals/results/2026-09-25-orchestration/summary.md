# Workflow orchestration, 2026-09-25

The orchestration cases in `components.md` for the 3 workflows, run against stand-in agents. They
make no model calls and cost 0 USD. The gate's `swift test` finds every `tests/*_test.mjs`, so the
new cases run on every push.

## Coverage before and after

| Workflow | Case in `components.md` | Covered by |
|---|---|---|
| `design-research.js` | 1 lane fails: `NOT RESEARCHED`, the others finish, the design can't reach ready | existing: dead lane, `result.status` incomplete |
| | a lane asks the user: halt, and on resume only that lane re-runs | existing: 4 ask and resume tests |
| | 4 lanes: no more than 3 at once | existing |
| | an unknown citation kind is rejected | existing: the malformed-lane table includes `citation.kind` |
| `design-review.js` | each tier runs its reviewer set | existing |
| | each reviewer's findings go to its own verifier | existing: verifier tests |
| | a dead reviewer is `NOT REVIEWED` and blocks ready | existing, including the real `review-synth --design` |
| | a revise round re-runs only the reviewers it names | existing |
| `review.js` | SwiftUI reviewer only when the diff touches SwiftUI | **new**: 2 cases |
| | a dead reviewer is `NOT REVIEWED` and the verdict can't be merge | **new**: dead and thrown reviewers, dead and thrown verifiers |
| | synthesis goes through `swiftgate review-synth` | **new**: the return fed to the real `review-synth`, with a merge control, an unreviewed focus and an architecture blocker |
| | (added) a verifier's partial or reordered answer verifies nothing it doesn't match | **new** |

The design workflows already had every case. `review.js` had none of its 3.

## Why the existing `review.js` test missed them

`tests/review_workflow_test.mjs` stubs `pipeline` with `Promise.all`, so 1 throwing stage fails the
whole run. The workflow runtime turns that item into `null` and keeps its siblings. The new file
stubs `pipeline` the way the runtime behaves, so it can see a single reviewer dying.

## Red-first proof

On scratch branches (deleted after), 6 planted breaks in `workflows/review.js`, 1 at a time:

| Planted break | Tests that failed |
|---|---|
| every focus runs, `swiftui` included | the no-SwiftUI case |
| `not-applicable` pushed beside a real `swiftui` review | the SwiftUI case |
| a dead focus dropped from the return | the dead-reviewer and dead-verifier cases |
| a dead verifier passes its findings through unverified | the dead-verifier case |
| `reconcile` ignores file and line | the partial-answer case |
| `schemaVersion: 2` on a clean review | the `review-synth` case, with `unsupportedSchemaVersion(2)` |

A dropped focus alone doesn't fail the `review-synth` case, because the gate counts a missing
focus as `NOT REVIEWED`. The 2 layers back each other up.

## Harness defects found

None. `review.js` holds its contract. The gap was in the test.
