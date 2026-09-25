# Claude Code hooks

`hooks/hooks.json` wires four Claude Code events to `bin/swiftgate hook <event>`. Every hook is a
silent no-op unless the session's working directory is inside a project with `.swiftgate.toml`
(the nearest one at or above it, never past the git root). No check logic lives in the hooks:
each one calls the same code as the `swiftgate` command it names.

| Event | What it does | Budget |
|---|---|---|
| SessionStart | Injects the module map (package, module, role, kind), the Xcode pin against the selected Xcode, and the RESUME line of each active plan in `.harness/plans/index.json`. | < 1s |
| PreToolUse (Bash) | Denies raw `xcodebuild` (read-only queries such as `-list` pass), `simctl erase\|delete all`, turning snapshot recording on, and deleting the global DerivedData. On `git commit`, adds `swiftgate comments --staged` findings as advisory context. | < 50ms |
| PreToolUse (Edit/Write) | Denies hand edits to `__Snapshots__/`, `Package.resolved`, `.xcresult` bundles, and plan ledgers or the plan index from anyone but the orchestrator. | < 50ms |
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

## Plan state is orchestrator-only

Writes to `.harness/plans/<plan>/ledger.json` and `.harness/plans/index.json` are denied unless
the session is the orchestrator, which is either:

- a session launched with `SWIFT_HARNESS_ORCHESTRATOR=1` in its environment, or
- the session whose id is the content of `.harness/orchestrator.lock`.

A subagent is never the orchestrator, even inside the orchestrator's session: subagents are the
workers the rule exists for. The lock file is gitignored.

## State

Hook state lives in `.harness/hook-state/` (gitignored, and it writes its own `.gitignore`): the
last GREEN fingerprint, per-session strike counts, and a cached module map keyed by the config and
package manifests. Deleting the directory is always safe; it only costs re-runs.

## First run

The plugin's `bin/swiftgate` builds the gate on first use. A hook that finds no built binary starts
the build in the background and returns immediately; the hooks stay inactive until the build
finishes, and SessionStart says so.
