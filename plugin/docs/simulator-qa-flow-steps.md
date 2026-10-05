# Simulator QA flow steps: `wait` and `is`

How to write the steps a flow row checks with, so the pinned `agent-device` runs each as written.
How `qa run` drives a flow is in [`simulator-qa-flows.md`](simulator-qa-flows.md), and gestures in
[`simulator-qa-flow-gestures.md`](simulator-qa-flow-gestures.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## Each `wait` kind reads 1 key

The pinned tool drops a `wait` step's `kind` before it runs the step, then takes whichever target
key the input holds. So the target must sit under the key its `kind` names, and the step holds
only that 1 target key:

| `kind` | Target key | Example step | Waits until |
|---|---|---|---|
| `selector` | `selector` | `{"command": "wait", "input": {"kind": "selector", "selector": "id=\"probe.done\"", "timeoutMs": 5000}}` | the element is on screen |
| `absent` | `absent` | `{"command": "wait", "input": {"kind": "absent", "absent": "id=\"probe.loading\"", "timeoutMs": 15000}}` | the element is gone |
| `text` | `text` | `{"command": "wait", "input": {"kind": "text", "text": "Done", "timeoutMs": 5000}}` | the text is on screen |
| `duration` | `durationMs` | `{"command": "wait", "input": {"kind": "duration", "durationMs": 500}}` | the time has passed |
| `stable` | `stable` | `{"command": "wait", "input": {"kind": "stable", "stable": true, "quietMs": 500, "timeoutMs": 5000}}` | the screen stops changing |

A `ref` kind reads `ref`, but a flow never targets a ref. `quietMs` goes only with `stable`. A
`duration` or `stable` wait only pauses, so it never counts as the flow's check. These steps, run
in that order, are the captured batch that exited 0 in
`plugin/gate/Tests/Fixtures/AgentDevice/wait-kinds/kinds.steps.json`.

`{"kind": "absent", "selector": "id=\"probe.loading\""}` is a wait for the element to **appear**:
the tool runs the `selector` key and ignores `kind`. While the element shows, the step passes at
once. Once it's gone, the step times out with "wait timed out for selector".

## `is` and its `value`

An `is` step checks once, with no wait: `{"command": "is", "input": {"predicate": "absent",
"selector": "id=\"probe.loading\""}}`. It needs `selector`. `value` goes only with `predicate`
`text`, which compares the element's text with it. Any other predicate drops `value` unchecked.

## What `qa lint` refuses

`qa.flow-kind-key` refuses a `wait` whose target key isn't the 1 its `kind` reads, a `wait` with no
target key or with 2, `quietMs` beside another target, an `is text` with no `value`, and a `value`
on another predicate. The message spells out the corrected step, such as `{"absent":
"id=\"watchlist.loading\"", "kind": "absent", "timeoutMs": 15000}`. A flow repair keeps such a
`wait` by writing that same-kind step, never an `is`.
