# Batch steps files for `qa lint`

These files are inputs, not tool output: a validation worker writes a flow as an
`agent-device batch` steps file, and `qa lint` checks it offline against the step schemas the
pinned tool reports (`plugin/qa/agent-device-schemas-<pin>.json`, captured by
`../AgentDevice/capture.sh`) and against SampleApp's `AccessibilityID` enum.

Two of them are the exact steps `../AgentDevice/capture.sh` ran on a device, so the tool's own
verdict on them is captured:

| File | Same steps as | The pinned tool's verdict |
|---|---|---|
| `counter.flow.json` | `pass.json` in `capture.sh` | `../AgentDevice/batch-pass.*`: exit 0, every step `ok` |
| `target-object.flow.json` | `invalid.json` in `capture.sh` | `../AgentDevice/batch-invalid.*`: exit 1, `INVALID_ARGS`, "Batch step 1 wait input is invalid: Expected target to be one of: mobile, tv, desktop." |

The rest each change 1 thing in `counter.flow.json` to break 1 rule:

| File | Breaks |
|---|---|
| `typo-id.flow.json` | `qa.flow-unknown-id`: `counter.incremnet` |
| `misspelt-key.flow.json` | `qa.flow-schema`: `wait` input key `selecter` |
| `get-only.flow.json` | `qa.flow-no-assert`: `get` reads a value and asserts nothing |
| `wait-duration-only.flow.json` | `qa.flow-no-assert`: a `duration` wait is a pause, not a check |
| `ref-target.flow.json` | `qa.flow-ref-target`: `press` targets `@e3` |
| `point-target.flow.json` | `qa.flow-ref-target`: `press` targets a point |
| `not-a-list.flow.json` | `qa.flow-unparsed`: 1 step object, not a list of steps |
