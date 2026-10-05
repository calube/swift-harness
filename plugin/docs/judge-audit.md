# Judge audit log

The gate writes every judge backend call, and every decision it makes from one, as a line in an
append-only log. Read this page to check a run's judgement calls while it runs or afterwards, or
to find out why the judge blocked a change.

## Reading it

```sh
swiftgate judge events [--since <run id|ISO time>] [--run <id>] [--route <route>] [--backend claude|jev] [--json]
```

It reads the worktree's log and the copies imported from removed worktrees, and prints:

- decisions per question and backend, and the escalation share;
- the escalations by cause: `uncertain` (Jev's answer fell in the band) or `jevFailed` (Jev gave no
  answer);
- each block, with the backend and model that decided it, the model that served the deciding
  answer, its escalation cause when it escalated, and its reason;
- the decisions counted by the backend and served model of their deciding answer;
- error counts, latency p50 and p95 per backend, and the summed cost.

`--json` carries the same: `escalationCauses` on the summary and on each question row,
`servedModel` and `escalationCause` on each block, and `servedModels` (`backend`, `servedModel`,
`decisions`). An escalation logged with no cause counts as `uncertain`.

`--run <id>` reads that run's own copy, `.harness/runs/<id>/events/judge.jsonl`. `--route` takes
any route below, plus `check`, `hook` and `ingest`.

Exit codes: 0 when it prints; 2 for an unreadable log, an unknown key, a newer `schemaVersion`, or
a bad `--since` or `--run`. It reports a torn last line on stderr and leaves it out.

## Where the judge runs

| Route | Runs from | Gates | Backends |
|---|---|---|---|
| `check-ready` | `check --tier ready` | blocks `ready` | claude; jev, escalating to claude |
| `judge-tests`, `judge-tests-ready` | `judge tests`, `judge tests --ready` (`tests` is the default subcommand) | advisory; `--ready` blocks | claude; jev, escalating to claude |
| `comment-hook` | PreToolUse on `git commit` | advisory | claude, jev |
| `calibrate-design` | `calibrate design` | the calibration record | claude, jev |
| `self-test` | `self-test --judge --judge-backend <backend>` | the self-test | claude, jev |
| `judge-ask` | `judge ask` | never | claude, jev |
| `bench` | `judge bench` | never | claude, jev, cascade |

The gate logs a call made under no route too, with no `route`, and `judge events` counts it as
unattributed.

## The log

### Where and how it writes

- **Where:** `.harness/events/judge.jsonl` in the worktree, git-ignored. The gate also copies an
  event with a run id to `.harness/runs/<run id>/events/judge.jsonl`, beside that run's report.
- **How:** 1 `O_APPEND` write per line under a file lock, so concurrent sessions never tear or lose
  a line.
- **On failure:** a failed write never changes a verdict. A deciding route adds a
  `judge-events.unwritten` nit naming the path, and other routes say so on stderr.
- **Envelope:** `{schemaVersion, eventID, parentID?, kind, time, runID?, head?, base?, source:
  {route?, tier?, hook?, binary?: {sourceHash, pluginVersion?}}, payload}`. Other harness layers
  reuse it under their own kind and stream; see [`telemetry.md`](telemetry.md).
- **Never logged:** a backend key or a request header. The gate redacts the environment's backend
  keys from every reason, rationale and error.

### `judge.call`

1 per backend call or cache hit. `role` is 1 of:

- `answer`;
- `escalation`, whose parent is the Jev call;
- `reason`, whose parent is the block's decision.

It records the backend, model, served model, question set and ids, the subject (id, file, line,
source SHA-256), the answers, `cacheHit`, latency, tokens, cost, and the error kind and message.

At `ready`, after a Jev transport error (`transport`) or parse error (`malformedReply`), the gate
waits 750 ms and asks Jev again once. So a subject can have 2 Jev `answer` calls, and an
escalation's parent is the last.

### `judge.decision`

1 per subject and question on `check-ready`, `judge-tests`, `judge-tests-ready` and
`comment-hook`. It records:

- Jev's distribution and p, the thresholds, the band and `inBand`;
- `escalated`, with Claude's distribution and the escalation's `cause`: `uncertain`, or
  `jevFailed` with Jev's error as `jevError`;
- the decision (`block`, `advisory`, `pass` or `error`), severity and `decidedBy`;
- `reasonSource` (`claude`, `template` or `none`), the reason and any reason error;
- the calls it rests on.

### When Jev gives no answer at `ready`

Its blocking questions escalate with `cause: jevFailed`, and Claude decides them. Its advisory
questions become `error` decisions carrying Jev's error. When Claude fails too, the blocking
decisions are `error` as well, and the gate reports `judge.blocked`.
