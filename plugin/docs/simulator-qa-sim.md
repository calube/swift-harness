# Simulator QA sessions

This page covers the `swiftgate sim` commands a QA run uses: how `sim up` finds its device and
reuses its build, how `sim verify` judges a run's steps, and how `sim down` ends a run. Read it
when a `sim` command or a flow row's `sim verify` reports a finding.

Flow files and validation rows (`qa lint`, `qa run`, `qa adopt`) are in
[`simulator-qa.md`](simulator-qa.md), and how `qa run` drives a flow in
[`simulator-qa-flows.md`](simulator-qa-flows.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

| Command | What it does |
|---|---|
| `sim up [--scenario <name>] [--json]` | holds a simulator, builds and installs the app scheme, and opens it in a `[[scenarios]]` scenario; live dependencies without `--scenario` |
| `sim snap <label> [--assert <text>] [<runID>] [--json]` | captures a screenshot and accessibility tree as the run's next step |
| `sim verify [<runID>] [--json]` | judges the run's recorded steps: GREEN, RED or BLOCKED |
| `sim down [<runID>] [--json]` | closes the run's session, deletes its simulator and frees its slot |
| `sim hold --run <runID> [--owner-pid <pid>] [--timeout-minutes <n>]` | holds 1 slot and device for a run; `sim up` starts it, and you don't run it yourself |

## sim up

`sim up` and `sim hold` read the app's target from `.swiftgate.toml`. In a brownfield clone they
read it from the clone's 1 `xcode` area: the workspace or project, the scheme in its `test`
command, and the device its `-destination` names, on the newest iOS runtime that has it. A clone
with no `xcode` area, or several, reads BLOCKED.

`sim up` builds into 1 DerivedData folder per worktree, `derived-data/sim-up/` under the
worktree's state root. It stamps a good build with `HEAD` and the uncommitted changes outside
`.harness/`. A later `sim up` with the same stamp installs those products without building, and
says so in its `sim/build.log`.

## sim verify

```bash
swiftgate sim verify [<runID>] [--json]
```

`sim verify` judges the evidence `sim snap` recorded. It reads only the run's `sim/` folder and the
checkout's `HEAD`, and never touches the device.

- Without `<runID>` it takes this worktree's newest run whose holder is alive.
- It judges a named run from its folder even after `sim down`.
- A lease that names another worktree is `sim.not-owner`: RED (exit 1), and it writes nothing.

| Verdict | Exit | When |
|---|---|---|
| GREEN | 0 | no finding |
| RED | 1 | any finding |
| BLOCKED | 2 | `session.json` or `steps.ndjson` doesn't read, git can't name `HEAD`, or you named no run and none is live |

A RED finding outranks BLOCKED.

Each step's tree must also show its controls with an accessibility identifier
(`sim.a11y-identifier`) and a readable label (`sim.a11y-label`). Which controls the audit judges
depends on the repository and the flow: see [`simulator-qa-audit.md`](simulator-qa-audit.md).

### An app that exits

`sim snap` records each step's `appState` from `agent-device appstate`. When it finds the app
`notRunning`, it keeps the step with its screenshot and no tree, and exits 1 with
`sim.app-exited`.

`sim verify` reports that step as `sim.app-exited`, naming the run's next crash report in
`sim/crashes/`. It also reports any crash report no step claimed. It skips reports of another app,
another device or an earlier run. `sim down` copies the reports in, so run `sim verify` after it to
name them.

### The report

Each judged run writes `sim/report.json` with these keys:

| Key | Holds |
|---|---|
| `schemaVersion`, `command`, `runID`, `verdict` | the report's identity and verdict |
| `stepCount` | how many steps the run recorded |
| `headCommit` | the commit `sim up` built |
| `checkoutHead` | the checkout's `HEAD` when `sim verify` ran |
| `blocked` | why the verdict is BLOCKED |
| `findings` | each `{rule, step, path, message}`, with `path` relative to `sim/` |
| `notes` | each `{rule, message}`: nits that never change the verdict |

Unknown values are `null`. `sim verify` also appends a `sim verify` line, with the run id and
verdict, to the runs history.

## sim down

```bash
swiftgate sim down [<runID>] [--json]
```

`sim down` ends a QA run. Without `<runID>` it takes this worktree's newest lease, whether or not
its holder is alive. It takes these steps in order:

1. A lease from another worktree is `sim.not-owner`: RED (exit 1), and `sim down` touches nothing.
2. It runs `agent-device close` on the lease's session and device, then checks that
   `session list` no longer names the session. `SESSION_NOT_FOUND` or `DEVICE_NOT_FOUND` from
   `close` counts as closed. Then it deletes `sessions/<session>` under
   `agent-device session state-dir`, that exact folder only.
3. It removes the lease, so the `sim hold` process deletes the device and frees the `sim` slot.
   It waits up to 2 minutes for the holder to exit and the device to go. If the holder died
   holding the device, `sim down` deletes that 1 device, whose name carries the dead PID.
4. It runs `agent-device device release --stale --udid <udid>`, which clears claims whose owner is
   dead.
5. It copies into `sim/crashes/` each `.ips` crash report of the run's app on its device since
   `startedAt`, from the user's `DiagnosticReports` log folder. A report lands seconds after its
   crash. With fewer reports than recorded exits, it waits up to 30 s, then notes the shortfall.

| Rule | Verdict | When |
|---|---|---|
| `sim.not-owner` | RED (exit 1) | the lease belongs to another worktree |
| `sim.driver-failed` | BLOCKED (exit 2) | a close that fails, a session still listed, or a failed release; reported after the device goes back to the pool, with each problem appended to `sim/agent-device.log` |
| `swiftgate.environment` | BLOCKED (exit 2) | a lease `sim down` can't read or remove, or a holder or device still there after the wait |

With no lease left, `sim down` does nothing and exits 0, so a second call is harmless. The JSON is
`{schemaVersion, verdict, released, runID, udid, crashReports, notes}`. `notes` names an
unreadable lease, a session listing that failed, or a crash report it couldn't copy, and never
fails the call.

### Orphan sweep

`swiftgate gc`, and the orphan sweep each `sim hold` runs before it takes a device, first apply
`sim down`'s release to every lease whose holder died, in any worktree. A killed holder's session
and claim outlive it. Then they run `device release --stale --udid` on every orphaned device they
delete. They skip an `agent-device` that won't launch. Any other failure is a `gc` error.
