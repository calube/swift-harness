# Judge audit log

The gate writes every judge backend call, and every decision it makes from one, as a line in an append-only log, so you can check a run's judgement calls while it runs and afterwards.

## Where the judge runs

| Route | Runs from | Gates | Backends |
|---|---|---|---|
| `check-ready` | `check --tier ready` | blocks `ready` | claude; jev, escalating to claude |
| `judge-tests`, `judge-tests-ready` | `judge`, `judge --ready` | advisory; `--ready` blocks | claude; jev, escalating to claude |
| `comment-hook` | PreToolUse on `git commit` | advisory | claude, jev |
| `calibrate-design` | `calibrate design` | the calibration record | claude, jev |
| `self-test` | `self-test --judge --judge-backend` | the self-test | claude, jev |
| `judge-ask` | `judge ask` | never | claude, jev |
| `bench` | `judge bench` | never | claude, jev, cascade |

The gate logs a call made under no route too, with no `route`, and `judge events` counts it as unattributed.

## The log

- **Where:** `.harness/events/judge.jsonl` in the worktree, git-ignored. The gate also copies an event with a run id to `.harness/runs/<run id>/events/judge.jsonl`, beside that run's report.
- **Writes:** one `O_APPEND` write per line under a file lock, so concurrent sessions never tear or lose a line. A failed write never changes a verdict: a deciding route adds a `judge-events.unwritten` nit naming the path, and other routes say so on stderr.
- **Envelope:** `{schemaVersion, eventID, parentID?, kind, time, runID?, head?, base?, source: {route?, tier?, hook?}, payload}`. Other harness layers can reuse it under their own kind and stream.
- **`judge.call`:** one per backend call or cache hit. `role` is `answer`, `escalation` (parent: the Jev call) or `reason` (parent: the block's decision). It records backend, model, served model, question set and ids, subject (id, file, line, source SHA-256), answers, `cacheHit`, latency, tokens, cost, and the error kind and message.
- **`judge.decision`:** one per subject and question on `check-ready`, `judge-tests` and `comment-hook`. It records Jev's distribution and p, thresholds, band and `inBand`, `escalated` with Claude's distribution, the decision (`block`, `advisory`, `pass` or `error`), severity, `decidedBy`, `reasonSource` (`claude`, `template` or `none`), the reason and any reason error, and the calls it rests on.
- **Never logged:** a backend key or a request header. The gate redacts the environment's backend keys from every reason, rationale and error.

## Reading it

`swiftgate judge events [--since <run id|ISO time>] [--run <id>] [--route <route>] [--backend claude|jev] [--json]` prints decisions per question and backend, the escalation share, the blocks with their reasons, error counts, latency p50 and p95 per backend, and the summed cost.

It exits 0 when it prints, and 2 for an unreadable log, an unknown key, a newer `schemaVersion`, or a bad `--since` or `--run`. It reports a torn last line and leaves it out.
