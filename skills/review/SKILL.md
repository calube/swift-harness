---
name: review
description: This skill should be used to run the swift-harness multi-agent code review on a Swift change — gather the gate evidence with swiftgate review-input, run parallel focus reviewers (concurrency, architecture and TCA fit, test quality, API and errors, SwiftUI when touched) each checked by an independent verifier, then synthesize a merge / fix-then-merge / refactor-needed verdict with swiftgate review-synth. Use when the user says "review this change", "review my branch", "run the review panel", "is this mergeable", "/swift-harness:review", or after /swift-harness:test-gate passes and before asking a human to review.
---

# Review

Invoking this skill is the user's opt-in to run the review workflow (8–10 agents, top-tier model,
wall time about the slowest reviewer plus its verifier). Gather and synthesis are deterministic
`swiftgate` commands; only review and verification use agents.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Pass `--base <ref>` when the branch doesn't target
`origin/main`.

## 1. Gather

Run `"$SG" review-input --json` from the project root (the directory holding `.swiftgate.toml`).

- Exit 1 (RED) or 2 (BLOCKED): the push gate is not GREEN, so stop. Report the gate's findings as
  `file:line rule — message` and hand off to `/swift-harness:test-gate` (RED) or `"$SG" doctor`
  (BLOCKED). Reviewing code that fails its own gate wastes the panel.
- Exit 0: stdout is the bundle manifest. Keep `runID`, `focuses` and `changedFiles`. The bundle is
  `.harness/runs/<runID>/review-input/` under the project root; use its absolute path.

Size check: count changed lines in the bundle's `diff.patch` (`grep -c '^[+-]' diff.patch`). Over
about 1,500, ask the user with `AskUserQuestion` whether to review the whole diff or split it by
module before launching; a large diff multiplies the panel's cost.

## 2. Review and verify

Tell the user the panel is starting and how many agents it uses (one reviewer plus up to one
verifier per focus). Then run:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/review.js",
  args: { bundle: "<absolute bundle path>", focuses: <manifest focuses> }
})
```

Surface the workflow's `log()` lines as they arrive. It returns `{bundle, reviews}`: one object per
focus, already in the shape `review-synth` reads. A reviewer or verifier that died comes back as
`status: "not-reviewed"`; keep it, never re-label it.

If the Workflow tool is not available in this session, run the same pipeline with the Agent tool:
for each focus in `focuses`, launch `swift-harness:<focus>` (all in one message), and as each
returns findings, launch `swift-harness:verifier` with only those findings and the bundle path,
never the reviewer's reasoning. Build the per-focus objects exactly as `workflows/review.js` does:
unverified findings keep `verified: false`, a failed agent gives `not-reviewed`, and an absent
`swiftui` focus gives `not-applicable`.

## 3. Synthesize

Write each returned review object verbatim as JSON to
`.harness/runs/<runID>/review-findings/<focus>.json` (the files are the audit trail; don't edit
findings). Then run:

```
"$SG" review-synth --run-directory .harness/runs/<runID> .harness/runs/<runID>/review-findings/*.json
```

It drops findings without a failure scenario or without verification, dedupes by file, line and
category, applies the verdict rule, writes `review.json`, and prints at most 30 lines. Exit 2 means
an input broke the contract: fix the file you wrote, don't hand-edit the verdict.

## 4. Report

Relay the summary as printed: the verdict first (`merge`, `fix-then-merge` or `refactor-needed`),
any `NOT REVIEWED` focus, then the top findings with `file:line`, scenario and fix. Don't add
findings the panel didn't verify and don't soften the verdict.

- `refactor-needed`: a verified architecture blocker. Say what structure has to change and propose
  the design; don't patch lines.
- `fix-then-merge`: offer to fix the blocker and major findings, then re-run `check --tier push`
  and this review. A `NOT REVIEWED` focus alone also gives this verdict: re-run the review.
- `merge`: say so, and list minor and nit findings as optional.
