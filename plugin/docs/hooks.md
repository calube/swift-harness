# Claude Code hooks

This page says what each swift-harness hook does to a Claude Code session. Read it when a hook
denied a tool call, blocked a stop or added context, and you want to know why. Every denial names
its rule id, such as `swiftgate guard.raw-xcodebuild: …`; look the id up in
[Guard rule ids](#guard-rule-ids).

## How the hooks run

`hooks/hooks.json` wires 4 Claude Code events to `bin/swiftgate hook <event>`. No check logic lives
in the hooks: each one calls the same code as the `swiftgate` command it names.

| Topic | Behaviour |
|---|---|
| Where hooks act | Inside a project with `.swiftgate.toml` (the nearest one at or above the working directory, never past the git root), or inside a brownfield clone. Anywhere else every hook is a silent no-op, except the review agents' Bash limit (`guard.reviewer-bash`), which belongs to the agent and holds wherever it runs. |
| Brownfield clones | A `swiftgate run` session loads the plugin for its skills and the clone's own settings for its hooks. Only the hooks those settings start act: SessionStart, PreToolUse and Stop. PostToolUse stays silent, since it would format code to this harness's style rather than the team's. Stop gates at `slice` instead of `fast`. |
| Recording | Each hook call writes a `hook.decision` event unless telemetry is off ([`telemetry.md`](telemetry.md)). A failed write never changes the decision. |
| Denied Bash calls | Every Bash denial ends with a note: no part of the command ran, not even the steps before the refused one (no heredoc file, redirect, copy or commit). Run those parts again without the refused step. |

## The hooks

| Event | What it does | Budget |
|---|---|---|
| SessionStart | Injects the session context (below) and records which plugin the session loaded ([Session records](#session-records)). | < 1s |
| PreToolUse (Bash, Monitor) | Runs the Bash guards ([Guard rule ids](#guard-rule-ids)) and judges every path the command writes as a Write ([Bash writes](#bash-writes)). A Monitor command is a shell script too, so it gets the Bash guards. On `git commit`, adds advisory context (below). | < 50ms |
| PreToolUse (Bash, `swiftgate run` session) | Rewrites the call so the user's shell profile can't stall it ([Run sessions](#run-sessions)). | < 50ms |
| PreToolUse (Edit, Write, MultiEdit, NotebookEdit) | Denies hand edits to recorded or generated files, and guards plan state and design artifacts ([Plan state and design artifacts](#plan-state-and-design-artifacts-are-orchestrator-only)). | < 50ms |
| PreToolUse (Agent) | Denies a `swift-harness:build-worker` or `swift-harness:build-fixer` launch without `run_in_background: true` (`guard.build-agent-foreground`). A foreground one holds the build loop's merges and starts until it returns. Every other Agent call goes to the normal permission flow. | < 50ms |
| PreToolUse (any subagent call) | Decides every Bash, Edit, Write, WebFetch and WebSearch call a subagent makes with an explicit allow or deny, never a prompt ([Subagents never prompt](#subagents-never-prompt)). | < 50ms |
| PostToolUse (Edit, Write, MultiEdit on `*.swift`) | Formats the file in place with `swift format`, then runs `swiftgate lint` on that file alone. A gating finding comes back as a block next to the tool result. | < 1s |
| Stop | Runs `swiftgate check --tier fast`, or `--tier slice` in a brownfield clone, and blocks the stop when it is RED ([Stop policy](#stop-policy)). | ≤ 90s |

### SessionStart context

| Line | Content |
|---|---|
| Module map | package, module, role and kind |
| Xcode | the Xcode pin against the selected Xcode |
| Plans | the RESUME line of each active plan, from the shared `swift-harness/plans/index.json` in the git common dir |
| Reference docs | the absolute path of the plugin's docs, from `CLAUDE_PLUGIN_ROOT`, named only when `standards.md` exists there; otherwise why it is unavailable |
| Scratch worktrees | each scratch worktree a killed `prove` or `mutate` run left behind, which the hook removes or reports it couldn't |

### Advice on `git commit`

On a `git commit`, PreToolUse adds advisory context and never denies the commit. A brownfield clone
gets none.

| Advice | Detail |
|---|---|
| `swiftgate comments --staged` findings | The git pre-commit hook enforces the blocking ones. |
| The comment judge's CUT and TRIM answers | Only when the repository enables `[judge]`, on up to 6 staged comments. Answers are cached; the judge is skipped after 15 s. |

The hook reads the index as it stands when it fires, so in `git add … && git commit` as 1 command
the git pre-commit hook checks the new files instead.

## Guard rule ids

Each guard denies 1 kind of call and names how to do the job instead.

### Bash guards

| Rule id | Denies |
|---|---|
| `guard.raw-xcodebuild` | `xcodebuild` doing work. Read-only queries pass: `-list`, `-version`, `-showsdks`, `-showBuildSettings`, `-showdestinations`, `-showTestPlans`, `-help`, `-usage`, `-checkFirstLaunchStatus`, `-showComponent`. Use `swiftgate check` or `swiftgate test`. |
| `guard.simctl-all` | `simctl erase all` and `simctl delete all`, which destroy other sessions' simulators. |
| `guard.snapshot-record` | Setting `SNAPSHOT_TESTING_RECORD` or `TEST_RUNNER_SNAPSHOT_TESTING_RECORD` to any value but empty or `never`. Use `swiftgate snapshots record`. |
| `guard.global-derived-data` | Deleting the global DerivedData, or a folder above it, with `rm`, `rmdir`, `unlink`, `trash`, `srm` or `find -delete`. Prune with `swiftgate gc`. |
| `guard.validation-flow-by-hand` | An `agent-device batch` whose `--steps-file` is a validation flow, under `.harness/qa/` or a plan's `qa/` folder. Only `swiftgate qa run` drives one. |
| `guard.bare-stdin-reader` | An `ls` that names no folder, and a `cat`, `bat`, `head`, `tail`, `grep`, `less`, `more` or `read` that names no file and that no pipe, heredoc or `<` feeds. An alias such as `eza` or `bat` reads stdin, which the Bash tool leaves open whenever the command holds a heredoc, so the call hangs until its timeout. `ls .` and `cat <file>` pass. |
| `guard.process-match-wait` | `pkill` and `killall` in every session. In a subagent, also `pgrep -f`, and a `while` or `until` loop on `pgrep`. Each matches every session's processes by name, and `pgrep -f` matches its own shell, so the loop never ends. |
| `guard.qa-run-truncated` | Piping `swiftgate qa run` into `head` or `tail`, which cuts off rows or the closing `summary`. Write its `--json` to a file instead. |
| `guard.qa-run-timeout` | Wrapping `swiftgate qa run` in `timeout` or `gtimeout`, which kills it with no report. Bound it with `--deadline` instead. |
| `guard.gate-output-outside-run` | A `swiftgate` call whose output a redirect or `tee` sends outside the repository's checkouts and git common dir, such as `/tmp/x.json`. The denial names the plan's `out/` folder. |
| `guard.plan-state` | `swiftgate plan release --force` from any tool call: taking over a lock is the user's call. Also, in a subagent, `plan claim`, `plan release`, `plan set`, `index set`, `ledger set`, `build start`, `build finish`, `build merge`, `build cutoff` and `worktree create`. In a main session, any of these whose `--session` names another session or isn't a literal. |
| `guard.raw-swift-build` | In a brownfield clone, `swift build` or `swift test` with no `--scratch-path` or `--build-path`. It would build cold beside the scratch path the warm-up and gates share. |
| `guard.dirty-file` | In a brownfield clone, staging a file that held uncommitted work before the run began: `git add` or `git stage` naming it or a folder above it, `git add -A`, `-u` or `.` at the root, and `git commit -a` or `git commit <path>`. Stage your own files by name. |

A build agent runs its gates in the foreground at the Bash tool's longest timeout, 600000 ms. A gate
that may outlast that runs in the background with its `--json` sent to a file, and
`swiftgate build gate-wait` waits on the file.

### Edit and Write guards

| Rule id | Denies |
|---|---|
| `guard.snapshot-reference` | Hand edits under `__Snapshots__/`. Use `swiftgate snapshots record`. |
| `guard.package-resolved` | Hand edits to `Package.resolved`. Change `Package.swift` and run `swift package resolve`. |
| `guard.xcresult` | Edits inside an `.xcresult` bundle, which is test evidence. |
| `guard.plan-state` | Writes to plan state or design artifacts by anyone but the session allowed to ([below](#plan-state-and-design-artifacts-are-orchestrator-only)). |
| `guard.run-user-checkout` | In a brownfield clone, while the session holds a plan's lock: a write inside the user's checkout, outside its `.git`. A run commits in its plan checkout and keeps scratch files there. |

Bash commands get these guards too, through [Bash writes](#bash-writes).

### Subagent and agent guards

| Rule id | Denies |
|---|---|
| `guard.subagent-protected-path` | A subagent's write into `.git`, `.claude`, `.vscode` or `.idea`, which Claude Code always asks about. |
| `guard.subagent-outside-checkouts` | A subagent's write outside the repository's checkouts, such as `/tmp`. The denial names `.harness/tmp/`. |
| `guard.build-agent-main-checkout` | A build worker's or fixer's write to the main checkout. |
| `guard.reviewer-bash` | Any Bash call by `swift-harness:architecture`, `swift-harness:test-quality` or `swift-harness:verifier` other than 1 `swiftgate events span start\|end`, even outside a project. These agents hold no Bash, so the guard is a backstop for a call that is ever attempted. |
| `guard.fixer-gate-cap` | A merge fixer's `swiftgate check` at `push`, `ready`, `merge` or `final` once its worktree's run history holds 3 such runs. The denial names `swiftgate test-only`. |
| `guard.build-agent-foreground` | A build worker or fixer launched without `run_in_background: true`. |
| `guard.foreground-timeout` | Not a denial: in a run session, holds an orchestrator's foreground Bash `timeout` to 120 s ([Run sessions](#run-sessions)). |

## Run sessions

In a `swiftgate run` session, once the guards pass, the hook returns the Bash call as
`updatedInput` so the user's shell profile can't stall it.

| Change | When | Effect |
|---|---|---|
| Shell isolation: `\builtin unalias -a; \builtin set +C; \builtin eval '<command>' </dev/null` | permissions bypassed, and every subagent call | No alias applies (`cp -i`, `cat` as `bat`, `ls` as `eza`), `>` overwrites under `noclobber`, and stdin is empty. |
| Foreground `timeout` held to 120 s (`guard.foreground-timeout`) | an orchestrator call that runs no `swiftgate` | A hung call moves to the background instead of holding the run past its cutoff. `swiftgate` calls bound their own waits and keep 600000. |

Where permission rules judge the call, only the timeout changes, since a rewritten command no longer
matches a rule.

## Stop policy

| Case | What happens |
|---|---|
| Content already passed | The hook fingerprints HEAD plus the changed Swift files, `Package.resolved` and `.swiftgate.toml` (every changed path in a brownfield clone), and skips when it matches the last GREEN run. |
| Unchanged content that was RED | The hook reuses that verdict instead of running again. |
| RED | The hook blocks the stop, at most 3 times in a row. It releases the next stop with the message `RED — not done`. |
| BLOCKED (git, SwiftPM, the formatter or the Xcode pin) | The stop goes through and doesn't count as a strike; the user sees why the gate couldn't judge. |
| A stop without `stop_hook_active` | Claude Code sets the flag on a stop that follows a block. Without it, the strike count starts over. |

## Plan state and design artifacts are orchestrator-only

The guard (`guard.plan-state`) covers:

- shared plan state in the git common dir: `swift-harness/plans/index.json` and every file in
  `swift-harness/plans/<plan>/`, such as `plan.json` and `ledger.json`;
- design docs, `docs/**/designs/*.md`;
- everything under a `*.evidence/` directory: claims, amendments, snapshots, captures and probes.

Before matching, the guard resolves the tool's path every way a write could land: relative to the
session's working directory, with `..` removed before and after following symlinks, and through
symlinks, including a dangling one. Names compare without regard to case, as on the default APFS
volume. So the guard judges a write through `../`, a symlink, a sibling worktree, the common dir
reached from a linked worktree, or a different letter case like the canonical path.

Who may write:

| Target | Allowed |
|---|---|
| `swift-harness/plans/<plan>/` and any file in it | the session whose id is in that plan's `orchestrator.lock` |
| `swift-harness/plans/index.json` | a session holding any plan's lock |
| a design doc, or a file in its `<doc>.evidence/` | the session holding the lock of the 1 plan whose `plan.json` `design` names that doc; nobody while 2 plans name it |
| a plan's `plan.json` | its lock holder, by Write or Edit (never Bash), keeping `design`; a missing or unreadable one may name a doc no other plan names |
| a sprint page, a `.md` file directly in `swift-harness/plans/sprints/` | any main session, with no lock; never a subagent, and nothing else under `sprints/` |
| `orchestrator.lock`, and the `claim.lock.*`, `index.lock.*`, `ledger.lock.*` and `events.lock.*` files | nobody; only `swiftgate` writes them |

`SWIFT_HARNESS_ORCHESTRATOR=1` in the session's environment allows every row except the last. No
subagent qualifies, even inside the lock holder's session and with the override: subagents
are the workers the rule exists for. A worker that finds the design wrong reports
`design-conflict` or `needs-replan` instead.

The guard only reads locks; it never claims a plan. A held lock counts until
`swiftgate plan release` removes it. A design write needs a plan that names the doc:

- If git can't name the common dir, the guard finds no design lock, so only the override allows a
  design write.
- The same holds when no plan names the doc, or when the holder's `plan.json` is missing or
  corrupt. Claim the plan with a `plan.json` that names the doc first.

The guard resolves a relative `design` against the project root (the directory holding
`.swiftgate.toml`), as `plan claim` and `evidence check` read it. It compares canonical paths, so
a sibling worktree's copy of the doc isn't the plan's doc.

The plan-state commands check the same authority, and exit 1 on refusal:

| Command | Writes | Refused when |
|---|---|---|
| `plan claim <plan> --session <id> [--design <doc> \| --spec-page] [--tier <tier>]` | the lock; a new plan's `plan.json` | another session holds the plan, or another plan names `<doc>` (canonical path, any case) |
| `plan release <plan> --session <id>` | removes the lock | another session holds it |
| `plan set <plan> --session <id> [--tier <tier>] [--resume <text>]` | `plan.json` `tier`, `resume` | `<id>` isn't the holder |
| `index set <plan> <status> <resume> --session <id>` | the plan's `index.json` entry | `<id>` isn't the holder |

A refusal names the holder. Taking over a lock whose session has ended is the user's decision.

## Subagents never prompt

A background subagent can't answer a permission prompt, so a call that raises one would never run.
When a PreToolUse call carries `agent_id`, the hook decides it after the guards above:

| The call | Decision |
|---|---|
| A write into `.git`, `.claude`, `.vscode` or `.idea` | deny (`guard.subagent-protected-path`) |
| A write outside the repository's checkouts, such as `/tmp` | deny, naming `.harness/tmp/` (`guard.subagent-outside-checkouts`) |
| A build worker's or fixer's write to the main checkout | deny (`guard.build-agent-main-checkout`) |
| A reviewer's or verifier's Bash other than 1 `swiftgate events span start\|end`, even outside a project; they hold no Bash, so only if ever attempted | deny (`guard.reviewer-bash`) |
| A merge fixer's `swiftgate check` at `push`, `ready`, `merge` or `final` when its worktree's run history already holds 3 such runs | deny, naming `swiftgate test-only` (`guard.fixer-gate-cap`) |
| Anything else | allow |

The checkouts are the main checkout and each sibling `<repo>-…` directory whose `.git` is a file.
The hook judges the write targets [Bash writes](#bash-writes) can parse. Claude Code ignores a
plugin agent's `permissionMode`, so the hook is the only lever, and a settings `deny` or `ask`
rule still wins.

## Bash writes

The guard judges each path a Bash command writes as it judges a Write to that path, with the same
payload. So it denies a subagent's `echo {} > ledger.json` as it denies its Write, and the lock
holder can still write its ledger through Bash.

| Judged as writes, anywhere in the command | Not judged |
|---|---|
| redirections (`>`, `>>`, `&>`, `<>`) and `tee` | reads, `cp` sources, quoted text and `2>&1`, which aren't writes |
| the destination of `cp`, `mv`, `install` and `ln` | interpreter code (`python3 -c`, `node -e`), heredoc text, `eval` of a built string |
| the operands of `rm`, `truncate` and `touch`, and `dd of=` | targets spelled with `$VAR` or `$(…)` |
| the files of `sed -i` and `perl -i` | a recursive delete of a guarded directory's parent |
| every operand of `git checkout`, `git restore`, `git rm` and `git mv`, after `-C` | for git: a branch switch, `reset`, `stash`, `clean`, a parent directory, glob or `:(magic)` pathspec, and `--pathspec-from-file` |

Relative paths resolve under a guaranteed literal `cd`, and against the working directory too. The
guard stops accidental and ordinary writes; it isn't a sandbox.

## State

Hook state lives in `.harness/hook-state/`, which is git-ignored and writes its own `.gitignore`.
It holds the last GREEN fingerprint, per-session strike counts, and a cached module map keyed by
the config and package manifests. Deleting the directory is always safe; it only costs re-runs.

`plan-lock-cache-<session>.json` keeps a session's git common dir. The guard still reads locks and
`plan.json` fresh.

### Session records

A running session keeps the prompts it loaded at start, so SessionStart records which plugin that
was. It writes `sessions/<session id>.json` with these keys:

| Key | Holds |
|---|---|
| `schemaVersion` | 1 |
| `sessionId` | the session id |
| `recordedAt` | when the hook wrote it |
| `pluginRoot` | `CLAUDE_PLUGIN_ROOT` |
| `pluginVersion` | the plugin's version |
| `treeHash` | a SHA-256 over the plugin version and each file's path and bytes under `skills/`, `agents/` and `workflows/` |
| `transcriptPath` | optional: the session's transcript |

`swiftgate doctor` recomputes `treeHash` at `pluginRoot` to spot a session running stale prompts.
Reading fails on an unknown key or version. The hook writes only a session id that is a safe file
name, by atomic rename, and keeps the newest 20 records. A compacted session keeps its start
record. A failed write becomes a `Session record not written` line in the session context.

## First run

The plugin's `bin/swiftgate` builds the gate on first use and again after its sources change. A
hook that finds no binary for the current sources starts the build in the background. Meanwhile it
runs the last binary this gate built or, with no record of that, the newest one in the cache, so
older rules keep enforcing during a rebuild. Only a cache with no binary at all leaves the hooks
inactive until the build finishes, and SessionStart says so.
