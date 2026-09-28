# Claude Code hooks

`hooks/hooks.json` wires four Claude Code events to `bin/swiftgate hook <event>`. Every hook is a
silent no-op unless the session's working directory is inside a project with `.swiftgate.toml`
(the nearest one at or above it, never past the git root). No check logic lives in the hooks:
each one calls the same code as the `swiftgate` command it names.

| Event | What it does | Budget |
|---|---|---|
| SessionStart | Injects the module map (package, module, role, kind), the Xcode pin against the selected Xcode, the RESUME line of each active plan in the shared `swift-harness/plans/index.json` under the git common dir, and the absolute path of the plugin reference docs (from `CLAUDE_PLUGIN_ROOT`, named only when `standards.md` exists there; otherwise a line saying why it is unavailable). | < 1s |
| PreToolUse (Bash) | Denies raw `xcodebuild` (read-only queries such as `-list` pass), `simctl erase\|delete all`, turning snapshot recording on, and deleting the global DerivedData. Paths it writes go through the Edit/Write guard ([Bash writes](#bash-writes)). On `git commit`, adds `swiftgate comments --staged` findings as advisory context. | < 50ms |
| PreToolUse (Edit/Write) | Denies hand edits to `__Snapshots__/`, `Package.resolved`, `.xcresult` bundles, and a plan's `orchestrator.lock`. Plan state and design artifacts are writable only by the orchestrating session (below). | < 50ms |
| PreToolUse (subagent) | Decides every Bash, Edit, Write, WebFetch and WebSearch call a subagent makes with an explicit allow or deny, never the prompt ([Subagents never prompt](#subagents-never-prompt)). | < 50ms |
| PostToolUse (Edit/Write `*.swift`) | Formats the file in place with `swift format`, then runs `swiftgate lint` on that file alone. A gating finding comes back as a block next to the tool result. | < 1s |
| Stop | Runs `swiftgate check --tier fast` and blocks the stop when it is RED. | ≤ 90s |

## Stop policy

- Content that already passed is not re-checked: the hook fingerprints HEAD plus the changed Swift
  files, `Package.resolved` and `.swiftgate.toml`, and skips when the fingerprint matches the last
  GREEN run. Unchanged content that was RED reuses that verdict instead of re-running.
- A RED stop is blocked at most 3 times in a row. The next stop is released with the message
  `RED — not done`.
- BLOCKED (git, SwiftPM, the formatter, or the Xcode pin) never blocks and never counts as a
  strike; the user sees why the gate could not judge.
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
| `swift-harness/plans/<plan>/` and any file in it | the session whose id is in that plan's `orchestrator.lock` |
| `swift-harness/plans/index.json` | a session holding any plan's lock |
| a design doc, or a file in its `<doc>.evidence/` | the session holding the lock of the one plan whose `plan.json` `design` names that doc; nobody while two plans name it |
| a plan's `plan.json` | its lock holder, by Write or Edit (never Bash), keeping `design`; a missing or unreadable one may name a doc no other plan names |
| `orchestrator.lock`, and the `claim.lock.*` and `index.lock.*` files in the plans root | nobody; only `swiftgate plan claim`, `plan release` and `index set` write them |

`SWIFT_HARNESS_ORCHESTRATOR=1` in the session's environment allows every row except the last. A
subagent is never allowed, even inside the lock holder's session and with the override: subagents
are the workers the rule exists for. A worker that finds the design wrong reports
`design-conflict` or `needs-replan` instead.

The guard only reads locks; it never claims a plan. A held lock counts until
`swiftgate plan release` removes it. If git can't name the common dir, no design lock can be
found, so only the override allows a design write. The same holds when no plan names the doc,
or when the holder's `plan.json` is missing or corrupt: claim the plan with a `plan.json` that
names the doc first. The guard resolves a relative `design` against the project root (the
directory holding `.swiftgate.toml`), as `plan claim` and `evidence check` read it, and compares
canonical paths, so a sibling worktree's copy of the doc isn't the plan's doc.

No tool call may run `swiftgate plan release --force`: taking over a lock is the user's call.
The guard denies `swiftgate plan claim|release|set` and `index set` to a subagent, and to a main
session whose `--session` names another id or isn't a literal.

Plan-state commands check the same authority, and exit 1 on refusal:

| Command | Writes | Refused when |
|---|---|---|
| `plan claim <plan> --session <id> [--design <doc>] [--tier <tier>]` | the lock; a new plan's `plan.json` | another session holds the plan, or another plan names `<doc>` (canonical path, any case) |
| `plan release <plan> --session <id>` | removes the lock | another session holds it |
| `plan set <plan> --session <id> [--tier <tier>] [--resume <text>]` | `plan.json` `tier`, `resume` | `<id>` isn't the holder |
| `index set <plan> <status> <resume> --session <id>` | the plan's `index.json` entry | `<id>` isn't the holder |

A refusal names the holder. Taking over a lock whose session has ended is the user's decision.

## Subagents never prompt

A background subagent can't answer a permission prompt, so its call would never run. When a
PreToolUse call carries `agent_id`, the hook decides it after the guards above:

| The call | Decision |
|---|---|
| A write into `.git`, `.claude`, `.vscode` or `.idea`, which Claude Code always asks about | deny (`guard.subagent-protected-path`) |
| A write outside the repository's checkouts, such as `/tmp` | deny, naming `.harness/tmp/` (`guard.subagent-outside-checkouts`) |
| A build worker's or fixer's write to the main checkout | deny (`guard.build-agent-main-checkout`) |
| Anything else | allow |

The checkouts are the main checkout and each sibling `<repo>-…` directory whose `.git` is a file.
The hook judges the write targets [Bash writes](#bash-writes) can parse. Claude Code ignores a
plugin agent's `permissionMode`, so the hook is the only lever, and a settings `deny` or `ask`
rule still wins.

## Bash writes

The guard judges each path a Bash command writes as it judges a Write to that path, with the same
payload. It finds redirections (`>`, `>>`, `&>`, `<>`), `tee`, and the destination of `cp`, `mv`,
`install` and `ln`. It also finds the operands of `rm`, `truncate` and `touch`, `dd of=`, and
`sed -i`/`perl -i` files, and every operand of `git checkout`, `git restore`, `git rm` and
`git mv` (after `-C`), anywhere in the command. Relative paths resolve against the working
directory and any literal `cd` before them. The guard denies a subagent's `echo {} > ledger.json`
as it denies its Write, and the lock holder can still write its ledger through Bash. Reads, `cp` sources, quoted text and `2>&1` aren't writes.

Known limits: the guard stops accidental and ordinary writes; it isn't a sandbox. It doesn't judge
interpreter code (`python3 -c`, `node -e`), heredoc text, `eval` of a built string, targets spelled
with `$VAR` or `$(…)`, or a recursive delete of a guarded directory's parent. For git: a branch
switch, `reset`, `stash`, `clean`, a parent directory, glob or `:(magic)` pathspec, and
`--pathspec-from-file`.

## State

Hook state lives in `.harness/hook-state/` (gitignored, and it writes its own `.gitignore`): the
last GREEN fingerprint, per-session strike counts, and a cached module map keyed by the config and
package manifests. Deleting the directory is always safe; it only costs re-runs.

`plan-lock-cache-<session>.json` keeps a session's git common dir; the guard still reads locks
and `plan.json` fresh.

## First run

The plugin's `bin/swiftgate` builds the gate on first use and again after its sources change. A
hook that finds no binary for the current sources starts the build in the background. Meanwhile it
runs the last binary this gate built, or with no record of it the newest one in the cache, so
older rules keep enforcing during a rebuild. Only a cache with no binary at all leaves the hooks
inactive until the build finishes, and SessionStart says so.
