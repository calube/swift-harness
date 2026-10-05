# Telemetry

`swiftgate` records what happens in harness runs as JSON lines on the machine that ran them, so you
can ask what was slow, expensive or wrong and answer from data. Read this page to query those
events, to see what they hold and never hold, or to turn them off.

Telemetry never gates: a failed event write prints 1 line and never changes a verdict, an exit code
or a report. No command sends events anywhere.

## Commands

| Command | Does |
|---|---|
| `swiftgate events summary [--since <when>] [--run <gate run id>] [--build-run <build run id>] [--json]` | Prints the [summary sections](#what-the-summary-answers). `--since` takes `7d`, `12h`, `30m`, an ISO 8601 time or a run id, and defaults to `7d`. |
| `swiftgate events list [--kind <kind>]... [--since <when>] [--run <gate run id>]` | Prints matching events as JSON lines, oldest first, and lists damage on stderr. |
| `swiftgate events ingest --session <id> [--workflow-transcripts <dir> \| --agent-id <id>] [--role <role>] [--task <id>] [--build-run <id>]` | Reads token counts and tool calls offline from transcripts ([Ingest](#ingest)). |
| `swiftgate build halt --run <id> [--task <id>] --reason <reason>` | Records why a build stopped to ask a person: `question`, `stall`, `gate-red`, `merge-conflict`, `amend`, `budget` or `permission`. A return's `review-blocked` records as `question`, and its `design-conflict` as `amend`. |
| `swiftgate build resume --run <id> [--task <id>] --answer <answer>` | Answers the newest open halt (`retry`, `wait`, `abandon`, `amend`, `continue` or `merge`) and records the wait. Exits 1 when no halt is open. |
| `swiftgate events span start\|end` | Records a phase no other event times; `swiftgate report` and `view` draw a build run as a page. See [`run-viewer.md`](run-viewer.md). |
| `swiftgate judge events` | Summarizes the judge log; see [`judge-audit.md`](judge-audit.md). |
| `swiftgate gc --events --older-than <days>` | Removes sealed segments, with their indexes and rollups, whose last event is older, here and in every imported or unkept store. Never touches an active file. |

`events list` and `summary` exit 0 even with damage, and 2 for a bad flag value.

The build skill runs `events ingest` as each worker completes, and the merge fixer's with
`--agent-id`, and calls `build halt` and `resume`. The ship and run skills ingest their session and
print `events summary --build-run <id>`.

### Ingest

`events ingest` reads the session's transcript, its subagents' transcripts (Workflow agents too)
and, with `--workflow-transcripts`, every `agent-*.jsonl` in that directory.

| Topic | Behaviour |
|---|---|
| What it keeps | Message ids, model ids, token counts and times, never the text. Also 1 `agent.tools` per agent per 60 s window of tool calls, with only repository-relative file-tool paths. |
| Repeat runs | Ingesting again adds nothing. |
| Prices | A message the price table can't price is stored without a cost, and the output names its model. |
| `--agent-id` | With the id the Agent tool printed, it reads only that subagent of the session and tags it with `--role`, then required. The build skill uses it for the merge fixer, the run skill for the validation worker. |
| Roles | `orchestrator`, `design`, `plan`, `build-worker`, `build-fixer`, `review`, `qa`, `explorer`, `classifier` |
| Exit 2 | `[telemetry] enabled = false`, outside a project, a bad flag value, an unreadable record or transcript, a malformed usage line, or a failed write. |

## Opting out

Telemetry is on in every repository with a `.swiftgate.toml`. To turn it off:

```toml
[telemetry]
enabled = false
```

That stops every kind except the judge's audit log, which a configured `[judge]` always writes,
since its decisions can block a merge. With telemetry off, `events ingest` exits 2 naming
`telemetry.enabled`; `build halt`, `build resume` and `events span` exit 0 and record nothing; and
`events list` and `summary` still read what exists.

## What's recorded

| Kind | Written by | Holds |
|---|---|---|
| `gate.run` | each recorded gate run | command, verdict, ms, the clean tree's hash or `dirty`, per-tier ms, rule counts, finding paths, allowance counts, test counts |
| `gate.step` | each timed step of a gate run | tier, step, ms, verdict, warm or cold DerivedData, the step's start offset from its gate run when known, and `lockWaitMs`, the part of `ms` its builds waited for another build in the same build directory, when any took a turn |
| `test.result` | every test case of every recorded gate run | test id, target, tier, outcome, ms |
| `prove.result` | each changed test `prove` ran, under its `gate.run` | test id, target, outcome (`proven`, `passes-reverted`, `compile-only`, `crashed`, `hangs-at-base` or `skipped`), the proof base, and where the reverted run first failed: a repository-relative file, a line and the assertion form, never its text |
| `hook.decision` | each hook call | hook event, tool name, decision, rule ids, ms, session id, a salted hash of the tool input |
| `cache.lookup` | the manifest and evidence caches | cache, outcome, key hash, answer hash, tombstone reason |
| `discover.run` | `swiftgate discover` in a brownfield clone | ms, area count, the areas' languages, and counts of values found, guessed, missing and edited; never a command or a path |
| `warmup.run` | `swiftgate warmup`, 1 per area and step; in a brownfield clone, `worktree create` and `run checkout create`, 1 per node install, under the first area it serves | area, step (`generate`, `build`, `test`, or `install` for a node install), ms, `cold` or `warm` cache (an install is `warm` when the directory its manager names as its cache or store held anything), outcome |
| `build.halt`, `build.resume` | `swiftgate build halt` and `resume`, and `build cutoff`, which records a brownfield run's cutoff as `budget` halts it answers at once | build run, task, reason or answer, wait |
| `build.return-checked` | `swiftgate build check-return` | build run, task, verdict, rule ids, and the first 10 findings' messages and the summary, scrubbed |
| `span.start`, `span.end` | `swiftgate events span start` and `end` | a 16-hex span id, its parent span, phase, build run, task and role; the end holds the outcome (`ok`, `red`, `halted` or `abandoned`) and ms |
| `agent.usage` | `swiftgate events ingest` | session, agent, role, task, build run, model, message id and time, token counts, cost |
| `agent.tools` | `swiftgate events ingest` | per agent per 60 s window: session, agent, role, task, build run, window bounds, call counts and summed ms by tool (built-in names; every `mcp__…` tool as `mcp`; any other name only counted), the repository-relative paths file tools named (at most 50), and a count of paths dropped |
| `qa.check` | `swiftgate qa run`, 1 per validation row as the row ends, with the run's id | plan, the row's 1-based position in `validation.json`, requirement id, layer, result (`pass`, `red`, `unverified`, `waiting` or `abandoned`), whether it ran at the merge base, exit status, ms, the run-relative evidence paths, the tasks a waiting row waits on, `reusedFrom` (for a row taken from a validation worker's prepared run, that run's id), and `repairProof: true` for a repair worker's `--prepared-by --requirement` run, which a row's history leaves out until a `qa.repair` adopts it; never the check's command or output, which stay in the run's `qa/report.json` |
| `qa.flow` | `swiftgate qa run`, 1 per flow row that reached its batch, as the row ends, with the run's id; T3, 1 per kept XCUITest flow, under its `gate.run` with `flow` and `test` | plan, row, requirement id, whether it ran at the merge base, `source` (`batch` or `xcuitest`), each step that ran as `{n, label, offsetMs, ok}` plus `captureMs` after a step `qa run` captured after, the leading `open`'s `launch` (`{launchMs, settleMs}`), and the run-relative `video` and `sheet` once a final pass records them |
| `qa.repair` | `swiftgate qa adopt --repair`, 1 per repair plan state took, with the id of the prepared run that proved it red at the base | plan, requirement id, the rows it replaced, build run, `cause` (`flow-side` or `still-red`), the red runs' ids, the step they failed at and its command, and the commands of the steps it took out and put in; never the reason, which stays in plan state's `qa/repairs.json` |
| `qa.setup` | `swiftgate qa run`, 1 per setup step, a row's as the row ends, with the run's id | plan, the row (absent for the run's scratch tree and its device wait), whether it ran at the merge base, `step` (`tree`, `device-wait`, `device`, `build` or `install`), ms (`device-wait` comes first at 0 ms as the wait for the build run's device starts, then with its length), and `reused` when known: a tree whose app build was warm, a device a live hold already had, a build whose DerivedData existed |
| `judge.decision`, `judge.call` | the judge | see [`judge-audit.md`](judge-audit.md) |

### The binary on every event

Every kind carries `source.binary`, the binary `bin/swiftgate` ran:

| Key | Holds |
|---|---|
| `sourceHash` | the 16-hex hash of the sources it built that binary from, set in `SWIFTGATE_SOURCE_HASH` |
| `pluginVersion` | the `version` of `.claude-plugin/plugin.json`, when it has one |

A run without the shim (`swift run`, a test) writes neither. The binary leaves out, and names on
stderr, a value that isn't a hash or a version, so neither ever holds a path. It clears the
variable once read, so no process it starts claims its hash.

## What's never recorded

No source text, diffs, finding or failure messages, prompts, transcript text, tool inputs, shell
commands, environment values or API keys. There are 2 exceptions:

- **`check-return` messages.** `build.return-checked` keeps them, cut and scrubbed as the
  [run viewer](run-viewer-failures.md#privacy) does.
- **File-tool paths.** `agent.tools` keeps the `file_path`, `path` or `notebook_path` of a file tool
  (Read, Edit, Write, MultiEdit, NotebookEdit, Grep, Glob). Each path is relative to the innermost
  of the git top level of the agent's working directory and every worktree of that repository, so a
  worker keeps the paths in its own worktree. It keeps nothing else from a tool's input or output:
  no command, pattern, query, prompt, content, or MCP server or tool name. Ingest drops and counts
  a `~` path, a path outside those roots, and a path the guard rejects.

A guard drops any non-judge event holding a string of 512 bytes or more, a string starting with `/`
or `~`, or a newline, and counts it in `dropped.json`. The gate hashes a test id the guard rejects.
The judge log follows [`judge-audit.md`](judge-audit.md), which redacts backend keys.

## Where events live

- **Per worktree,** in `.harness/events/<stream>.jsonl`, git-ignored. The streams are `judge`,
  `gate`, `test`, `hook`, `cache`, `usage`, `build`, `brownfield`, `span` and `qa`.
- **Brownfield clones.** Every worktree of a brownfield clone writes to the main checkout's store
  under the git common dir, `<git common dir>/swift-harness/events/`.
- **Build halts, return checks and spans** go to the main checkout's store, whichever worktree the
  command starts in.
- **Sealed, never deleted on their own.** Past 4 MiB (16 MiB for `test`) an active file moves to
  `sealed/<stream>/`, compressed with LZFSE, beside an index. A sealed `test` segment also gets a
  rollup, so the summary never decompresses it.
- **Copied up on remove.** `swiftgate worktree remove` copies a worktree's events to the main
  checkout's `.harness/events/imported/<storeID>/`. If the copy fails, it moves them to
  `.harness/events/unkept/<storeID>/` and names the path in its report. Readers read every imported
  and unkept store, each event once.

## What the summary answers

| Section | Answers |
|---|---|
| Cost | what agents and judge calls cost, by role, agent, model, task and design phase, and how much input came from cache |
| Gate time | p50, p95, standard deviation and n per command, tier and step, warm against cold DerivedData |
| Wrong gates | verdicts that flipped on 1 clean tree, findings an allow overturned, a GREEN then a RED on 1 clean tree, and GREEN task gates followed by a RED in the task's write set |
| Flaky and slow tests | tests that passed and failed on 1 clean tree, and the slowest tests by p95 |
| Hooks | latency per hook event, decisions, blocks per rule, and blocks bypassed by a later call with the same input |
| Caches | hit rate, stores, tombstones and stale keys per cache; a stale hit no later store replaces stays invisible |
| Halts | wait per reason, answers, open halts and their age, idle worker-slot time, retries per task |
| Judge | decisions, escalation share, blocks, agreement, latency, cache hits, errors and cost |
| Store | size per kind and stream, sealed segments, dropped events and damage |

Every number carries its n, and a section with no events says "no events yet". `swiftgate stats`
stays the budget view over run history.
