# Validation worker brief

The brief for a plan's validation task: the decomposer's validation task in a design plan, or the
validation task beside a brownfield run's first wave. It runs beside the first wave with no deps,
writes each check its validation rows name before the code exists, and finishes before the tasks
those checks wait for.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Work only in your own worktree, from its toplevel.

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
  repository's test framework, or the row's `curl -fsS … | jq -e '<condition>'` command.
- **Flow**: a JSON array of `{"command": "<name>", "input": {...}}` steps for an `agent-device` batch.
  Target elements by `id="…"` selectors whose ids are raw values of the app's `AccessibilityID`
  module, the file `[qa] accessibility_ids` names, never by an `@e` ref or a point. Every flow
  checks at least 1 thing with a `wait` or `is` step; a `get` reads a value and never counts.
- **State**: a shell script that exits non-zero when the stored or sent result is wrong. It reads
  1 of: a database query, a read after the write, the app's stored data, or a log line. It gets
  `QA_PORT` (a server's port), `QA_DIR` (the plan's `qa/` folder), `QA_EVIDENCE_DIR`, and, after its
  flow, `QA_SIM_UDID`, `QA_SIM_SESSION`, `QA_SIM_BUNDLE_ID` and `QA_SIM_DIR`.

Lint every flow file until it is GREEN:

```bash
"$SG" qa lint .harness/qa/<plan>/*.flow.json
```

## Record why each check fails now

Run each check once against today's code and record its failure reason: a stub's return, a 404, a
missing element, a failing step. A check that fails on an import error, a typo, a missing file or a
lint finding isn't ready: fix it and run it again before you return.

- **Acceptance**: run the test, or the command, and record the assertion it fails on.
- **Flow**: build and install the base app only through `swiftgate sim up`, never on a device you
  pick yourself, then run the steps file as 1 batch and release the device on every path:

  ```bash
  "$SG" sim up --scenario <scenario> --json
  agent-device batch --steps-file .harness/qa/<plan>/<name>.flow.json --udid <udid> --session <session> --on-error stop --json
  "$SG" sim down <runID> --json
  ```

  Record the failing step's number and message from the batch output.
- **State**: run the script after its flow's batch, before `sim down`, with `QA_DIR` set to
  `.harness/qa/<plan>/` and `QA_SIM_UDID` and `QA_SIM_SESSION` from `sim up`'s JSON, and record
  its exit status and output.

Your recorded reason is a note. The gate confirms the red run: once you return, the orchestrator
copies your folder into plan state with `qa adopt` and runs `qa run --at-base`, and an acceptance
test goes through `prove` with its `--proof-base` before the tasks it waits for.

## Return

1 line per check, then 1 line per missing contract name:

```text
<requirement> <layer> <path>: <failure reason>
<requirement> <layer> <path>: not run: <why>
missing: <name> (<requirement>): <why the check needs it>
```

A check you couldn't run, such as a flow whose `sim up` failed, returns `not run` with the
reason, never a guessed failure.
