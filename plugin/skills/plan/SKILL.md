---
name: plan
description: This skill should be used to turn an approved swift-harness design, or a confirmed spec page, into a build plan, or to replan one after an amend. It checks that this session holds the plan's claim and that the approval matches the design's designSha (directly or through a verified clarify chain), re-checks the evidence at HEAD (a spec page plan instead needs its confirm and its surface commit recorded), has the decomposer agent split the design or the page's slices into ledger tasks (after an amend, only the needs-replan tasks and fix tasks for changed ids that done tasks cover, around the kept tasks), runs swiftgate plan-schedule and plan-lint with one fix round, writes the shared plan.json and ledger.json, sets the plan index and publishes the ledger page as an Artifact. Use when the user says "plan this design", "decompose the design", "make the ledger", "replan", "/swift-harness:plan", or after /swift-harness:design reports an approved design or an amend.
---

# Plan

This skill turns an approved design, or a confirmed spec page, into `plan.json` and `ledger.json`
under the git common dir, where every worktree of the repository reads them. It decides the order of the steps and asks the
user. `swiftgate` does every check. The decomposer agent proposes the tasks, and this skill never
edits a task itself.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the repository toplevel.

The JSON shapes this skill writes, and the `phases.jsonl` record, are in
[`references/state-files.md`](references/state-files.md). Read it before step 2, the first write.

## Halt and ask

Any step below that says **halt** means: stop the run, then ask the user with `AskUserQuestion`.
Put the recommended option first and ask at most 4 questions in a single prompt. Quote the failing
command's message or findings as `rule: message` lines. Never work around a halt by hand: don't
edit a task, a finding or a state file to make a check pass. Leave the index status as it was, so
no one builds from a half-made plan.

## Inputs

- The plan slug, `<slug>`: the argument, or the plan the user names. With no argument, list the
  plans that the SessionStart context shows as `approved` and ask which one.
- This session's id, `<session>`: the `Session id:` line of the SessionStart context. If that line
  is missing, halt: the claim can't prove who holds the plan.
- The plan directory, `<plans>/<slug>/`, where `<plans>` is
  `$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans`.

Keep a single run id for this run, `plan-` plus the UTC time as `YYYYMMDDTHHMMSSZ`. Each step that says
**log** appends one `phases.jsonl` line under that run id.

## 1. Hold the claim

```bash
"$SG" plan claim <slug> --session <session> --json
```

This session may go on only when the command exits 0. Its JSON `status` is `already-held` when this
session holds the plan, or `claimed` when no one held it and this session now does.

- Exit 1 (`held-by-other`): another session holds the plan, and the message names it. Halt. Tell
  the user that the holding session releases it with `"$SG" plan release <slug> --session <id>`.
  A user who knows that session is gone runs `"$SG" plan release <slug> --force` themselves. Never
  run `--force` for them.
- Exit 2: a bad slug, no repository, or a plan that doesn't exist yet. A new plan starts in
  `/swift-harness:design`, which claims it with its design doc, or in `/swift-harness:ship` at a
  preset without a design step, which claims it with its spec page. Halt.

The claim is the only thing that lets this session write the plan's state. The edit guard allows
a write to `<plans>/<slug>/` only from the main session whose id is in that plan's
`orchestrator.lock`. A subagent never qualifies.

## 2. Match the approval to the designSha

Read `<plans>/<slug>/plan.json`. `"source": "specPage"` marks a spec-page plan: follow
[A spec-page plan](#a-spec-page-plan) instead of the rest of this step and step 3. Otherwise its
`design` names the design doc, `<doc>`.

Compute the current designSha from the committed doc, and confirm the working tree matches it:

```bash
"$SG" design-diff HEAD:<doc> <doc> --json
```

The `oldSha` field is the current designSha, `<current>`. If `class` isn't `unchanged`, the working
copy differs from the commit: halt, and ask the user to commit or discard the change first. Exit 2
means the doc isn't in `HEAD`; halt.

Then find the approval:

1. `plan.json` has `approval` with `decision` `approve`: use it.
2. `plan.json` has no `approval`: find the record `/swift-harness:design` left for `<current>`.
   That is the design page's `db` entry, read with `ArtifactData` (collection `approval`, doc id
   `<current>`), or the `answer` claim in `<slug>.evidence/claims.jsonl` bound to `<current>`. Ask
   the user for the design page link if you don't have it. With no record, or a decision other
   than `approve`, halt and point the user to `/swift-harness:design`.

