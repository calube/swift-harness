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
- `surfaceCommit` is the plan's 1 surface commit, which every task builds on. Leave it out until it
  lands; keep it as the file had it.

A plan with no design doc names a spec page instead. `plan claim <slug> --session <id> --spec-page`
seeds it; `--spec-page` never goes with `--design` or `--tier`.

```json
{
  "schemaVersion": 1,
  "slug": "<slug>",
  "source": "specPage",
  "specPage": {"path": "spec-page.md", "pageSha": "<sha-256 of the page>"},
  "approval": {"pageSha": "<confirmed pageSha>", "by": "user", "at": "<ISO-8601 UTC>"},
  "surfaceCommit": "<sha>",
  "resume": "<one line>"
}
```

- The page is `<plans>/<slug>/spec-page.md`, and `path` is always `spec-page.md`. Only the plan's
  lock holder writes it.
- `pageSha` and `approval` are left out until the page is hashed and confirmed. `by` is `user`,
  `spec-quotes`, or `delegate` for a session that confirmed on the user's behalf under their
  delegation.
- A design plan has no `source` key (or `"source": "design"`). A spec-page plan carries none of
  `design`, `designSha`, `clarifyChain` and `tier`, and a design plan carries no `specPage`; either
  mix fails decoding.
- Commands that read a design (`plan-lint`, `design-diff --chain`, `design-render --ledger`,
  `plan set --tier`) refuse a spec-page plan and name it.

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

On a replan, `tasks` is the `<fixed>` tasks as the old ledger had them, in its order, then the
decomposer's new tasks. A `done` task keeps every field, `actualLines`, `model` and `branch`
included.

## `replan.json`

Path: `.harness/plan-draft/<slug>/replan.json`. The plan skill writes it on a replan, and the
decomposer reads it. It isn't plan state and isn't committed.

```json
{
  "schemaVersion": 1,
  "plannedSha": "<the designSha the ledger was planned at>",
  "designSha": "<current designSha>",
  "changedIds": ["req-offline-queue-drains-on-reconnect", "test-queued-orders-replay-in-submit-order"],
  "fixed": [{"id": "offline-queue-core-reducer", "status": "done", "…": "every ledger field"}],
  "replace": [{"id": "offline-queue-sync-feature", "status": "needs-replan", "…": "every ledger field"}],
  "fixIds": [{"id": "req-offline-queue-drains-on-reconnect", "doneTask": "offline-queue-core-reducer"}]
}
```

- `fixed` and `replace` hold whole ledger tasks, copied as they are.
- `fixIds` has one entry per changed id per `done` task whose `covers` names it.

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
