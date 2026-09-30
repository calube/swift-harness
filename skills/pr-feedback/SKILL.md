---
name: pr-feedback
description: This skill should be used to handle review comments on a Swift pull request end to end — validate each comment against the code, fix it test-first or push back with evidence, run the swiftgate gate, push, reply on the thread, resolve it, and re-trigger bot review only after a behavior change, until a stopping rule (not "the bot found nothing") says stop. Use when the user says "address PR feedback", "handle the review comments", "respond to reviewers", "fix the bot findings", "address the comments on PR #N", "babysit this PR", or "/swift-harness:pr-feedback".
---

# PR feedback

Run the whole loop: validate → fix → gate → push → reply → resolve. Don't hand suggestions back to
the user; do the work, and stop only at the rule in [Stopping rule](#stopping-rule).

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Pass `--base <ref>` when the branch doesn't target
`origin/main`. Every check in this loop is a `swiftgate` command: if a reviewer asks for a check
the gate lacks, that is a gate gap to note, not a check to hand-write here.

## Stance

Reviewers, bots and humans alike, are partners, not oracles.

- **Validate before acting.** Read the code at the cited path and line. Decide: real, real but
  low priority, or wrong. Don't accept blindly and don't defend reflexively.
- **Right:** fix it, reply on the thread with the commit SHA and one line of why, resolve it once
  the fix is pushed.
- **Wrong or built on a false premise:** push back with evidence (`file:line`, a doc link, a test
  result). Giving in to a wrong critique buys churn, not correctness. Resolve a **bot's** thread
  after pushing back; leave a **human's** thread open for them.
- **Right but out of scope:** say so, explain the boundary, and record a follow-up or drop it with
  a stated reason. Don't silently widen the PR.
- **Bots earn extra scrutiny.** They are right often enough to read and wrong often enough that
  auto-accepting produces bad commits. This includes bots asserting Swift or Xcode behavior:
  check the claim against the docs or a compile, not the bot's confidence.
- **Reply tersely.** "Fixed in `<sha>`" beats "Thanks so much for catching this!"

A fix isn't done until its thread has a reply. If an earlier commit already fixed a comment, post
the SHA anyway; an unanswered thread reads as unaddressed to the reviewer and to re-review bots.

Confirm the branch and PR number (`git status`, `gh pr view --json number,headRefName`) before every
push; worktrees make it easy to commit to the wrong place.

## Fixing a comment

1. **Test first.** A behavior fix starts with a test that fails for the reported reason, through
   `/swift-harness:tdd`. A comment that changes no behavior (naming, docs) needs none.
2. **Gate before push.** `"$SG" check --tier push --json`. `RED`: fix the named findings. `BLOCKED`:
   run `"$SG" doctor`; never change code to get past it. Never push on RED.
3. **Ready tier before a re-review request** that follows a behavior change:
   `/swift-harness:test-gate`. The pre-commit hook already runs `swiftgate comments --staged`.
4. **Check your own fix the way the bot will read it** before pushing: missing states, unbounded
   collections, error and cancellation paths, actor isolation, whether an escape hatch carries its
   `swiftgate:allow <rule> — <reason>`. Fix what you find in the same commit.
5. Commit, push, reply with the SHA, resolve (see [Resolving threads](#resolving-threads)).

## Converge, don't chase

Bot review is not deterministic, and every push starts a new review. On one 23-round production
PR, a bot reviewed the same commit twice and gave a clean pass and two new medium-severity findings. 35% of all
findings were in code that earlier review fixes had added, the diff grew 80%, and unrelated scope
landed after the human approval. "The bot found nothing" is not a reachable exit. Use these rules.

1. **Keep a findings ledger across rounds.** One row per finding in
   `$(git rev-parse --git-common-dir)/pr-feedback/<pr>.tsv`: round, reviewer, severity, path,
   one-line claim, origin, theme, disposition. Origin is `orig`, `fix:<sha>` or `main-merge`; find
   it with `git blame` on the flagged line. Read the ledger at the start of every round. Without
   it each round starts from zero and the same class of finding gets different answers.
2. **Triage by severity.**
   - Critical or high severity (a bot's top two levels), or anything a human raised: validate and fix now, test first.
   - A medium-severity finding that is a real bug in the PR's stated contract: fix it.
   - A hypothetical medium-severity finding (needs a state no code path writes, or is polish outside the PR's purpose):
     reply once, record a follow-up, resolve. Don't implement it.
3. **When a theme repeats, write the rule down.** On the third finding in one theme, stop fixing
   cases. Name the rule the reviewer keeps probing (who owns a lifecycle, which values a client
   may trust, what a reducer may assume), state it once in the type's doc comment or the module's
   contract, and answer the rest by pointing at it. If the theme is a structural seam, fix the
   seam or file it.
4. **Guard the scope.** If the diff has grown more than about 30% since the first review, or a fix
   needs a new module, a new shared helper, or edits to unrelated callers, move it to a follow-up
   PR and tell the user. After a human approves, anything beyond the requested fixes goes in a
   separate PR; an approval covers only the commit it was given on.
5. **Re-trigger bots only after a behavior change.** Once every open thread has a reply, post the
   repo's re-review command (check earlier PR comments for the exact text). Don't re-trigger after
   a merge from main, a doc-only change, or a rebase: that buys a fresh random sample of medium-severity findings.

## Stopping rule

Done when all of these hold:

- `"$SG" check --tier ready --json` is `GREEN` on the current head (CI is local-only here).
- No new critical or high finding in the last two bot rounds.
- Zero unresolved threads; every remaining medium finding is fixed or answered with a recorded follow-up.
- Any human approval covers the current head, or you've told the user it's stale.

Then stop and report: rounds, findings by severity, the share that were fix-induced, themes and
their rules, follow-ups. If rounds keep producing critical or high findings in one theme, the design is wrong, not
the details: stop patching and escalate with the ledger as evidence.

## Resolving threads

GitHub's REST reply endpoint does not resolve a thread; the GraphQL mutation does. Find the thread
by the database id of its first comment:

```bash
gh api graphql -f query='query($o:String!,$r:String!,$p:Int!){repository(owner:$o,name:$r){pullRequest(number:$p){reviewThreads(first:50){nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}' -f o=<owner> -f r=<repo> -F p=<pr>
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}' -f id=<thread-node-id>
```

Resolve by thread id, one at a time, and only when the comment is acted on (fixed, or answered
with reasoning). Never blanket-resolve: doing so once silently closed a high-severity finding mid-loop. Leave a human
reviewer's pushed-back thread for them.

## Boundaries

- Sending anything to a person beyond thread replies (review requests, messages) is the user's
  call; draft it and stop.
- Never force-push a shared branch or merge; the user merges.
