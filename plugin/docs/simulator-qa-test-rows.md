# Simulator QA: test rows

How `swiftgate qa run` runs an acceptance row whose check names a test, and how it and a
brownfield gate keep an `xcodebuild test` off the simulator every session shares. The rest of
`qa run` is in [`simulator-qa.md`](simulator-qa.md).

## The test form

An acceptance check `test: <id>` (or `test <area>: <id>`) runs the area's test command narrowed to
that test: `-only-testing:<id>` for an `xcode` area, writing `qa/<NN>-<req>.acceptance.xcresult`,
`test_files` with `{tests}` or `{files}` otherwise.

## 1 run per check

Acceptance rows naming the same check run it once per `qa run`, for the first of them. Each later
row takes that run's result and evidence, its message leads with `row <N> ran this same check`,
and it took 0 ms.

## A leased clone

An `xcodebuild test` whose `-destination` names a simulator (`platform=iOS Simulator,name=<device>`)
runs with `-destination 'id=<clone>'` instead, on a clone of that device: its `OS=`, or else the
newest iOS runtime that has it. Clones come from the machine-wide `sim` slots that every simulator
run shares. `qa run` holds 1 clone across its acceptance rows and gives it back before the first
flow row brings its own device up. A brownfield gate's area commands lease 1 clone per command.
With no clone to be had, the command runs as written; a row's message says why.

## A runner that never launched

When `xcodebuild` exits non-zero saying "Failed to install or launch the test runner" or
"Simulator device failed to launch", such as on a busy device, no test ran. The command runs once
more. A row that fails the same way again reads `unverified`, naming the launch failure, at the
merge base too: it is the machine's failure, never a `red` row. A failing test in its result bundle
or report keeps the row `red`. A gate step that fails the same way twice stays failed, its tail
headed by the launch failure.
