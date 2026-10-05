# 0001. Review severity for standards violations

Status: accepted 2026-09-25, built. Refines the review verdict contract and the verify step of the
[Foundation design](../designs/2026-09-24-swift-harness-foundation-design.md) (§9.1, §9.2 step 3). Where they
differ, this record is the current contract.

## Context

We ran the review panel end to end on a seeded design smell in the sample app: a change to
`APIClientLive` that truncated cat facts to 120 characters for the counter screen. That's a display
rule inside a Live client, so it runs in no `TestStore` test or preview, and changing the layout
means editing the networking module. The expected verdict was `refactor-needed`. The panel returned
`merge`.

The architecture reviewer found the problem and traced it correctly, but filed it as `minor`, and
its verifier confirmed it at `minor`. Six harness defects produced that result:

1. **Severity only described user-visible defects.** The contract defined `blocker` as a defect
   users hit, and the verifier confirmed a finding only by reproducing a wrong outcome. A
   structural violation has no wrong outcome today, only a risk the rule exists to prevent. So a
   reviewer that called it a `blocker` couldn't have it verified, and a `minor` was the only
   rating that survived. The synthesizer's rule (a verified architecture blocker is
   `refactor-needed`) could never fire for design findings.
2. **No rule covered the smell.** `plugin/docs/standards.md` said what a Live module may contain (D2)
   but not what it must not do, so the reviewer argued from D2 and A5 and neither rule fit.
3. **Wrong rule anchors.** `plugin/agents/api-errors.md` cited A3, D2 and C4 for API misuse, access
   level and retries. Those rules cover TCA feature shape, client pairs and cancellation.
4. **Agents couldn't find the standards.** The prompts said "the plugin's `docs/standards.md`"
   but gave no path, and the project under review has no `docs/standards.md`.
5. **The workflow dropped the verifier's reasoning.** `reconcile()` in `plugin/workflows/review.js` discarded
   `verification_note`, so `review.json` couldn't show why a finding was confirmed or refuted.
6. **The review skill stated the wrong agent count.** It said 8–10 agents, but the workflow skips
   the verifier when a reviewer reports nothing.

## Decision

Findings carry a `kind`, and each kind has its own verification rule.

- **`defect`**: the code produces a wrong outcome. It's verified by reproducing the failure
  scenario against the code, as before. A finding with no `kind` is a defect, so older focus
  files still decode.
- **`standards-violation`**: the code breaks a rule in `plugin/docs/standards.md` or
  `plugin/docs/testing-playbook.md`. It's verified by 3 things: the cited `rule` exists, the quoted
  code is in the diff or made reachable by it, and the code matches the rule's **Tell** or breaks
  its **Do**. Its `failure_scenario` names the maintenance or correctness risk the rule prevents,
  made concrete for this code. A violation that cites no rule is dropped at synthesis
  (`no-rule-citation`).

Severity for standards violations:

- A violation of a rule's **Do** is at least `major`.
- An architecture violation whose fix is structural (logic moves across a module boundary, or the
  module is the wrong kind) is a `blocker`. The synthesizer's rule is unchanged, so a verified one
  gives `refactor-needed`.
- The verifier may lower a standards violation only with evidence that the rule doesn't apply or
  that an exception covers the code, given in `downgrade_reason`. The workflow restores the
  reviewer's severity when no reason is given. "No user sees it today" is not a reason; that's
  what the kind means. The verifier may still lower a defect when the reproduced impact is
  smaller, and may never raise severity.

Supporting changes:

- New rule **D7**: Live clients perform IO and decode or map to domain models; no business rules
  or transformations. It's in the architecture reviewer's rubric.
- `plugin/agents/api-errors.md` marks rows with no standards rule as `—`, reportable only as defects. A
  test fails when any rule id cited in `plugin/agents/*.md` or `plugin/skills/*/SKILL.md` is missing from the
  standards or the playbook. It can't catch a real rule cited for the wrong reason; that still
  needs review.
- The review skill passes `pluginRoot` (from `${CLAUDE_PLUGIN_ROOT}`) to the workflow, because a
  workflow script can't read the environment or the filesystem. Every reviewer and verifier prompt
  gets absolute paths to the standards, the playbook and this record.
- `verification_note` is kept through `reconcile()` and in `ReviewFinding.verificationNote`, so it
  appears in `review.json`. `ReviewFinding` also gains `kind` and `rule`. All three fields are
  optional and additive, so the focus-file schema version stays 1.

## Consequences

- Architecture findings can reach `refactor-needed` without a reproduced runtime failure. The
  seeded smell now yields a D7 `blocker` and `refactor-needed`.
- The rules become the panel's source of truth for structural findings. A structural smell with
  no rule can only be filed as a defect, so gaps like the one D7 fills show up as design findings
  that can't be verified. The fix for those is a new rule, not a looser verifier.
- Reviewers and verifiers have to read the rules they cite. That adds a little reading per
  finding, and in exchange a verifier can check a citation mechanically instead of taking the
  reviewer's word.
- The verifier has more room to confirm findings. Two guards limit false positives: a rule
  citation is required, and the rule's **Tell** must match the quoted code. The anchor test keeps
  citations pointing at rules that exist.
- `reconcile()` has a unit test (`tests/review_workflow_test.mjs`, run with `node`). The
  agent-tool fallback in the review skill has to follow the same rules by hand.