The approval matches in one of 2 ways:

- **Direct match:** `approval.designSha` equals `<current>`.
- **Through a clarify chain:** `plan.json` has a `clarifyChain`, and this check passes:

  ```bash
  "$SG" design-diff --chain <plans>/<slug>/plan.json --json
  ```

  The chain holds only when the command exits 0 with `status` `valid` and `endSha` equals
  `<current>`. Exit 1 names the broken link; exit 2 means the command can't check it. Either way, or when
  `endSha` differs, halt. The design changed in a way the approval doesn't cover, so the next step
  is `/swift-harness:design --amend`.

No match: halt. Never plan a design the user hasn't approved.

Before you write, keep the `designSha` that `plan.json` has now as `<planned>`: the designSha the
current ledger was planned at, or none on a first plan. A replan (step 4) needs it.

Write `plan.json` (shape in the reference): keep its fields and set `designSha` to `<current>`, and
`approval` to the record from this step. `plan-lint` reads the design at this `designSha`.

### A spec-page plan

The page is `<plans>/<slug>/spec-page.md`. Its confirm replaces the design's approval and evidence:
`swiftgate plan confirm` recorded the page's sha in `approval`, and `plan-lint` fails a page that
changed after it. Don't write `plan.json` in this step.

1. `plan.json` has no `approval`: halt. No one has confirmed the page yet; `/swift-harness:ship`
   confirms it with `"$SG" plan confirm <slug> --by user|spec-quotes --spec <spec-file> --session <session>`.
2. `plan.json` has no `surfaceCommit`: halt. The decomposer reads the surface's files, and every
   worker builds on it; `/swift-harness:ship` lands it with
   `"$SG" plan surface <slug> <surface> --gate <run id> --preset <preset> --session <session>`.
3. Keep `surfaceCommit` as `<surface>`, then go to step 4.

A spec-page plan has no amend, so it never replans: step 4's table applies, with every row but
**fresh** a halt.

## 3. Re-check the evidence at HEAD

A spec-page plan skips this step: it has no design and no evidence.

```bash
"$SG" evidence check --design <doc> --at HEAD --json
```

Exit 0: go on. Any other exit halts. A `stale` or failing claim means the design rests on evidence
that no longer holds. Recommend `/swift-harness:design`, which re-researches that claim, and list
each claim as `id: status`.

## 4. Decompose

### Fresh plan or replan

Read `<plans>/<slug>/ledger.json`, if it exists, and pick the mode from its task statuses:

| The ledger | Mode |
|---|---|
| doesn't exist, or every task is `pending` | **fresh**: decompose the whole design |
| has an `in-progress` task | a build is in flight: **halt** |
| has a `needs-replan` or `done` task, and none `in-progress` | **replan** |
| anything else (`blocked` or `abandoned` tasks, none `needs-replan` or `done`) | **halt** |

A halt names each task that isn't `pending` as `id: status`. A build in flight finishes or stops
first; the user decides what a `blocked` or `abandoned` task needs.

### Replan

An amend (`/swift-harness:design --amend`) set `needs-replan` on each task whose `covers` meets a
changed id, and left `done` tasks alone: a `done` task is immutable, so a change it needs becomes a
new fix task. A replan asks the decomposer for the new tasks only, and keeps every other task as
it is.

