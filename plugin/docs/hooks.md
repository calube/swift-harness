# Claude Code hooks

`hooks/hooks.json` wires four Claude Code events to `bin/swiftgate hook <event>`. Every hook is a
silent no-op unless the session's working directory is inside a project with `.swiftgate.toml`
(the nearest one at or above it, never past the git root). No check logic lives in the hooks:
each one calls the same code as the `swiftgate` command it names.

| Event | What it does | Budget |
|---|---|---|
| SessionStart | Injects the module map (package, module, role, kind), the Xcode pin against the selected Xcode, and the RESUME line of each active plan in `.harness/plans/index.json`. | < 1s |
| PreToolUse (Bash) | Denies raw `xcodebuild` (read-only queries such as `-list` pass), `simctl erase\|delete all`, turning snapshot recording on, and deleting the global DerivedData. On `git commit`, adds `swiftgate comments --staged` findings as advisory context. | < 50ms |
| PreToolUse (Edit/Write) | Denies hand edits to `__Snapshots__/`, `Package.resolved`, `.xcresult` bundles, and a plan's `orchestrator.lock`. Plan state and design artifacts are writable only by the orchestrating session (below). | < 50ms |
| PostToolUse (Edit/Write `*.swift`) | Formats the file in place with `swift format`, then runs `swiftgate lint` on that file alone. A gating finding comes back as a block next to the tool result. | < 1s |
| Stop | Runs `swiftgate check --tier fast` and blocks the stop when it is RED. | ≤ 90s |

## Stop policy

- Content that already passed is not re-checked: the hook fingerprints HEAD plus the changed Swift
  files, `Package.resolved` and `.swiftgate.toml`, and skips when the fingerprint matches the last
  GREEN run. Unchanged content that was RED reuses that verdict instead of re-running.
- A RED stop is blocked at most 3 times in a row. The next stop is released with the message
  `RED — not done`.
- BLOCKED (git, SwiftPM or the formatter could not run) never blocks and never counts as a strike;
  the user sees why the gate could not judge.
- Claude Code's `stop_hook_active` flag marks a stop that follows a block. A stop without it starts
  the strike count over.

## Plan state and design artifacts are orchestrator-only

The guard covers:

- shared plan state in the git common dir: `swift-harness/plans/index.json` and every file in
  `swift-harness/plans/<plan>/`, such as `plan.json` and `ledger.json`;
- design docs, `docs/**/designs/*.md`;
- everything under a `*.evidence/` directory: claims, amendments, snapshots, captures and probes.

Before matching, the guard resolves the tool's path every way a write could land: relative to the
session's working directory, with `..` removed before and after following symlinks, and through
symlinks, including a dangling one. Names compare case-insensitively, as on the default APFS
volume. So a write through `../`, a symlink, a sibling worktree, the common dir reached from a
linked worktree, or a different letter case is judged like the canonical path.

Who may write:

| Target | Allowed |
|---|---|
| a file in `swift-harness/plans/<plan>/` | the session whose id is in that plan's `orchestrator.lock` |
| `swift-harness/plans/index.json` | a session holding any plan's lock |
| a design doc, or a file in its `<doc>.evidence/` | the session holding the lock of the plan whose `plan.json` `design` names that doc |
| `orchestrator.lock` | nobody; only `swiftgate plan claim` and `swiftgate plan release` write it |

`SWIFT_HARNESS_ORCHESTRATOR=1` in the session's environment allows every row except the last. A
subagent is never allowed, even inside the lock holder's session and with the override: subagents
are the workers the rule exists for. A worker that finds the design wrong reports
`design-conflict` or `needs-replan` instead.

The guard only reads locks; it never claims a plan. A held lock counts until
`swiftgate plan release` removes it. If git can't name the common dir, no design lock can be
found, so only the override allows a design write. The same holds when no plan names the doc,
or when the holder's `plan.json` is missing or corrupt: claim the plan with a `plan.json` that
names the doc first. `design` is resolved against the worktree toplevel and compared as a
canonical path, so a sibling worktree's copy of the doc isn't the plan's doc.

## State

Hook state lives in `.harness/hook-state/` (gitignored, and it writes its own `.gitignore`): the
last GREEN fingerprint, per-session strike counts, and a cached module map keyed by the config and
package manifests. Deleting the directory is always safe; it only costs re-runs.

## First run

The plugin's `bin/swiftgate` builds the gate on first use. A hook that finds no built binary starts
the build in the background and returns immediately; the hooks stay inactive until the build
finishes, and SessionStart says so.
