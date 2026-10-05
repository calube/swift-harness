# Review contract

Every reviewer and verifier in `/swift-harness:review` follows this contract, and
`swiftgate review-synth` enforces it. Read it to write or verify a finding, or to see why
`review.json` dropped a finding or reached its verdict. Findings cite rules by id from
[standards.md](standards.md) and [testing-playbook.md](testing-playbook.md).

## How a review runs

1. 5 focus reviewers read the review bundle: `concurrency`, `architecture`, `test-quality`,
   `api-errors` and `swiftui`. Only `swiftui` may report itself `not-applicable`.
2. An independent verifier checks each focus's findings.
3. `swiftgate review-synth` drops what fails the contract, merges duplicates, applies the severity
   rules and writes `review.json` and `review-telemetry.json` into the run directory.

`review.json` comes only from `review-synth`; its `telemetry` path is relative.

## Findings

A finding has these fields:

| Field | Holds |
|---|---|
| `kind` | which check the verifier runs on it: `defect` (the code produces a wrong outcome) or `standards-violation` (the code breaks a rule in the standards or the playbook, even when no user sees a wrong outcome today). A finding with no `kind` is a defect. |
| `rule` | the cited rule id, such as `D7`. Required for a standards violation. |
| `severity` | `blocker`, `major`, `minor` or `nit`. |
| `category` | a kebab-case class, such as `data-race` or `layering`. |
| `title` | a 1-line summary. |
| `file`, `line` | the repo-relative path and 1-based line in the new code. Cite the line of the code that is wrong, not a new call site that reaches it. |
| `end_line` | the last line, when the wrong code spans several. |
| `failure_scenario` | for a defect, the concrete input or state and the wrong outcome. For a standards violation, the maintenance or correctness risk the rule prevents, made concrete for this code. |
| `evidence` | the code or gate output that shows it, plus the matched **Tell** for a violation. |
| `fix` | the smallest change that removes the failure. |
| `verified` | the verifier's verdict, `true` or `false`. |
| `verification_note` | what the verifier checked. `review.json` keeps it. |
| `severity_rule` | the [severity rule](#severity) the verifier applied. |
| `downgrade_reason` | why the verifier lowered a standards violation's severity. |

Use `effect-lifetime` as the category for an effect or task that nothing cancels when the state or
screen it serves goes away. Synthesis reads `missing-cancellation` and
`missing-effect-cancellation` as `effect-lifetime`.

### Dropped findings

Synthesis drops a finding, and lists it as dropped with the reason, when:

| Reason | The finding |
|---|---|
| `no-failure-scenario` | has no `failure_scenario` |
| `no-rule-citation` | is a standards violation with no `rule` |
| `unverified` | doesn't have `verified: true` |

A finding the verifier returned no entry for is `unmatched`, not dropped: see [Verdicts](#verdicts).

## Severity

Each severity rule has an id. The verifier records the one it applied as `severity_rule`, and
`review-synth` raises a finding below the rule's severity to it. A rule never lowers a severity.

| Rule | Applies to | Least severity | When |
|---|---|---|---|
| `defect-users-hit` | defects | `blocker` | A defect is a `blocker` when users or callers hit it. A race a user triggers through ordinary use, such as tapping Fact then Dismiss while the request runs, is one. |
| `defect-narrow-trigger` | defects | `major` | its trigger is narrower than ordinary use, such as a timing only a stress load produces. |
| `do-violation` | standards violations | `major` | it breaks a rule's **Do**. |
| `structural-fix` | standards violations | `blocker` | it is an architecture violation with a structural fix, which moves logic across a module boundary or changes a module's kind. |
| `no-harm-yet` | both | `minor` | no concrete harm yet. |
| `taste` | both | `nit` | a matter of taste. |

`review-synth` rejects, with exit 2, a finding whose `severity_rule` the contract states for the
other kind.

## Verification

The verifier gets the findings and the code, never the reviewer's reasoning.

- **A defect.** The verifier reproduces its failure scenario against the code. It may lower the
  severity when the reproduced impact is smaller.
- **A standards violation.** The verifier checks that the cited rule exists, that the diff holds
  the quoted code or makes it reachable, and that the code matches the rule's **Tell** or breaks
  its **Do**.
- **Lowering a standards violation.** The verifier may lower its severity only with a `downgrade_reason`
  showing the rule doesn't apply or an exception covers the code. Otherwise the workflow restores
  the reviewer's severity. "No user sees it today" is never a reason.
- **Raising.** The verifier raises severity only through `severity_rule`, which `review-synth`
  enforces.

## Dedupe

Synthesis merges same-file findings whose line ranges overlap or lie within 3 lines of each other.
For example, 3 reviewers citing 1 race at lines 67, 69 and 70 merge into 1 finding.

- **What matches.** Defects merge on category, standards violations on rule. A defect citing no
  rule joins the single nearby rule of its category.
- **What the merged finding keeps.** The most severe copy, every focus and cited line, and each
  distinct `evidence`. A copy citing a rule sets its `kind` and `rule`, and the strongest
  `severity_rule` stays.
- **Which copy leads.** Among copies of the same severity, the earliest line leads, then the focus
  first in panel order, then the copy reported first.

## Pre-existing defects

A verified finding on code the diff didn't add or change is pre-existing. `review-synth` reports it
in a separate pre-existing section with its severity, and it never counts toward the verdict.

`review-synth` reads the changed code from the bundle's `diff-numbered.txt` (manifest
`artifacts.numberedDiff`), never from an agent's opinion. The changed code is the added lines, and
the lines on either side of a removal.

- A finding counts when any line from `line` to `end_line` is a changed line.
- A finding in a file the diff doesn't touch is pre-existing.
- A finding with no line counts.
- When `review-synth` can't read the numbered diff, every finding counts and the summary says why.

## Verdicts

The verdict is a literal string: `merge`, `fix-then-merge` or `refactor-needed`.

| Verdict | When |
|---|---|
| `refactor-needed` | a verified `blocker` from the architecture focus |
| `fix-then-merge` | any other verified `blocker` or `major`; or any focus not reviewed; or any `unmatched` finding that isn't pre-existing |
| `merge` | anything else |

Only findings on code the diff changed count. A reviewer that fails, or gives no result, leaves its
focus not reviewed. A finding the verifier returned no entry for stays in `review.json` as
`unmatched`.