1. **Changed ids.** Read `<ev>/amendments.jsonl` (`<ev>` is `<doc>` without `.md`, plus
   `.evidence`). Follow its records from `<planned>`: the record whose `fromSha` is `<planned>`,
   then the one whose `fromSha` is that record's `toSha`, until a `toSha` equals `<current>`.
   `<changed>` is the union of their `changedIds`. When `<planned>` equals `<current>`, `<changed>`
   is empty. A chain that doesn't reach `<current>` halts: the ledger was planned against a design
   the records don't connect to this one.
2. **Split the tasks.** `<replace>` is every `needs-replan` task. `<fixed>` is every other task,
   `done`, `pending`, `blocked` and `abandoned` alike. `<fix-ids>` is each id in `<changed>` that
   a `done` task's `covers` names, with that task's id.
3. **Nothing to ask.** When `<replace>` and `<fix-ids>` are both empty, skip the decomposer: the new
   tasks are none. Go to step 5.
4. **The replan input.** Write `.harness/plan-draft/<slug>/replan.json` (shape in the reference)
   with `<planned>`, `<current>`, `<changed>`, `<fixed>` and `<replace>` copied as the ledger has
   them, and `<fix-ids>`.

A replan builds the same context pack as a fresh plan, below, and gives the decomposer the path of
`replan.json` as well. Its reply holds only the new tasks: a replacement for each `<replace>` task,
a fix task for each `<fix-ids>` entry, and a task for any design id that no `<fixed>` task covers.
In step 5 the draft's tasks are `<fixed>`, unchanged and in their ledger order, then the reply's
tasks. You never edit a `<fixed>` task, so a `done` task reaches the new ledger as it was.

### The decomposer

Build the decomposer's context pack. It needs a module graph and the task-sizing bounds as files:

- Module graph: `"$SG" module-graph --output .harness/plan-draft/<slug>/module-graph.txt`. Exit 2
  names what it couldn't read, and writes no file; halt.
- Bounds: `.swiftgate.toml` itself. Its `[plan]` table and `[[modules]]` kinds are the bounds;
  when `[plan]` is absent, the agent applies its defaults.

```bash
"$SG" context-pack --role decomposer --design <doc> --module-graph .harness/plan-draft/<slug>/module-graph.txt --task-sizing-bounds .swiftgate.toml
```

A spec-page plan packs its page in place of the design:

```bash
"$SG" context-pack --role decomposer --spec-page <plans>/<slug>/spec-page.md --module-graph .harness/plan-draft/<slug>/module-graph.txt --task-sizing-bounds .swiftgate.toml
```

Exit 1 or 2 halts: the design is missing a section the pack needs, the page breaks the spec page
format, or an input is unreadable.

Launch the decomposer with the Agent tool, `subagent_type: "swift-harness:design-decomposer"`.
Give it the absolute path of `.harness/context-pack/decomposer.md`, the plan slug and the
repository's directory name. That name is the main checkout's, the directory that holds the git
common dir, even when you run from a linked worktree. For a spec-page plan, give it `<surface>` too:
the surface's stub files may go in the write set of the task that fills them. On a replan, give it the absolute path of
`.harness/plan-draft/<slug>/replan.json` too, and say it's a replan. Keep the agent's id for the
fix round.
**Log** a `decompose` line with the tokens and duration the Agent tool reports.

The reply must be a single JSON object, `{tasks, unresolved}`, in the agent's contract. Check that every
task has the ledger task fields, `status` `pending` and `model` set, with no `actualLines`. On a
replan, also check that no reply task has the id of a `<fixed>` task. A reply that isn't in that
shape halts.

## 5. Schedule, write the ledger, lint

