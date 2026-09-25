---
name: comment-audit
description: This skill should be used for a judgment pass over the comments a Swift change adds — decide KEEP, TRIM or CUT for each with evidence (precedent, owner, ward, test) and propose exact edits; advisory, never blocking. Complements the mechanical `swiftgate comments --staged` pre-commit check. Use when the user runs /swift-harness:comment-audit, asks to "audit the comments", "trim comment slop", "are these comments worth keeping", "clean up comments before commit", or when a Claude-authored commit's staged comments need review.
---

# Comment audit

The rule (plugin `docs/standards.md` `K1`, `K2`): if deleting a comment loses nothing a reader can't
recover from the code, delete it. Keep non-obvious *why*, footgun warnings, suppression reasons,
and `///` contracts on `public`/`package` API. No history narration in source.

The mechanical half is `swiftgate comments --staged` (it blocks commented-out code, diff narration,
line references, unlinked TODOs, private paths, unjustified suppressions, and warns on the
heuristics). This skill is the judgment half: it proposes, the author decides, and it never blocks.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`.

## 1. Collect the comments

1. Pick the change: the staged change by default (`git diff --cached -U5 -- '*.swift'`); a branch
   when the user names one (`git diff -U5 <base>...HEAD -- '*.swift'`).
2. Keep only hunks whose **added** lines contain a comment token (`//`, `///`, `/* */`, not inside a
   string literal). Skip what is always kept: `// MARK:`, `#warning`, `@available(…, message:)`,
   suppressions with a same-line reason (`// swiftgate:allow <rule> — <reason>`,
   `swiftlint:disable … — <reason>`), and `///` contracts on `public`/`package` API.
3. For a staged change, run `"$SG" comments --staged --json` and keep its `findings[]`. Gating ones
   must be fixed before the commit anyway; the heuristic warnings (`comments.long-block`,
   `comments.restates-code`, `comments.test-body`, `comments.trivial-private-doc`,
   `comments.ai-prose`) become inputs to the judgment below. In branch mode there is no mechanical
   pass (it reads only the staged change), so the subagent works without these warnings.
4. If there are no added comments, say so and stop.

## 2. Judge in isolation

Launch one subagent (Agent tool, general-purpose) per ~40 comments. Give it only: each comment
with its file, line and surrounding hunk, the relevant `swiftgate` warnings, read access to the
repository, and the rubric below. Don't pass your own reasoning about why the comments were
written: the judgment must come from the code alone, like a reader meeting it cold.

Rubric, applied to every comment:

- **Test 1 — lost fact.** Would a reader lose a fact the code can't give back? No → **CUT**.
- **Test 2 — right size.** For a keeper: is it the right size? No → **TRIM**: delete it and write
  the surviving fact fresh in one line, rather than editing the old wording down.
- Otherwise **KEEP**.

Every verdict carries four pieces of evidence, each one short line:

| Field | Question |
|---|---|
| precedent | How often does the same construct appear uncommented elsewhere in the repository? (Search for it; give the count.) |
| owner | Does the fact already live somewhere else: a type, a name, a `///` contract, a doc? Name it. |
| ward | Is there a plausible edit that compiles and passes the tests but is wrong, which this comment prevents? Describe it, or "none". |
| test | Could a test state this fact instead? If yes, name the test to write; the verdict becomes CUT once that test exists. |

A comment with a real ward is almost always KEEP or TRIM. High precedent, an owner, and no ward is
CUT. A comment a test could replace gets `CUT (after test: <name>)`. The subagent returns one
entry per comment:
`file:line — KEEP|TRIM|CUT|CUT (after test: <name>) — precedent: … · owner: … · ward: … · test: … — proposed replacement (TRIM) or deletion (CUT)`.

## 3. Propose

1. Re-check only the facts behind each verdict (the precedent count, whether the owner exists).
   Never change a verdict: if you dispute one, show it with your reason instead of dropping it.
2. Show the user a compact list grouped CUT, TRIM, KEEP (KEEP as a count only, unless asked).
3. Ask with one `AskUserQuestion`: **Apply all**, **Apply CUT only**, **Pick individually**, or
   **Apply none**. For "pick", batch the choices into multi-select questions of up to four
   comments each, four questions per call.
4. Apply the chosen edits. For `CUT (after test: …)`, write the test first
   (`/swift-harness:tdd`), then cut the comment.
5. For a staged change, re-stage the edited files and re-run `"$SG" comments --staged` until it is
   GREEN, at most twice; then report what is left.

Never commit on the user's behalf from this skill, and never apply edits the user didn't choose.
