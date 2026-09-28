# Review contract

Every reviewer and verifier in `/swift-harness:review` follows this contract. Findings cite rules by
id from [standards.md](standards.md) and [testing-playbook.md](testing-playbook.md).

## Findings

A finding has these fields:

- `kind`: which check the verifier runs on it.
  - `defect`: the code produces a wrong outcome. A finding with no `kind` is a defect.
  - `standards-violation`: the code breaks a rule in the standards or the playbook, even when no
    user sees a wrong outcome today.
- `rule`: the cited rule id, such as `D7`. Synthesis drops a standards violation without one.
- `severity`: `blocker`, `major`, `minor` or `nit`.
- `category`: a kebab-case class. Use `effect-lifetime` for an effect or task that nothing
  cancels when the state or screen it serves goes away; synthesis reads `missing-cancellation`
  and `missing-effect-cancellation` as `effect-lifetime`.
- `file` and `line`: the repo-relative path and 1-based line in the new code. Cite the line of the
  code that is wrong, not a new call site that reaches it. `end_line` is the last line when the
  wrong code spans several.
- `failure_scenario`: for a defect, the concrete input or state and the wrong outcome. For a
  standards violation, the maintenance or correctness risk the rule prevents, made concrete for
  this code. The verifier drops a finding without one.
- `evidence`: the code or gate output that shows it, plus the matched **Tell** for a violation.
- `fix`: the smallest change that removes the failure.

## Severity

Each rule has an id. The verifier records the one it applied as `severity_rule`, and
`review-synth` raises a finding below the rule's severity to it. A rule never lowers a severity.

- `defect-users-hit`: A defect is a `blocker` when users or callers hit it. A race a user triggers
  through ordinary use, such as tapping Fact then Dismiss while the request runs, is one.
- `defect-narrow-trigger`: a defect is `major` when its trigger is narrower than ordinary use,
  such as a timing only a stress load produces.
- `do-violation`: a violation of a rule's **Do** is at least `major`.
- `structural-fix`: an architecture violation with a structural fix is a `blocker`. A structural
  fix moves logic across a module boundary, or changes a module's kind.
- `no-harm-yet`: `minor`, no concrete harm yet. `taste`: `nit`.

The two `defect-` rules apply only to defects, and `do-violation` and `structural-fix` only to
standards violations. `review-synth` rejects a finding whose rule the contract states for the
other kind.

## Verification

The verifier gets the findings and the code, never the reviewer's reasoning.

- For a defect, the verifier reproduces its failure scenario against the code. It may lower the
  severity when the reproduced impact is smaller.
- For a standards violation, the verifier checks that the cited rule exists, that the diff holds
  the quoted code or makes it reachable, and that the code matches the rule's **Tell** or breaks
  its **Do**.
- The verifier may lower a standards violation only with a `downgrade_reason` showing the rule
  doesn't apply or an exception covers the code. Otherwise the workflow restores the reviewer's
  severity. "No user sees it today" is never a reason.
- The verifier raises severity only through `severity_rule`, which `review-synth` enforces.
  `review.json` keeps its `verification_note`.

## Dedupe

Synthesis merges same-file findings whose line ranges overlap or lie within 3 lines: 3 reviewers
once cited 1 race at lines 67, 69 and 70. Defects merge on category, standards violations on
rule, and a defect citing no rule joins the single nearby rule of its category. The merged finding keeps the most severe copy, every focus and cited line, and each
distinct `evidence`. A copy citing a rule sets its `kind` and `rule`, and the strongest
`severity_rule` stays. Among copies of the same severity the earliest line leads, then the focus
first in panel order, then the copy reported first.

## Pre-existing defects

A verified finding on code the diff didn't add or change is pre-existing. `review-synth` reports
it in a separate pre-existing section with its severity, and it never counts toward the verdict.
`review-synth` reads the code the diff changed from the bundle's `diff-numbered.txt` (manifest
`artifacts.numberedDiff`), never from an agent's opinion: its added lines, and the lines on
either side of a removal. A finding counts when any line from `line` to `end_line` is one of them.
A finding in a file the diff doesn't touch is pre-existing. A finding with no line counts. When
`review-synth` can't read the numbered diff, every finding counts and the summary says why.

## Verdicts

The verdict is a literal string: `merge`, `fix-then-merge` or `refactor-needed`.

- A verified architecture `blocker` gives `refactor-needed`.
- Any other verified `blocker` or `major` gives `fix-then-merge`.
- Anything else gives `merge`.

Only findings on code the diff changed count. A reviewer that fails leaves its focus not
reviewed, and the verdict can't be `merge` while any focus is unreviewed. A finding the verifier
returns no entry for stays in `review.json` as `unmatched`, which likewise keeps the verdict off
`merge` unless it is pre-existing.

`review.json` comes only from `review-synth`; its `telemetry` path is relative.