1. Write the draft ledger to `.harness/plan-draft/<slug>/ledger.json`: the decomposer's `tasks`
   copied as they are (on a replan, the `<fixed>` tasks first, then the reply's), `waves` empty,
   and `maxParallel` from `.swiftgate.toml` `[plan] max_parallel` (3 when unset).
2. Compute the waves, and **log** a `schedule` line:

   ```bash
   "$SG" plan-schedule .harness/plan-draft/<slug>/ledger.json --json
   ```

   Exit 0: copy `waves` from the output into the draft. Exit 1 (a cycle or a missing dependency):
   leave `waves` empty; `plan-lint` reports the same problem at item 4. Exit 2 means this skill
   wrote a malformed draft: fix the draft's shape, never a task, and rerun.
   Then set the draft's `resume` to a single line, such as
   `planned; 7 tasks in 3 waves; next: build the first wave`. A replan's line counts the tasks
   already done, such as `replanned at <current>; 4 of 9 tasks done; next: build the next wave`.
3. Write the draft to `<plans>/<slug>/ledger.json` with the Write tool, byte for byte.
4. Lint the plan, and **log** a `lint` line:

   ```bash
   "$SG" plan-lint <slug> --json
   ```

   Exit 0: go to step 6. Exit 2 halts: the plan state, the design at `designSha`, the spec page
   or the module graph is unreadable, or no one has confirmed the page. Exit 1: go on to the fix round,
   except that `plan-lint.spec-page-moved` halts at once: the page changed after its confirm, and
   no task edit fixes that. Confirm the page again with `/swift-harness:ship` first.
5. **A single fix round.** Send the decomposer every finding from the report with
   `SendMessage` to the agent id you kept, as `rule (severity) task: message` lines. On a replan,
   its reply is again the new tasks only, and items 1 to 4 put `<fixed>` first again. Load
   `SendMessage` with `ToolSearch` if it's deferred. **Log** a `decompose` line for its reply.
   Check the reply as in step 4, then repeat items 1 to 4 of this list once with the new tasks.
6. After the fix round, any gating finding from `plan-lint`, or any `unresolved` entry, halts.
   Ask the user how to go on: amend the design, change a bound in `.swiftgate.toml` `[plan]`, or
   stop. There is no second fix round. `minor` findings don't halt; list them in the summary.

## 6. Set the index

```bash
"$SG" index set <slug> planned "<resume>" --session <session>
```

`<resume>` is the ledger's `resume` line. Before this call, write the same line to the `resume`
field of `plan.json`. For a spec-page plan, write it with
`"$SG" plan set <slug> --resume "<resume>" --session <session> --json`, which keeps the confirm and
the surface as they are. **Log** an `index` line. A non-zero exit halts.

## 7. Publish the ledger page

```bash
"$SG" design-render --ledger <slug> --json
```

Exit 0 writes `.harness/design-render/<slug>-ledger.html`; exit 2 halts. Read the whole page, then
publish it with the `Artifact` tool, with no `capabilities`: the ledger page takes no input. On a
rerun, publish to the same URL: the same file path in this conversation, or the earlier URL
otherwise. When this session has no Artifact tool, don't publish: report the rendered page's path,
`.harness/design-render/<slug>-ledger.html`, in its place and go on. The page is a view, never a
gate.

## Report

End with the Artifact link, or the page's path when this session has no Artifact tool, and a
short summary:

- the task count and the waves, in the order `plan-schedule` gave them;
- the `minor` findings `plan-lint` left;
- on a replan, the tasks replaced, the fix tasks added and the `done` tasks kept;
- the plan's status, `planned`.

The claim stays with this session. The build of the first wave starts from this ledger.

## Rules

- Only this main session writes `plan.json` and `ledger.json`, and only while it holds the claim.
  A subagent returns content, and this skill writes it.
- Never write `index.json` or `orchestrator.lock`. `index set` and `plan claim` own them.
- A `ledger.json` with a task that isn't `pending` means a build has started. Only a replan (step
  4) writes over it, and only around its `<fixed>` tasks. A change to a plan in flight goes
  through the design's amend flow, which marks the tasks this skill replaces.
- Don't re-implement a check. When a `swiftgate` command and your reading disagree, the command
  wins.
