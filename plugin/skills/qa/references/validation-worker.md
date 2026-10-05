# Validation worker brief

The brief for a plan's validation task: the decomposer's validation task in a design plan, or the
validation task beside a brownfield run's first wave. It runs beside the first wave with no deps,
writes each check its validation rows name before the code exists, and finishes before the tasks
those checks wait for.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Work only in your own worktree, from its toplevel.

Run every `"$SG"` call (`qa lint`, `qa run`) in the foreground with the Bash tool's `timeout` at
600000, never with `run_in_background` or a shell `&`. A call cut at the 120 s default goes on in
the background while you wait on it, and every merge your rows name waits on you. If 1 does,
`qa run` printed `run <id> started; its report will be written to <path>` first: wait for that
file, in Bash or Monitor, never for a process by name, which the hook denies. Never search
outside your worktree: every file you need is in it, in the brief, or at a path `qa run` prints.
List a folder by naming it, as `ls .harness/qa/<plan>`, never a bare `ls`: the tool's stdin never
closes, and a shell alias such as `eza` given no path reads paths from stdin and waits.

## What you get

- The plan's slug, written `<plan>` below, and your task id.
- The validation rows whose `writer` is your task: each row's `requirement`, `layer`, `check` and
  `runsAfter`.
- The contract: the surface or contract commit's types and signatures, and the names a check may
  target: accessibility identifiers and labels, routes with their request and response shapes,
  storage keys and tables, and log lines with their subsystem.

## Write set

- The acceptance test files your task's write set names, in the repository, committed on your
  branch. Each one merges later as a ledger dep of the tasks it waits for.
- `.harness/qa/<plan>/`: every flow steps file and state script, each named as its row's `check`
  names it under the plan's qa folder. No commit carries this folder.

Write nothing else: no app code, no contract file, no plan state, no config. A missing contract
name goes in your report: when a check needs a name the contract doesn't fix, leave that check out
and return the name. You never add it yourself; the orchestrator amends the contract.

## Writing the checks

Write each check against the contract's names only, so it compiles or parses before the code
exists and fails for the reason the feature is missing.

- **Acceptance**: a test in the module's test target that drives the boundary the row names, in the
  repository's test framework, or the row's `curl -fsS … | jq -e '<condition>'` command. A test's
  row names it as `test: <id>`, never by its file: in an `xcode` area the id is
  `<Target>/<Class>/<method>`, which `qa run` passes to the area's test command as `-only-testing:`.
- **Flow**: a JSON array of `{"command": "<name>", "input": {...}}` steps for an `agent-device` batch.
  Target elements by `id="…"` selectors whose ids are raw values of the app's `AccessibilityID`
  module, the file `[qa] accessibility_ids` names, never by an `@e` ref or a point. Every flow
  checks at least 1 thing with a `wait` or `is` step; a `get` reads a value and never counts.
  A screen a dependency client feeds never reaches the live service: the flow's first step is
  `{"command": "open", "input": {"app": "<bundle id>", "relaunch": true, "launchArgs":
  ["-harness-scenario", "<name>"]}}`, naming the contract's fake scenario its journey needs.
- **State**: a shell script that exits non-zero when the stored or sent result is wrong. It reads
  1 of: a database query, a read after the write, the app's stored data, or a log line. It gets
  `QA_PORT` (a server's port), `QA_DIR` (the plan's `qa/` folder), `QA_EVIDENCE_DIR`, and, after its
  flow, `QA_SIM_UDID`, `QA_SIM_SESSION`, `QA_SIM_BUNDLE_ID` and `QA_SIM_DIR`.

Lint every flow file until it is GREEN:

```bash
"$SG" qa lint .harness/qa/<plan>/*.flow.json
```

## Record why each check fails now

Prove each check red against today's code and record its failure reason: a stub's return, a 404, a
missing element, a failing step. A check that fails on an import error, a typo, a missing file or a
lint finding isn't ready: fix it and run it again before you return.

- **Acceptance test** in the repository: run the test and record the assertion it fails on.
- **Every check under `.harness/qa/<plan>/`** (flow, state, acceptance script): 1 run from your
  worktree's toplevel proves them all, in the foreground with the Bash `timeout` at 600000:

  ```bash
  "$SG" qa run --plan <plan> --at-base --prepared-by <your task id> --json
  ```

  It runs only the rows you write, from your prepared folder, at the merge base in a scratch tree:
  each flow is linted, run as 1 batch on a device `sim up` leases, snapped at each step and judged
  by `sim verify`, and each state row runs on its flow's device. Record each row's `result` and
  `message`, and the run id. Run it last, after your final edit, and leave the
  `at-base-run.json` it writes at the absolute path its JSON names as `atBaseRecord`; read it
  there, never search for it. Once `qa adopt` copies your folder, the orchestrator's
  `qa run --at-base` takes each row whose check is still byte-identical from it instead of
  running the row again. A row that reads `pass` can't tell the change from its absence: fix
  the check. A row that reads `unverified` has no red run: fix what its message names and run
  again.

Never prove a red by hand: no raw agent-device batch of a prepared flow (the hook denies it, as
`guard.validation-flow-by-hand`), and no `sim up`, `sim snap` or `sim verify` of your own. `qa run`
leases and releases the device itself.

Your recorded reason is a note. The gate confirms the red run: once you return, the orchestrator
copies your folder into plan state with `qa adopt` and runs `qa run --at-base`, and an acceptance
test goes through `prove` with its `--proof-base` before the tasks it waits for.

## Return

1 line per check, then 1 line per missing contract name:

```text
<requirement> <layer> <path>: <result>: <message> (qa run <run id>)
<requirement> <layer> <path>: not run: <why>
missing: <name> (<requirement>): <why the check needs it>
```

A check you couldn't run, such as a flow `qa run` left `unverified` because its device didn't
come up, returns `not run` with the reason, never a guessed failure.
