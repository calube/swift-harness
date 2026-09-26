---
name: design
description: This skill should be used to design a change in a swift-harness repository before any code or plan exists. It frames the goal with the user through multiple-choice questions, claims the plan, lets `swiftgate design-scope` pick a depth tier, runs the research lanes, verifies every claim (evidence check, probe, claim checker), and has an opus drafter write the design doc until `design-lint` and `docs-lint` pass. Use when the user says "design this", "write a design doc", "/swift-harness:design", "plan the architecture for", "how should we build", or asks for a design before a plan.
---

# Design

Invoking this skill is the user's opt-in to run the design pipeline. It spends agents at every tier
except the frame: 1 research lane, the claim checker and the drafter at `quick`; 4 lanes, the
checker and the drafter at `standard` and `deep`. Review and publish come after the draft.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the repository root, the
directory that holds `.swiftgate.toml`. Paths passed to `swiftgate` are repo-relative.

## Ground rules

- **Ask only through `AskUserQuestion`.** Multiple choice, the recommended option first with
  `(Recommended)` in its label, at most 4 questions per prompt. Never ask in plain text. Every
  answer goes into `answers.jsonl` and becomes an `answer` claim.
- **You write every file.** Agents and workflow scripts return content. The edit guard lets only
  the session that holds the plan write the design doc and its `<slug>.evidence/` folder, and it
  denies any subagent.
- **The gate decides.** Never hand-check what a `swiftgate` command checks, and never edit a
  status the gate or an agent returned. When a command exits 2, report its message and stop.
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
   Exit 1 means another session holds it: name the holder and stop. Only the user runs
   `"$SG" plan release <plan> --force`.
5. Switch to the `design/<slug>` branch, write `answers.jsonl` and the frame's `answer` claims, and
   run `"$SG" index set <plan> designing "<resume note>"`.

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

Review, publish, approval and amend pick up from this state. Until this skill documents them, stop
here: report the doc path, the tier, the claim counts by status, and any lane marked
`NOT RESEARCHED`.
