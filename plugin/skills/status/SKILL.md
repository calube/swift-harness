---
name: status
description: This skill should be used to list active swift-harness plans across every bootstrapped Swift repository on this machine — reads ~/.swift-harness/projects.json and each repository's shared plan index (swift-harness/plans/index.json in its git common dir), and shows each plan's slug, status and RESUME line. Use when the user asks "what am I working on", "status", "which plans are active", "where did I leave off", "show harness plans", or starts a session and wants to pick a plan to resume.
---

# Status

Read-only. The registry holds pointers; each repository's plan index is the canonical record and
is written only by the plan orchestrator. It lives in the git common dir, so every worktree of a
repository shares it. This skill never edits either file.

## Steps

1. Read `~/.swift-harness/projects.json`: `{"schema": 1, "projects": ["<absolute repo path>", …]}`.
   Missing file: say no repository has been bootstrapped on this machine and point to
   `/swift-harness:bootstrap`. Stop. Unparseable, or `schema` other than 1: report it, point to
   `/swift-harness:bootstrap`, and stop without editing the file.
2. For each path, resolve its plans dir `<plans>`:
   `git -C <path> rev-parse --path-format=absolute --git-common-dir`, plus `/swift-harness/plans`.
   Read `<plans>/index.json`: `{"plans": [{"slug", "status", "resume"}, …]}`.
   - Path missing: list it under "Not found" (moved or deleted). Don't remove it from the registry;
     re-running bootstrap in the moved repository registers the new path.
   - Not a git repository, index missing or unparseable: list the repository with "no plan index".
   - `resume` may be absent or null; show `(no RESUME)`.
   - Read only these three fields. Never open a plan's ledger or design here: the RESUME line is
     the summary, and the ledgers are large.
3. A plan is active unless its status is `done`, `abandoned` or `superseded`, the same rule the
   SessionStart hook uses. An unknown status counts as active, so a bad entry stays visible.

## Output

One section per repository with active plans, repositories sorted by path:

```
<repo path>
  <slug> · <status> — <resume, first line, cut to ~120 characters>
```

Then one line each for: repositories with no active plans (count), "no plan index", and
"Not found". Nothing else: no ledger contents, no gate runs.

If the user wants to resume a plan, ask which one with `AskUserQuestion` (one option per active
plan, up to four; with more, the four most recently listed plus the question's free-text answer
for any other slug). Then read only the `resume` field of `<plans>/<slug>/ledger.json` (or of
`<plans>/<slug>/plan.json` while the plan has no ledger yet), never the whole ledger.
