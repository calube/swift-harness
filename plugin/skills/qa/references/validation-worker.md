# Validation worker brief

The brief for a plan's validation task: the decomposer's validation task in a design plan, or the
validation task beside a brownfield run's first wave. It runs beside the first wave with no deps,
writes each check its validation rows name before the code exists, and finishes before the tasks
those checks wait for.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Work only in your own worktree, from its toplevel.

Run every `"$SG"` call (`qa lint`, `qa run`) in the foreground with the Bash tool's `timeout` at
600000, never a shorter one, never with `run_in_background` or a shell `&`, and never inside
`timeout`, which kills a run with no report (`guard.qa-run-timeout`): `qa run --deadline <seconds>`
bounds the device wait and the rows instead. A call cut at the 120 s default goes on in
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
  A `wait` puts its target under the key its `kind` reads, which the tool runs whatever `kind`
  says: `{"kind": "absent", "absent": "id=\"<id>\""}` waits for an element to go, and the same
  target under `selector` waits for it to appear. Each kind's key is in
  `${CLAUDE_PLUGIN_ROOT}/docs/simulator-qa-flow-steps.md`; `qa lint` refuses a mismatch as
  `qa.flow-kind-key`.
  A screen a dependency client feeds never reaches the live service: the flow's first step is
  `{"command": "open", "input": {"app": "<bundle id>", "relaunch": true, "launchArgs":
  ["-harness-scenario", "<name>"]}}`, naming the contract's fake scenario its journey needs.
  A state shown only while a call runs, such as a loading, sending or saving label, ends before a
  `wait` polls under a scenario that answers in 300 ms. A flow that waits for such a state runs
  under the contract's scenario named with the word `held`, whose call holds it, and waits for
  the state's end with a `timeoutMs` of at least 15000. Check for that scenario before you write
  the flow; when the contract has none, leave that check out and return the scenario as a
  `missing:` line, so the orchestrator hears of it while the tasks are still building.
  `qa lint` warns `qa.flow-transient-state` on a flow that sees a state come and go under a
  scenario without the word.
  A pull to refresh is 1 step, `{"command": "gesture", "input": {"kind": "drag", "source":
  "id=\"<top row>\"", "destination": "id=\"<lower element>\""}}`, from the list's top row to an
  element at least 350 pt lower on screen, then a `wait` for what the refresh changes. That
  `wait` reads the fake's refreshed value, which every later load after the first answers, never
  a value that counts calls. A `scroll`
  step is never a pull to refresh: it leaves the row red on a gesture that didn't refresh. On a
  list too short for that, end the drag on the bottom-pinned id the contract adds for each
  refresh row, `"destination": "id=\"<bottom id>\""`; the contract pins it with
  `.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 1).accessibilityElement().accessibilityIdentifier(<bottom id>) }`.
  When the contract has none, return it as a missing contract name.
  A `.searchable` field takes no identifier, so its 1 step is `{"command": "fill", "input":
  {"target": {"kind": "selector", "selector": "role=searchfield"}, "text": "<query>"}}`, never a
  `fill` or `press` on the list's id. Check the result by the ids of the count and rows.
  An element a `wait` for a selector, an `is exists`, `is visible` or `is text` checks must be in
  view: `sim verify` reds the row as `sim.covered` when every match lies under a later search
  field, tab bar, toolbar or keyboard, as a list's last rows do under iOS 26's floating search
  field. `hittable=true` doesn't catch it. Scroll a row into view before checking it; a row the
  list can't scroll clear of the bar is the app's defect, not the flow's.
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
  "$SG" qa run --plan <plan> --at-base --prepared-by <your task id> --output .harness/tmp/qa-at-base.json
  ```

  Never pipe it through `head`, `tail` or a filter, never redirect `--json` with `2>&1`, and
  never send it to a file outside your worktree: read the whole JSON `--output` wrote. Its last member, `summary`, is 1 line naming the
  verdict, the run id and its `report.json`, which holds the same JSON. A finished run on the same
  commit is never run again: read its report there, or the `at-base-run.json` beside your checks.

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

## Repair mode

The orchestrator sends 1 flow row back to you when a fixer found it red twice and judged the flow,
not the app, at fault. Your brief names the fix worktree, the row's requirement and rows, the
fixer's `flow row:` line, both red run ids and their evidence paths. The worktree's
`.harness/qa/<plan>/` already holds that requirement's adopted checks and nothing else: 1 folder,
1 requirement.

- Read the evidence the brief names, `${CLAUDE_PLUGIN_ROOT}/docs/simulator-qa-flow-gestures.md` and
  `${CLAUDE_PLUGIN_ROOT}/docs/simulator-qa-flow-steps.md`.
  Decide whether the flow is at fault: a step the pinned tool can't drive as written, a selector
  for the wrong element, or a step the app can't satisfy as written.
- Change only the requirement's files in that folder, and add no other file. Keep every `wait` and
  `is` step, in order, with a `timeoutMs` no shorter: change, add or drop only the steps that drive
  the app. A `wait` whose target sits under another kind's key, which `qa lint` names as
  `qa.flow-kind-key`, stays a `wait` of the same kind with its target moved to the key the lint
  message names; an `is` never replaces a `wait`. `qa adopt --repair` refuses a repair that
  weakens what the row checks, or changes nothing.
- Lint it, then prove it red at the merge base on a `wait` or `is` step the row already had, or
  the step it failed at there before, in the foreground with the Bash `timeout` at 600000:

  ```bash
  "$SG" qa run --plan <plan> --at-base --prepared-by <writer> --requirement <requirement> --output .harness/tmp/qa-repair.json
  ```

  Run it yourself, every time, before you return: the adopt refuses a repair with no such run
  after its last edit. A red there on a step you added, or a flow file the tool refuses, isn't
  ready: fix it and run again. Commit nothing; `qa adopt --repair` checks all of this before it
  takes the files.
- A brief that quotes a refused adopt's findings is a second try: make the change each message
  says would pass, such as the step a `qa.repair-weakens-check` message quotes, then lint and
  prove it again.

Return 1 line:

```text
repaired: <requirement> <path>: red: <message> (qa run <run id>)
no repair: <requirement>: <why>
```

Return `no repair` when the flow already drives what the requirement needs and the app is at
fault, or when the fix needs a contract name the app doesn't have. A `held` scenario for a state
the fake ends before the `wait` sees it is such a name.
