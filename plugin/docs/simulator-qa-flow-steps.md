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

## A checked element must be in view

A `wait` for a selector, and an `is exists`, `is visible` or `is text`, match an element anywhere
in the accessibility tree, including one the user can't see. iOS 26 draws a `.searchable` field
as a floating bar over the bottom of the list, and the rows under it still match. Neither `is
visible` nor `hittable=true` in the selector catches it: the pin's `hittable` only asks whether
the element's centre is on screen, and it reads `true` before the bar joins the tree. The captured
runs are in `plugin/gate/Tests/Fixtures/AgentDevice/under-search-bar/`.

So `qa run` records each such step's selector as the `target` of its `sim/` step, and `sim
verify` reds the row as `sim.covered` when, in the tree kept after the step, the centre of every
element it matches lies inside a search field, tab bar, toolbar or keyboard listed after it. The
fix is the app's: give the content room above the bar, such as a bottom `.contentMargins` or
`.safeAreaPadding`. Or, when the list scrolls, the flow scrolls the element into view before the
check. An absence check (`wait` `absent`, `is absent`, `is hidden`) names no target.

## A state that ends on its own

A `wait` polls the screen, so a state the app shows for 300 ms, such as a sending label while a
fake's call runs, can come and go between polls. `qa lint` warns `qa.flow-transient-state`, and
never gates, when a flow sees a selector appear and then go with only `wait`, `is`, `get`,
`snapshot` or `screenshot` steps between, under a `-harness-scenario` whose name lacks the word
`held`. Run such a flow under the contract's `held` scenario, whose call holds the state.
A screen whose state advances on a clock runs the same race however fast the app settles. After
each `wait` or `is` step, `qa run` captures a snapshot, a screenshot and a snapshot: about 1.2 s,
and over 10 s on a loaded machine. So a check of its starting state runs under the contract's
`held` scenario, whose clock starts at the first input.

## A state that changes on a clock

After each `wait` or `is`, `qa run`'s captures take about 1 s before the next step, and far longer
on a loaded machine: 1 screenshot has taken 11 s. A flow that reads a value the app changes on a
timer races them. Launch it under a scenario that holds the clock until the first input. A red
row's message says where the time before its failing step went.

## What `qa lint` refuses

`qa.flow-kind-key` refuses a `wait` whose target key isn't the 1 its `kind` reads, a `wait` with no
target key or with 2, `quietMs` beside another target, an `is text` with no `value`, and a `value`
on another predicate. The message spells out the corrected step, such as `{"absent":
"id=\"watchlist.loading\"", "kind": "absent", "timeoutMs": 15000}`. A flow repair keeps such a
`wait` by writing that same-kind step, never an `is`.
