# Simulator QA flow gestures

The flow steps for gestures that a selector alone doesn't drive, each proven on a simulator with
the pinned `agent-device`. The rules a flow file meets are in
[`simulator-qa.md`](simulator-qa.md#qa-lint), and how `qa run` drives a flow in
[`simulator-qa-flows.md`](simulator-qa-flows.md). The captured runs are under
`gate/Tests/Fixtures/AgentDevice/pull-to-refresh/`.

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
- A `scroll` step is never a pull to refresh. `scroll up` starts its finger near the top edge,
  often inside the navigation bar, and moves in 400 ms. On the captured list it never refreshed at
  `amount: 0.8`, and at most 3 runs in 4 at other amounts.
- When no element sits that far below the top row, as on a list of 2 rows, the validation worker
  returns the lower element it needs as a missing contract name, such as an id on the list's
  footer.
