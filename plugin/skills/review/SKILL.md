---
name: review
description: This skill should be used to run the swift-harness multi-agent code review on a Swift change — gather the gate evidence with swiftgate review-input, run parallel focus reviewers (concurrency, architecture and TCA fit, test quality, API and errors, SwiftUI when touched) each checked by an independent verifier, then synthesize a merge / fix-then-merge / refactor-needed verdict with swiftgate review-synth. Load it whenever the user wants a verdict on whether a Swift change should merge, however they ask: would you approve it or sign off on it, what blocks it, is it good enough to go in, even when they say to leave the tests out of it. Use when the user says "review this change", "review my branch", "run the review panel", "is this mergeable", "would you approve this", "/swift-harness:review", or after /swift-harness:test-gate passes and before asking a human to review. Not for judging only the tests (use test-gate), writing PR evidence text (use validate), or explaining a diff without a verdict.
---

# Review

Invoking this skill is the user's opt-in to run the review workflow: one reviewer per focus (4, or
5 when the diff touches SwiftUI) plus one verifier for each reviewer that reports findings, so 4 to
10 top-tier agents. Wall time is about the slowest reviewer plus its verifier. Gather and synthesis
are deterministic `swiftgate` commands; only review and verification use agents.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Pass `--base <ref>` when the branch doesn't target
`origin/main`.

## 1. Gather

Run `"$SG" review-input --json` from the project root (the directory holding `.swiftgate.toml`).
After a GREEN push gate it also runs `mutate` on the changed lines, which can take minutes; its
verdict is a manifest note and never stops the review.

- Exit 1 (RED) or 2 (BLOCKED): the push gate is not GREEN, so stop. Report the gate's findings as
  `file:line rule — message` and hand off to `/swift-harness:test-gate` (RED) or `"$SG" doctor`
  (BLOCKED). Reviewing code that fails its own gate wastes the panel.
- Exit 0: stdout is the bundle manifest. Keep `runID`, `focuses` and `changedFiles`. The bundle is
  `.harness/runs/<runID>/review-input/` under the project root; use its absolute path.

Size check: count changed lines in the bundle's `diff.patch` (`grep -c '^[+-]' diff.patch`). Over
about 1,500, ask the user with `AskUserQuestion` whether to review the whole diff or split it by
module before launching; a large diff multiplies the panel's cost.

## 2. Review and verify

Tell the user the panel is starting and how many agents it uses (one reviewer per focus, and a
verifier only for a reviewer that reports findings). Then run:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/review.js",
  args: {
    bundle: "<absolute bundle path>",
    focuses: <manifest focuses>,
    pluginRoot: "${CLAUDE_PLUGIN_ROOT}"
  }
})
```

`pluginRoot` must be the absolute path: a workflow script can't read the environment, and the
agents need it to open the plugin's `docs/standards.md` and `docs/testing-playbook.md`, which are
not in the project under review.

Surface the workflow's `log()` lines as they arrive. It returns `{bundle, reviews}`: one object per
focus, already in the shape `review-synth` reads. A reviewer or verifier that died comes back as
`status: "not-reviewed"`; keep it, never re-label it.

If the Workflow tool is not available in this session, run the same pipeline with the Agent tool:
for each focus in `focuses`, launch `swift-harness:<focus>` (all in one message), and as each
returns findings, launch `swift-harness:verifier` with only those findings, the bundle path and the
absolute docs paths, never the reviewer's reasoning. Give every prompt the absolute paths
`${CLAUDE_PLUGIN_ROOT}/docs/standards.md`, `${CLAUDE_PLUGIN_ROOT}/docs/testing-playbook.md` and
`${CLAUDE_PLUGIN_ROOT}/docs/review-contract.md`. Build the
per-focus objects exactly as `reconcile()` in `workflows/review.js` does: keep the reviewer's
`kind`, `rule`, category and location; keep the verifier's `verification_note` and a
`severity_rule` stated for the finding's kind; accept a lower
severity for a `standards-violation` only when the verifier gave a `downgrade_reason`; unverified
findings keep `verified: false`, a finding the verifier returned no entry for gets
`verified: false, unmatched: true`, a failed agent gives `not-reviewed`, and an absent `swiftui`
focus gives `not-applicable`.

## 3. Synthesize

Write each returned review object verbatim as JSON to
`.harness/runs/<runID>/review-findings/<focus>.json` (the files are the audit trail; don't edit
findings), and the whole workflow return value verbatim to
`.harness/runs/<runID>/review-workflow.json`: its `telemetry` holds the token count the runtime
reported. Then run:

```
"$SG" review-synth --run-directory .harness/runs/<runID> --workflow-result .harness/runs/<runID>/review-workflow.json .harness/runs/<runID>/review-findings/*.json
```

Leave out `--workflow-result` only when the panel ran through the Agent tool fallback; the
telemetry file then says the tokens are unavailable.

It drops findings without a failure scenario, standards violations that cite no rule, and
findings the verifier refuted, and lists `unmatched` findings (which keep the verdict off
`merge`). It raises a finding to the severity its `severity_rule` states. It merges same-kind
findings in a file whose lines are within 3 of each other. It files findings on code the diff
didn't add or change (read from `review-input/diff-numbered.txt`) as pre-existing, outside the
verdict. It then applies the verdict rule, writes `review.json` and `review-telemetry.json` (wall
time since `review-input` started, and the workflow's reported output tokens and agent calls),
and prints at most 30 lines. Exit 2 means an input broke the contract: fix the file you wrote,
don't hand-edit the verdict.

## 4. Report

Relay the summary as printed: the verdict first (`merge`, `fix-then-merge` or `refactor-needed`),
any `NOT REVIEWED` focus and `UNMATCHED AT VERIFY` finding, then the top findings with `file:line`, scenario and fix.
Then relay the `PRE-EXISTING` line (reported, never part of the verdict) and the `telemetry:` path. Don't add
findings the panel didn't verify and don't soften the verdict.

- `refactor-needed`: a verified architecture blocker, usually a `standards-violation` whose fix
  moves logic across a module boundary. Say what structure has to change, cite the rule, and
  propose the design; don't patch lines.
- `fix-then-merge`: offer to fix the blocker and major findings, then re-run `check --tier push`
  and this review. A `NOT REVIEWED` focus alone also gives this verdict: re-run the review.
- `merge`: say so, and list minor and nit findings as optional.
