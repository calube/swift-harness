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
run shares. `qa run` holds 1 clone across its acceptance rows and gives it back before its flow
rows start. With no clone to be had, the command runs as written; a row's message says why.

A brownfield gate leases each area's test clone as the area starts, so the clone boots while the
area builds, and gives it back once the area is done. While no `qa run` borrows the build run's device, a
brownfield gate's test step runs on that device instead, and takes no `sim` slot.

## 1 device for the flow rows

A `qa run`'s flow rows share 1 device, held by a `sim hold --owner-pid` that ends after the last
row or once the run exits. Each row borrows it under a lease of its own. Its `sim up` uninstalls
the app and resets the keychain before installing, so no row starts on another's data, and builds
the app while the device comes up. A row's state rows run before the next row's reset.

In a brownfield build run, every `qa run` borrows the build run's own device instead, so only the
first flow row of the run waits for a clone to boot. Its holder has no owner process and lasts to
the time box's end; `build finish` and `run checkout remove` release it. 1 `qa run` borrows it at a
time; another holds its own as above. A brownfield `qa run`'s trial merge or merge-base tree is a
pooled worktree slot, the same slots task worktrees use, so the app `sim up` builds there stays
warm for the next run in that slot.

## A runner that never launched

When `xcodebuild` exits non-zero saying "Failed to install or launch the test runner" or
"Simulator device failed to launch", such as on a busy device, no test ran. The command runs once
more. A row that fails the same way again reads `unverified`, naming the launch failure, at the
merge base too: it is the machine's failure, never a `red` row. A failing test in its result bundle
or report keeps the row `red`. A gate step that fails the same way twice stays failed, its tail
headed by the launch failure.
