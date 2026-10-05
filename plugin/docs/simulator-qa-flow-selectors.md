# Simulator QA flow selectors

The selector grammar the pinned `agent-device` reads in a flow step's `selector`, `absent` or
`target.selector`, so a flow names an element without reading the tool's source. How to write
`wait` and `is` steps is in [`simulator-qa-flow-steps.md`](simulator-qa-flow-steps.md), and
gestures in [`simulator-qa-flow-gestures.md`](simulator-qa-flow-gestures.md).

## Keys

A selector is 1 or more `key="value"` terms. These keys name what a flow checks:

| Key | Matches the element's | Example |
|---|---|---|
| `id` | accessibility identifier | `id="probe.count"` |
| `label` | accessibility label, or a control's title | `label="Step count"` |
| `value` | accessibility value | `id="probe.count" value="3"` |
| `role` | element type, without `XCUIElementType`, such as `button`, `statictext` or `searchfield` | `role=button label="Start"` |

A flow targets its own elements by `id`, from the contract's `AccessibilityID` values, since `qa
lint` checks only `id` against them. `label`, `value` and `role` narrow an `id`, or reach an
element that takes no identifier, such as `role=searchfield`. A key the tool doesn't know, such as
`identifier`, fails the step as `INVALID_ARGS` before it runs.

## Matching

- A value matches the whole attribute, ignoring case and runs of spaces: `label="step COUNT"`
  matches `Step count`, and `label="Step"` matches nothing.
- Terms separated by spaces must all hold on 1 element. `id="probe.count" value="4"` waits until
  that element's value is `4`, so a `wait` on it waits for the value to change.
- `||` separates alternatives, tried in order: `id="probe.missing" || id="probe.start"` takes the
  first that matches.

To wait for a state an app reaches on a clock, put the value under `value` beside the element's
`id`: the `wait` polls until both hold, with no sleep.

Each example ran in the captured batches under `plugin/gate/Tests/Fixtures/AgentDevice/selectors/`:
`pass` exited 0, and `label-part`, `terms-all` and `unknown-key` failed at the step their names
describe.
