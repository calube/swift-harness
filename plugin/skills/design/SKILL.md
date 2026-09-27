---
name: design
description: This skill should be used to design a change in a swift-harness repository before any code or plan exists, and to take that design through review, approval and later amendment. It frames the goal with the user through multiple-choice questions, claims the plan, lets `swiftgate design-scope` pick a depth tier, runs the research lanes, verifies every claim, has an opus drafter write the design doc until `design-lint` and `docs-lint` pass, runs the design reviewers, publishes the rendered page as an Artifact, reads the approval back and merges. Use when the user says "design this", "write a design doc", "/swift-harness:design", "plan the architecture for", "how should we build", asks for a design before a plan, or passes --revise, --amend or --supersede.
---

# Design

Invoking this skill is the user's opt-in to run the design pipeline. It spends agents at every tier
except the frame: 1 research lane, the claim checker and the drafter at `quick`; 4 lanes, the
checker, the drafter and 3 reviewers at `standard`; the same plus a pre-mortem at `deep`.

## Modes

| Invocation | Starts at |
|---|---|
| `/swift-harness:design <goal>` | 1. Frame |
| `… --supersede <old-slug>` | 1. Frame; acts on the old design at the approved commit |
| `… --revise` | [Revise from comments](references/review-publish-amend.md#revise-from-comments) |
| `… --amend <slug>` | [Amend and clarify](references/review-publish-amend.md#amend-and-clarify) |
| a plan whose index status is `in-review` | [Read the approval](references/review-publish-amend.md#read-the-approval) |

When the frame finds that `<doc>` exists and this plan didn't write it, offer `--amend` instead
of stopping.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the repository root, the
directory that holds `.swiftgate.toml`. Paths passed to `swiftgate` are repo-relative.

## Ground rules

- **Ask only through `AskUserQuestion`.** Multiple choice, the recommended option first with
  `(Recommended)` in its label, at most 4 questions per prompt. Never ask in plain text while
  `AskUserQuestion` is available. Every answer goes into `answers.jsonl` and becomes an `answer`
  claim. A headless session (`claude -p`) has no `AskUserQuestion`: end the turn with the
  questions in the [headless shape](references/frame-research-verify.md#headless) and stop.
- **You write every file.** Agents and workflow scripts return content. The edit guard lets only
  the session that holds the plan write the design doc and its `<slug>.evidence/` folder, and it
  denies any subagent.
- **The gate decides.** Never hand-check what a `swiftgate` command checks, and never edit a
  status the gate or an agent returned. When a command exits 2, report its message and stop.
- **A premise is a claim.** An API, type or behaviour the request names isn't checked before
  research, even when a grep would settle it. The frame carries it into the lane briefs, and
  verify's probe decides it. Never stop the frame or rewrite the goal over a premise.
- **Halt, ask, resume.** A choice only the user can make stops the phase. Ask, record the answer,
  then resume where you stopped (`references/frame-research-verify.md` has the resume rules).

## Names used below

| Name | Value |
|---|---|
| `<slug>` | kebab-case name of the change, from the goal |
| `<plan>` | `<today as YYYY-MM-DD>-<slug>` |
| `<doc>` | `docs/<area>/designs/<slug>.md` |
| `<ev>` | `docs/<area>/designs/<slug>.evidence` |
| `<run>` | `.harness/runs/design-<slug>` (gitignored; `swiftgate stats` reads `phases.jsonl` here) |
| `<design-run>` | `design-<UTC time as YYYYMMDDTHHMMSSZ>`, fixed at the start of this invocation |
| session id | the `Session id: <id>` line of this session's SessionStart context |

The SessionStart hook prints `Session id: <id> (pass as --session to swiftgate plan claim/plan
release).` A skill can't read hook payloads, so this line is the only source. If it's absent, stop
and tell the user the hook didn't run; never invent an id.

## 1. Frame

Follow [the frame steps](references/frame-research-verify.md#frame). In short:

1. Ask the frame questions: area, touched modules, new modules and their kinds, new dependencies,
   constraints. Keep the answers in memory for now.
2. Write `<run>/frame-answers.json` and run `"$SG" design-scope --frame-answers <run>/frame-answers.json --json`.
3. Ask the user to confirm the tier, with the recommended tier first.
4. Claim the plan with this session's id:
   `"$SG" plan claim <plan> --session <id> --design <doc> --tier <tier> --json`.
   Exit 1 means another session holds it, or another plan owns the doc: name it and stop. Only the user runs
   `"$SG" plan release <plan> --force`.
5. Switch to the `design/<slug>` branch, write `answers.jsonl` and the frame's `answer` claims, and
   run `"$SG" index set <plan> designing "<resume note>" --session <id>`.

## 2. Research

Follow [the research steps](references/frame-research-verify.md#research). Build 1 context pack
per lane with `"$SG" context-pack --role research-lane`, then run `workflows/design-research.js`.
`quick` runs the codebase lane alone; `standard` and `deep` run all 4. On `needs-decision`, ask,
record, and relaunch with `resumeFromRunId`. Write each lane's claims to `<ev>/claims.jsonl` and
each probe to `<ev>/probes/<ev-id>.snippet.swift`.

## 3. Verify

Follow [the verify steps](references/frame-research-verify.md#verify): `"$SG" evidence check`,
`"$SG" probe`, the claim checker, then rewrite `claims.jsonl` from `evidence check --json` and the
checker's verdicts. When a refuted claim leaves no viable option, halt and ask.

## 4. Draft

Follow [the draft steps](references/frame-research-verify.md#draft). Build the drafter pack with
`"$SG" context-pack --role drafter`, launch `swift-harness:design-drafter` with the Agent tool,
write its reply to `<doc>`, then run `"$SG" design-lint <doc>` and `"$SG" docs-lint`. Send
findings back to the same drafter, at most 2 rounds, then halt and ask.

## After every phase

Append 1 line per agent run or `swiftgate` phase to `<run>/phases.jsonl`, in the shape the
reference gives. `"$SG" stats --design <doc>` reads it.

## Where the draft leaves things

The draft phase ends with:

- `<doc>` on the `design/<slug>` branch with `status: proposed`, uncommitted, clean under
  `design-lint`, and clean under `docs-lint` apart from the 2 findings that publish resolves;
- `<ev>/claims.jsonl`, `answers.jsonl` and `probes/` holding every claim with its final status;
- this session holding `<plan>`, and the index entry at `designing`.

## 5. Review

Follow [the review steps](references/review-publish-amend.md#review). Build 1 pack per reviewer
with `"$SG" context-pack --role evidence-auditor`, `--role standards-reviewer` and
`--role challenger`; the pre-mortem gets the challenger's pack. Run
`workflows/design-review.js`, write each `reviews` entry to its own file, then run
`"$SG" review-synth --run-directory <run>/review-<r> --design <doc> --tier <tier> --json` with
those files. `quick` runs no reviewer. On `revise`, run 1 revise round (2 at `deep`): redraft,
then relaunch with `reviewers` set to the report's `rerun` and `previous` set to the last return.
On `rethink`, halt and ask. Append every finding's disposition to `<ev>/review-log.jsonl`.

## 6. Publish

Follow [the publish steps](references/review-publish-amend.md#publish):

1. Add the area router row, and at `standard` and `deep` the ADR. Run `"$SG" docs-lint`: from
   here on it no longer tolerates `docs-lint.unreachable-doc` on `<doc>`.
2. Commit on `design/<slug>`; this 1st commit is status `proposed`. Run
   `"$SG" index set <plan> in-review "<note>" --session <id>`.
3. Run `"$SG" design-render <doc> --json` and publish its `output` with the `Artifact` tool,
   `capabilities: {"comments": {}, "db": {}}`.
4. Read the approval with `ArtifactData` `get`, collection `approval`, doc id = the designSha.
   Without `db`, ask with `AskUserQuestion` and record an `answer` claim bound to the designSha.
5. Check the designSha with `"$SG" design-diff HEAD:<doc> <doc> --json`, set status `approved`,
   merge, record the approval in `plan.json`, and run
   `"$SG" index set <plan> approved "<note>" --session <id>`.

## 7. Revise, supersede, amend

- `--revise` reads the page's threads with `ArtifactComments`, answers questions, redrafts for
  change requests, reviews again and republishes to the same URL.
- `--supersede <old-slug>` claims the old plan and sets the old design to
  `superseded-by: <slug>` in the approved commit.
- `--amend` classifies the change with `"$SG" design-diff`. A clarify writes a clarify record
  and extends the plan's clarify chain. An amend writes an amendment record after a 2-agent delta
  review and a new approval, and marks the affected ledger tasks `needs-replan`. A `stale` claim
  from `"$SG" evidence check --at HEAD` spawns a one-claim `reresearch` lane first.

[Status rules](references/review-publish-amend.md#status-rules) lists the only status changes the
skill makes. End every run by reporting the doc path, the tier, the verdict, the page URL, and the
plan's index status.
