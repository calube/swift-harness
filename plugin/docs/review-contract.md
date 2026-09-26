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
- `category`: a kebab-case class. Synthesis merges findings with the same file, line and category.
- `file` and `line`: the repo-relative path and 1-based line in the new code.
- `failure_scenario`: for a defect, the concrete input or state and the wrong outcome. For a
  standards violation, the maintenance or correctness risk the rule prevents, made concrete for
  this code. The verifier drops a finding without one.
- `evidence`: the code or gate output that shows it, plus the matched **Tell** for a violation.
- `fix`: the smallest change that removes the failure.

## Severity

- A defect is a `blocker` when users or callers hit it, and `major` when its trigger is narrower.
- A violation of a rule's **Do** is at least `major`.
- An architecture violation with a structural fix is a `blocker`. A structural fix moves logic
  across a module boundary, or changes a module's kind.
- `minor` has no concrete harm yet. `nit` is taste.

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
- The verifier never raises severity. `review.json` keeps its `verification_note`.

## Verdicts

The verdict is a literal string: `merge`, `fix-then-merge` or `refactor-needed`.

- A verified architecture `blocker` gives `refactor-needed`.
- Any other verified `blocker` or `major` gives `fix-then-merge`.
- Anything else gives `merge`.

A reviewer that fails leaves its focus not reviewed, and the verdict can't be `merge` while any
focus is unreviewed.
