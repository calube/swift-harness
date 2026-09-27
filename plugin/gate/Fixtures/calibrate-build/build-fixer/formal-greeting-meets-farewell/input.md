Repair 1 merge of plan `{{plan}}`.

- Plan slug: `{{plan}}`
- Task: `{{task}}`, whose branch `build merge` merged into the fix worktree
- Fix worktree: `{{worktree}}` (already checked out)
- Fix branch: `{{branch}}`
- Case: a conflicted merge. The merge is still in progress; `git status` lists the unmerged files.
- Merge gate tier: `fast`

The return of `{{task}}`, the task being merged:

```json
{
  "task": "{{task}}",
  "outcome": "ready-to-merge",
  "commits": ["{{taskCommit}}"],
  "gate": {"tier": "fast", "verdict": "GREEN", "runId": "20260927T090000Z-1a2b3c4d"},
  "review": {"mode": "gate", "findings": []},
  "testsAdded": ["test-formal-greeting", "test-informal-greeting"],
  "notes": "Greeter: `public static func greet(_ name: String, formal: Bool) -> String`. `formal: true` returns `Good day, <name>.`; `formal: false` returns exactly `greet(_:)`, `Hello, <name>`.",
  "designConflict": null
}
```

The return of `farewell`, the task already on `main`:

```json
{
  "task": "farewell",
  "outcome": "ready-to-merge",
  "commits": ["{{mainCommit}}"],
  "gate": {"tier": "fast", "verdict": "GREEN", "runId": "20260927T085500Z-5e6f7a8b"},
  "review": {"mode": "gate", "findings": []},
  "testsAdded": ["test-farewell-by-name"],
  "notes": "Greeter: `public static func farewell(_ name: String) -> String` returns `Goodbye, <name>`.",
  "designConflict": null
}
```
