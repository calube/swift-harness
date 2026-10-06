# Replace the posts screen with a testable screen whose state advances on a clock

## Requirements

- req-launch: Launching the app starts a session with a count of 0 and 3 chances
- req-motion: Objects launch from below the screen in upward arcs under acceleration, mostly target and sometimes a hazard
- req-seed: The same seed produces the same launches
- req-cut-test: The cut test of a swipe segment against an object has unit tests, including a swipe that only grazes the object's edge
- req-cut-target: A swipe through a target cuts it and adds 1 point; a swipe that misses cuts nothing
- req-hazard: A swipe through a hazard ends the session
- req-miss: Each target that falls off the screen uncut costs 1 chance, and the session ends at 0 chances
- req-fixed-step: The simulation advances in fixed time steps, independent of the frame rate
- req-screen: The session screen draws the moving objects, a trail following the swipe, the count and the remaining chances
- req-ended: At session end the screen shows "Ended" with the final count and a "Start again" button that starts a new session
- req-existing-tests: The existing tests keep passing

## Areas

- AppFeature (warm test 9 s)
- TimedBuildStarter (xcode, warm test 71 s, build-only)

## Assumptions

- The repository is small, so the orchestrator read it directly and launched no explorers.
- The simulation sits in a new pure-Swift `EngineCore` target inside the AppFeature package, so it is testable without UIKit, TCA or a screen; the app project and its package links stay unchanged.
- The world uses screen-style coordinates in a fixed 390 x 844 field, y growing downward, acceleration positive; the view scales the field to its size.
- "Keep the existing tests passing" keeps `AppFeatureTests` as they are, so `AppFeature` keeps its posts actions; the view no longer sends them. `LaunchFlowUITests` checks the replaced screen, so the screen-ui task rewrites it for the session's launch state.
- A target "falls back off the screen" when it moves downward with its top edge below the field's bottom; objects spawn below the field moving upward, so a fresh launch never counts as a miss. `EngineConfig.hasFallenOff` pins that rule in the contract.
- A cut hazard ends the session at once, whatever the chances left; cut objects leave the field and count nothing more.
- Swipe segments test against an object's circle inclusively: a segment whose distance to the centre equals the radius (a graze) cuts.
- The fixed step is 1/120 s; `advance(by:)` accumulates frame time and runs whole steps, carrying the remainder, and caps 1 call at 0.25 s of steps.
- The random source is a SplitMix64 generator seeded with a `UInt64`; about 1 launch in 6 is a hazard.
- The `-harness-scenario` seam gives the clock-driven screen its held and seeded scenarios: `launch-held`, `target-center` and `hazard-center`; with no argument the app runs a live session with a time-based seed.
- Flow row req-miss (`qa/miss.flow.json`) read `Chances: 2` too late under `launch-held`, since the next target fell within 0.5 s; `build no-repair` answered amend-contract, so the fix branch adds the `target-fall-held` scenario (1 target high on the left, launches held 5 s) and the row is repaired against it.
- The engine-sim before-merge run was RED on req-miss and req-ended; the flows-red halt was answered retry by rule, and the fixer found no app defect.
- The req-miss repair, a flow run under `target-fall-held` and proved red at the base, was refused by `qa adopt --repair` (`qa.repair-red-runs`: the red run's report "holds no row of req-miss"), so the row keeps its `launch-held` flow; it passed on the fix branch's run.
- req-ended's flow stayed red: Start again starts a live session whose clock drains `Chances: 3` before the flow reads it, and the repair worker answered `no repair` (contract gap: a held Start again session). `build no-repair` answered merge-unverified, so the gate-red halt was resumed with merge and engine-sim merged with that row unverified.

### spec-contract
Declare the engine, feature, scenario and screen names every task builds against, with stub behaviour.
- Deps: none · Gate: slice · estLines: 330
- Why: every requirement crosses the engine, the reducer and the screen, so all tasks compile against 1 declared shape.
- Scope:
  - `EngineCore` target in the AppFeature package: `Vec2`, `ObjectKind`, `FlyingObject`, `EngineConfig` (field size, acceleration, fixed step, start chances, spawn and removal rule `hasFallenOff`), `SeededGenerator`, `LaunchSchedule` (stub), `CutTest.segment(_:_:hits:)` (stub), `Simulation` (count 0, chances 3, stubbed `step`, `advance(by:)`, `swipe(_:)`, `start()`)
  - `TargetFeature` reducer stub in AppCore with `TargetScenario` (`live`, `launch-held`, `target-center`, `hazard-center`) read from the `-harness-scenario` launch argument; the `launch-held` scenario starts the clock only at the end of the first swipe; `AppFeature` scopes a `session` child
  - `TargetView` stub in AppUI holding every accessibility id the flows drive; the composition root reads `-harness-scenario`
- Acceptance:
  - `EngineConfigTests` checks the spawn and removal boundary; every touched area builds; slice is GREEN
- Out of scope:
  - launch, cut, counting and drawing behaviour
- Covers: req-launch
- Writes: .swiftgate.toml, Packages/AppFeature/Package.swift, Packages/AppFeature/Sources/EngineCore/, Packages/AppFeature/Sources/AppCore/, Packages/AppFeature/Sources/AppUI/TargetView.swift, Packages/AppFeature/Tests/EngineCoreTests/EngineConfigTests.swift, App/TimedBuildStarterApp.swift
- Does: names fixed here: ids `session.field` (whole-screen gesture area), `session.count` (label `Count: <n>`), `session.chances` (label `Chances: <n>`), `session.clock` (accessibility value = step count), `session.object.<id>` (1 element per object at its frame), `session.edge` (1 pt element at the right edge, vertically centred), `session.ended` (label `Ended`), `session.finalCount` (label `Final count: <n>`), `session.startAgain` (button `Start again`).

### engine-cut
Implement the swipe-segment-against-circle cut test.
- Deps: spec-contract · Gate: slice · estLines: 90
- Why: spec "Any object that a segment of the swipe passes through is cut" and the acceptance "the cut test has unit tests, including a swipe that only grazes the object's edge".
- Scope:
  - `CutTest.segment(_:_:hits:)` in `Sources/EngineCore/CutTest.swift`: closest-point distance from the circle centre to the segment, inclusive of the radius; a zero-length segment tests its point
- Acceptance:
  - `CutTestTests` fail first, then pass: through the centre, a clean miss, a graze exactly at the radius, a near miss just outside it, a segment ending before the circle, a zero-length segment; slice is GREEN
- Out of scope:
  - swipes of many points and counting
- Covers: req-cut-test
- Writes: Packages/AppFeature/Sources/EngineCore/CutTest.swift, Packages/AppFeature/Tests/EngineCoreTests/CutTestTests.swift
- Tests: Packages/AppFeature/Tests/EngineCoreTests/CutTestTests.swift

### engine-spawn
Implement seeded launches from below the field in upward arcs, mostly target and sometimes a hazard.
- Deps: spec-contract · Gate: slice · estLines: 120
- Why: spec "Objects launch from below the screen in upward arcs under acceleration: mostly target, sometimes a hazard. The launches come from a seeded random source".
- Scope:
  - `LaunchSchedule` in `Sources/EngineCore/LaunchSchedule.swift`: seeded by `SeededGenerator`, `nextLaunch()` returns a `FlyingObject` at `EngineConfig.spawnY` with an upward velocity whose apex under acceleration lies inside the field and an x that keeps the arc in the field; about 1 in 6 is a hazard; `nextLaunchDelay()` returns the steps until the next launch
- Acceptance:
  - `LaunchScheduleTests` fail first, then pass: 2 schedules with 1 seed give equal sequences of 50 launches, 2 seeds differ, every launch starts below the field moving up with its apex inside it, a run of 600 has more target than hazards and at least 1 hazard; slice is GREEN
- Out of scope:
  - stepping objects and counting
- Covers: req-motion, req-seed
- Writes: Packages/AppFeature/Sources/EngineCore/LaunchSchedule.swift, Packages/AppFeature/Tests/EngineCoreTests/LaunchScheduleTests.swift
- Tests: Packages/AppFeature/Tests/EngineCoreTests/LaunchScheduleTests.swift

### engine-sim
Implement the fixed-step simulation: motion under acceleration, swipe cutting, counting, chances and session end.
- Deps: engine-cut, engine-spawn · Gate: slice · estLines: 200
- Why: spec section 1: cutting a target adds 1 point, cutting a hazard ends the session, a missed target costs a chance, 3 chances ending at 0, fixed time steps independent of the frame rate.
- Scope:
  - `Simulation` in `Sources/EngineCore/Simulation.swift`: `step()` moves objects by velocity and acceleration over `EngineConfig.fixedStep`, launches from the `LaunchSchedule` on its delay while running, removes fallen objects and takes a chance per uncut target, ends at 0 chances; `advance(by:)` accumulates time and runs whole fixed steps; `swipe(_:)` cuts every live object a segment of the points hits, +1 per target, a hazard ends the session; nothing changes once the session is over; `start()` starts a held clock
- Acceptance:
  - `SimulationTests` fail first, then pass: a swipe through a target adds 1 and removes it, a missing swipe changes nothing, a hazard swipe ends the session, 3 missed targets end the session, `advance` in 1 call of 0.1 s equals 12 steps and equals 10 calls of 0.01 s, a real `LaunchSchedule` run of 2000 steps with no input shows each launched target on-screen before any chance is lost, the same seed gives the same state; slice is GREEN
- Out of scope:
  - the reducer and the screen
- Covers: req-cut-target, req-hazard, req-miss, req-fixed-step
- Writes: Packages/AppFeature/Sources/EngineCore/Simulation.swift, Packages/AppFeature/Tests/EngineCoreTests/SimulationTests.swift
- Tests: Packages/AppFeature/Tests/EngineCoreTests/SimulationTests.swift

### screen-ui
Drive the simulation from the reducer on a clock and replace the posts screen with the session screen.
- Deps: spec-contract · Gate: slice · estLines: 260
- Why: spec section 2, the session screen, and "Launching the app starts a session with a count of 0 and 3 chances".
- Scope:
  - `TargetFeature` in `Sources/AppCore/TargetFeature.swift`: on appear starts a `continuousClock` timer effect (unless the scenario holds the clock) sending ticks that call `advance(by:)`; swipe began/moved/ended builds the trail and calls `swipe(_:)` with the field-space points; ended clears the trail and starts a held clock; start again resets to a fresh live session; the timer stops at session end
  - `TargetView` draws each object at its scaled position, the trail as a fading path, the count and chances, and a session-over overlay with the final count and Start again; 1 `DragGesture` on the whole screen
  - `AppView` shows `TargetView` over `store.scope(state: \.session, action: \.session)`; `LaunchFlowUITests` checks the session's launch state under `launch-held`
- Acceptance:
  - `TargetFeatureTests` with a `TestClock` fail first, then pass: launch state is count 0 and 3 chances, ticks advance the step count, a swipe builds then clears the trail, start again resets the session; slice is GREEN
- Out of scope:
  - engine rules, which the engine tasks own
- Covers: req-launch, req-screen, req-ended, req-existing-tests
- Writes: Packages/AppFeature/Sources/AppCore/TargetFeature.swift, Packages/AppFeature/Sources/AppUI/TargetView.swift, Packages/AppFeature/Sources/AppUI/AppView.swift, Packages/AppFeature/Tests/AppCoreTests/TargetFeatureTests.swift, UITests/LaunchFlowUITests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/TargetFeatureTests.swift, UITests/LaunchFlowUITests.swift

### spec-validation
Write the flow checks against the contract's names, and record why each fails now.
- Deps: spec-contract · Gate: slice · estLines: 80
- Why: every requirement a user sees needs a check that fails before its tasks merge and passes after.
- Scope:
  - 1 file under `.harness/qa/spec/` per `## Validation` row whose `Writer` is this task
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-launch, req-cut-target, req-hazard, req-miss, req-screen, req-ended
- Writes: .harness/qa/spec/

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-launch | flow | `qa/launch.flow.json` | screen-ui | spec-validation | launch under `launch-held`, read `Count: 0` and `Chances: 3` |
| req-cut-target | flow | `qa/cut-target.flow.json` | engine-sim, screen-ui | spec-validation | `target-center`: drag from `session.object.0` to `session.edge`, then `Count: 1` |
| req-hazard | flow | `qa/cut-hazard.flow.json` | engine-sim, screen-ui | spec-validation | `hazard-center`: drag from `session.object.0` to `session.edge`, then `Ended` |
| req-miss | flow | `qa/miss.flow.json` | engine-sim, screen-ui | spec-validation | live session with no input: `Chances: 2` appears, then `Ended` |
| req-screen | flow | `qa/screen.flow.json` | engine-sim, screen-ui | spec-validation | live session: `session.clock` value moves, a `session.object.*` appears, count and chances show |
| req-ended | flow | `qa/ended.flow.json` | engine-sim, screen-ui | spec-validation | live session with no input reaches `Ended` and `Final count: 0`; Start again shows `Count: 0` and `Chances: 3` |
| req-motion | | | | | the engine-spawn unit tests check the spawn point, the upward velocity, the apex and the target-to-hazard mix |
| req-seed | | | | | the engine-spawn unit tests compare 2 schedules built with 1 seed |
| req-cut-test | | | | | the engine-cut unit tests are the requirement itself |
| req-fixed-step | | | | | the engine-sim unit tests compare 1 large and many small `advance` calls |
| req-existing-tests | | | | | gate: final runs every area's whole suite |
