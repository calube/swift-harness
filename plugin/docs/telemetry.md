# Telemetry

`swiftgate` records what happens in harness runs as JSON lines on the machine that ran them, so you can ask
what was slow, expensive or wrong and answer from data. Telemetry never gates: a failed event write prints 1
line and never changes a verdict, an exit code or a report.

## What's recorded

| Kind | Written by | Holds |
|---|---|---|
| `gate.run` | each recorded gate run | command, verdict, ms, the clean tree's hash or `dirty`, per-tier ms, rule counts, finding paths, allowance counts, test counts |
| `gate.step` | each timed step of a gate run | tier, step, ms, verdict, warm or cold DerivedData |
| `test.result` | every test case of every recorded gate run | test id, target, tier, outcome, ms |
| `hook.decision` | each hook call | hook event, tool name, decision, rule ids, ms, session id, a salted hash of the tool input |
| `cache.lookup` | the manifest and evidence caches | cache, outcome, key hash, answer hash, tombstone reason |
| `build.halt`, `build.resume` | `swiftgate build halt` and `resume` | build run, task, reason or answer, wait |
| `agent.usage` | `swiftgate events ingest` | session, agent, role, task, build run, model, message id and time, token counts, cost |
| `judge.decision`, `judge.call` | the judge | see [`judge-audit.md`](judge-audit.md) |

## What's never recorded

No source text, diffs, finding or failure messages, prompts, transcript text, tool inputs, shell commands,
environment values or API keys. Paths are repository-relative; nothing records a path outside the repository.
A guard drops any non-judge event holding a string over 512 bytes, a string starting with `/` or `~`, or a
newline, and counts it in `dropped.json`; the gate hashes a test id the guard rejects. The judge log follows [`judge-audit.md`](judge-audit.md), which
redacts backend keys. No command sends events anywhere.

## Where events live

- **Per worktree,** in `.harness/events/<stream>.jsonl`, git-ignored. The streams are `judge`, `gate`, `test`,
  `hook`, `cache`, `usage` and `build`.
- **Sealed, never deleted on their own.** Past 4 MiB (16 MiB for `test`) an active file moves to
  `sealed/<stream>/`, compressed with LZFSE, beside an index. A sealed `test` segment also gets a rollup, so the
  summary never decompresses it.
- **Build halts** go to the main checkout's store, where the orchestrator runs.
- **Copied up on remove.** `swiftgate worktree remove` copies a worktree's events to main's
  `.harness/events/imported/<storeID>/`. If the copy fails, it moves them to `.harness/events/unkept/<storeID>/`
  and names the path in its report. Readers read every imported and unkept store, each event once.

## Opting out

Telemetry is on in every repository with a `.swiftgate.toml`. To turn it off:

```toml
[telemetry]
enabled = false
```

That stops every kind except the judge's audit log, which a configured `[judge]` always writes, since its
decisions can block a merge. `events ingest` then exits 2 naming `telemetry.enabled`, `build halt` and `resume`
exit 0 with nothing recorded, and `events list` and `summary` still read what exists.

## Commands

- `swiftgate events list [--kind <kind>]... [--since 7d|12h|30m|<ISO time>|<run id>] [--run <gate run id>]`
  prints matching events as JSON lines, oldest first, and lists damage on stderr.
- `swiftgate events summary [--since <same forms>] [--run <gate run id>] [--build-run <build run id>] [--json]`
  prints the sections below. `--since` defaults to `7d`.
- `swiftgate events ingest --session <id> [--workflow-transcripts <dir>] [--role <role>] [--task <id>]
  [--build-run <id>]` reads token counts offline from the session's transcript, its subagents' transcripts and,
  with `--workflow-transcripts`, every `agent-*.jsonl` in that directory. It keeps message ids, model ids,
  counts and times, and never the text or a path. Ingesting again adds nothing. Ingest stores a message
  the price table can't price without a cost, and names its model in the output. Roles: `orchestrator`, `design`, `plan`,
  `build-worker`, `review`, `qa`.
- `swiftgate build halt --run <id> [--task <id>] --reason <reason>` records why a build stopped to ask a
  person: `question`, `stall`, `gate-red`, `merge-conflict`, `amend`, `budget` or `permission`.
- `swiftgate build resume --run <id> [--task <id>] --answer <answer>` answers the newest open halt (`retry`,
  `wait`, `abandon`, `amend` or `continue`) and records the wait. It exits 1 when no halt is open.
- `swiftgate judge events` summarizes the judge log; see [`judge-audit.md`](judge-audit.md).
- `swiftgate gc --events --older-than <days>` removes sealed segments, with their indexes and rollups, whose
  last event is older, here and in every imported or unkept store. It never touches an active file.

`events list` and `summary` exit 0 even with damage, and 2 for a bad flag value. The build skill runs
`events ingest` as each worker completes and calls `build halt` and `resume`; the ship skill ingests its own
session and prints `events summary --build-run <id>`.

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

Every number carries its n, and a section with no events says "no events yet". `swiftgate stats` stays the
budget view over run history.
