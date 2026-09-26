# Plan state files

The shapes `/swift-harness:plan` writes. `swiftgate` decodes each one into a closed type, so an
unknown key or value fails `plan-lint` or `plan-schedule` and names itself.

## `plan.json`

Path: `<plans>/<slug>/plan.json`. `plan claim` seeds it; the plan skill rewrites it whole.

```json
{
  "schemaVersion": 1,
  "slug": "<slug>",
  "design": "docs/<area>/designs/<name>.md",
  "designSha": "<current designSha>",
  "approval": {"decision": "approve", "designSha": "<approved designSha>", "at": "<ISO-8601 UTC>"},
  "clarifyChain": [{"fromSha": "…", "toSha": "…", "at": "<ISO-8601 UTC>"}],
  "tier": "standard",
  "resume": "<one line>"
}
```

- Keep `slug`, `design`, `clarifyChain` and `tier` as the file had them.
- `designSha` is the current designSha from `design-diff`. It equals `approval.designSha`, or the
  clarify chain's `endSha`.
- `approval.at` is the time on the approval record, not the time of this run.

## `ledger.json`

Path: `<plans>/<slug>/ledger.json`, and the draft at `.harness/plan-draft/<slug>/ledger.json`.

```json
{
  "schemaVersion": 1,
  "resume": "<one line>",
  "maxParallel": 3,
  "tasks": [
    {
      "id": "offline-queue-core-reducer",
      "deps": [],
      "writeSet": ["Packages/OrderQueue/Sources/OrderQueueCore/"],
      "gate": "push",
      "tests": ["test-queued-orders-replay-in-submit-order"],
      "covers": ["req-offline-queue-drains-on-reconnect", "test-queued-orders-replay-in-submit-order"],
      "estLines": 180,
      "status": "pending",
      "worktree": "../myapp-offline-order-queue-offline-queue-core-reducer"
    }
  ],
  "waves": [["offline-queue-core-reducer"]]
}
```

- `tasks` holds the decomposer's reply as it came. Don't add, drop or change a task.
- `waves` is the `waves` array from `plan-schedule --json`, copied as it is. `plan-lint` recomputes
  it and flags any difference.
- `gate` is `fast`, `push` or `ready`. `status` is `pending` for every new task. There is no
  `actualLines` until a worker reports one.

## `phases.jsonl`

Path: `.harness/runs/design-<name>/phases.jsonl` in this checkout, where `<name>` is the design
doc's file name without `.md`. The design skill writes to the same file, and
`swiftgate stats --design <doc>` reads it. Append a line per record and never rewrite a line:

```json
{"schemaVersion": 1, "runId": "plan-20260925T180000Z", "phase": "decompose", "agentRole": "decomposer", "lane": null, "tokens": 48210, "costUSD": null, "wallMilliseconds": 94000}
```

| Step | `phase` | `agentRole` | `tokens` | `wallMilliseconds` |
|---|---|---|---|---|
| decomposer call or fix round | `decompose` | `decomposer` | as the Agent or SendMessage result reports | as the result reports |
| `plan-schedule` | `schedule` | `null` | `0` | measured around the call |
| `plan-lint` | `lint` | `null` | `0` | measured around the call |
| `index set` | `index` | `null` | `0` | measured around the call |

- `lane` is `null` on every plan line; it names a research lane only.
- `costUSD` is `null` unless the result reports a cost. Never write `0` for a cost you don't know.
- To measure a call, take `perl -MTime::HiRes=time -e 'printf "%d", time*1000'` before and after
  it, and subtract.
