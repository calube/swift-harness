# Simulator QA stage

This page covers `swiftgate qa stage`, which copies 1 requirement's adopted checks from plan state
into a checkout so a validation worker can repair a flow row: the reverse of `qa adopt`. Read it
when the build loop stages a [flow repair](simulator-qa-flow-repair.md) or `qa stage` refuses.

## qa stage

```bash
swiftgate qa stage <worktree> --plan <slug> --requirement <requirement> [--json]
```

It removes `<worktree>/.harness/qa/`, then copies into `<worktree>/.harness/qa/<plan>/` each check
file that the plan's `validation.json` rows for that requirement name, from the plan's `qa/` in
plan state. Each file keeps its permissions.

| Flag | What it does |
|---|---|
| `--plan <slug>` | The plan whose adopted checks it copies |
| `--requirement <requirement>` | The requirement whose rows' check files it copies |
| `--json` | Prints the report as JSON |

It copies nothing unless the path is a checkout that `git worktree list` names, some row of the
requirement checks a `qa/` file, and every such file is in plan state.

| Exit | When |
|---|---|
| 0 | GREEN: it filled the folder |
| 1 | RED: it refused, and the message ends "nothing was staged" |
| 2 | BLOCKED: it couldn't list the checkouts, resolve or read plan state, or copy a file |

## Output

Text output is `qa stage: <verdict> <message>`, then 1 indented line per copied file. The JSON
report holds `command`, `worktree`, `plan`, `requirement`, `verdict`, `destination` (the folder it
filled), `files` (each copied file's name) and `message`. A copy that fails partway says to remove
`.harness/qa/` before a repair worker starts there.
