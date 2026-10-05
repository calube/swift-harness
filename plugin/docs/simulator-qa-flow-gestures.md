# Simulator QA flow gestures

The flow steps for gestures that a selector alone doesn't drive, each proven on a simulator with
the pinned `agent-device`. The rules a flow file meets are in
[`simulator-qa.md`](simulator-qa.md#qa-lint), and how `qa run` drives a flow in
[`simulator-qa-flows.md`](simulator-qa-flows.md). The captured runs are under
`gate/Tests/Fixtures/AgentDevice/`: `pull-to-refresh/`, `searchable/` and `swipe/`.

## Pull to refresh

A SwiftUI `.refreshable` list or scroll view refreshes only when a finger drags its content down
from the top, far enough and slowly enough. The step drags from the list's top row to an element at
least 350 pt lower on screen, then the flow waits for what the refresh changes:

`{"command": "gesture", "input": {"kind": "drag", "source": "id=\"<top row>\"", "destination": "id=\"<lower element>\""}}`

- Both ends are `id=` selectors, so `qa.flow-ref-target` passes the step. A `gesture` `pan` needs
  an `origin` point, which that rule refuses.
- 350 pt is about 40% of an iPhone 17's screen. On the captured list, drags of 312 pt and 364 pt
  refreshed in every run, and drags of 266 pt or less never did. The drag holds on its source
  before it moves; from a `NavigationLink` row it opened nothing.
- The fake behind the list answers after a fixed 300 ms, so the drag ends before the load does.
  Its first load answers the seed and every later load the same refreshed value, never a value
  that counts calls: a drag held past the threshold can refresh twice, and the flow's `wait`
  still finds the refreshed value.
- A `scroll` step is never a pull to refresh. `scroll up` starts its finger near the top edge,
  often inside the navigation bar, and moves in 400 ms. On the captured list it never refreshed at
  `amount: 0.8`, and at most 3 runs in 4 at other amounts.

### A short list

A list of a few rows has no element 350 pt below its top row, and `agent-device` drags only between
2 targets: a drag by an offset from 1 id isn't a step it has. So the contract pins a 1 pt id to the
bottom of the refreshable screen's safe area, and the drag ends there:

`.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 1).accessibilityElement().accessibilityIdentifier(<bottom id>) }`

`{"command": "gesture", "input": {"kind": "drag", "source": "id=\"<top row>\"", "destination": "id=\"<bottom id>\""}}`

- The contract places the inset in the screen's stub, so no task has to: declared alone, the id
  ended up as the last `List` row in a trial, where it scrolls with the rows and the drag pulled
  nothing. `plan import` keeps such a contract pending as `plan-import.refresh-marker-unplaced`.
- The id goes on the list after any identifier the list itself carries: an identifier applied
  later to the whole view replaces it.
- On the captured 3-row list, under `gate/Tests/Fixtures/AgentDevice/pull-to-refresh-short/`, the
  drag from the top row to the pinned id moved 594 pt and refreshed, and the drag to the last row
  moved 104 pt and didn't. The pinned id sits above the home indicator on a list of any length, so
  a refresh flow can always end its drag there.

## A search field

A SwiftUI `.searchable` field takes no accessibility identifier. On iOS 26 it is a
`UISearchBarTextField` in the bottom toolbar, or in the navigation bar with a
`.navigationBarDrawer` placement, and an identifier written after `.searchable` lands on the list.
A `fill` on that id, or a `press` on it first, fails with "no text input found at the provided
coordinates to clear". So the flow selects the field by its role, whatever its prompt says:

`{"command": "fill", "input": {"target": {"kind": "selector", "selector": "role=searchfield"}, "text": "<query>"}}`

- `qa.flow-ref-target` passes a `role=` selector, and `qa.flow-unknown-id` checks only `id=`
  selectors, so the step needs no `AccessibilityID` case. A screen with 2 search fields picks 1 by
  `label="<prompt>"`, the field's label before and after typing.
- The flow checks what the search changes by ids: a count, a row that stays, a row that goes.
- A wait for a row to go puts the row under `absent`, as
  [`simulator-qa-flow-steps.md`](simulator-qa-flow-steps.md) says.

## A swipe

A swipe is a 100 ms fling across the middle of the screen, at half its height:

`{"command": "gesture", "input": {"kind": "swipe", "preset": "<preset>"}}`

- `right` moves from 15% to 85% of the width, and `left` back. `right-edge` starts at the left
  edge and moves right; `left-edge` starts at the right edge and moves left.
- The step takes no element and no other key: `qa lint` refuses a swipe with no `preset` as
  `qa.flow-kind-key`, and an unknown preset as `qa.flow-schema`.
- The recognizer must cover that mid-height line: on the captured probe, a recognizer on a
  120 pt band at the top never saw the swipe. The contract puts a swipe-driven screen's
  recognizer on its whole area.
