# Replace the posts screen with a testable screen whose state advances on a clock

## Requirements

- req-launch: Launching the app starts a session with a count of 0 and 3 chances shown on screen
- req-motion: Objects launch from below the screen in upward arcs under acceleration, mostly target and sometimes a hazard, and the simulation advances in fixed time steps independent of the frame rate
- req-seed: The same seed produces the same launches, checked by a unit test
- req-cut-test: The swipe-segment-against-object test has unit tests, including a swipe that only grazes the object's edge
- req-cut-target: A swipe through a target cuts it and adds 1 point, and a swipe that misses cuts nothing
- req-hazard: A swipe through a hazard ends the session
- req-miss: Each target that falls back off the screen uncut costs 1 chance, and the session ends at 0 chances
- req-screen: The session screen draws the moving objects and a swipe trail, shows the count and chances, and on the end shows "Ended" with the final count and a "Start again" button that starts a new session
- req-existing-tests: The existing APIClient, LogClient and AppFeature tests keep passing

## Areas

- AppFeature (Packages/AppFeature, swiftpm; warm test time unknown, slice measures it): EngineCore engine target, TargetFeature reducer, TargetView
- InterviewStarter (., xcode; warm test time unknown): composition root and UITests; the app already links AppCore and AppUI, so no project file change

## Assumptions

- The repository is small, so the orchestrator read it directly and launched no explorers.
- The engine sits in the AppFeature package as a new pure-Swift `EngineCore` target (no TCA) plus a `TargetFeature` reducer in AppCore and a `TargetView` in AppUI, so the Xcode project needs no new package or product links.
- "Replace that screen" while "keep the existing tests passing": AppFeature stays the root reducer and gains a `session` child (the repo's own convention: "new screens join it as child features"); its posts-loading state and actions stay so `AppFeatureTests` pass unchanged, but `AppView` no longer triggers a load and shows only the session.
- `UITests/LaunchFlowUITests.swift` asserts the posts screen, which the spec removes; it is rewritten to assert the new first screen (count 0, 3 chances). The unit tests of the existing packages are the "existing tests" the spec means.
- The world is a fixed 400 x 800 point space with y growing downward; the view scales it to fit the screen.
- The fixed step is 1/60 s; `advance(by:)` accumulates real elapsed time and runs whole steps, carrying the remainder.
- A hazard falling off screen uncut costs nothing; a cut target leaving the screen costs nothing.
- An object is cut when a swipe segment comes within its radius of its centre (distance <= radius), so a segment tangent to the edge counts as a graze that cuts.
- "Start again" starts a new session with the next seed (seed + 1), so sessions differ but each stays reproducible.
- Cutting happens live: each drag update cuts along the segment from the previous drag point to the new one.
- `SeededGenerator` is SplitMix64, so the waves don't depend on Swift's unseeded system generator.
- spec-screen returned review-blocked (major: no test cuts target in a live session, which the stubbed engine on its branch couldn't show); the halt took the recommended retry, with the merged engine brought into its branch and the finding quoted in its brief.
- Fixer (spec-screen): opening grace of 4 s before the first launch, so a user, and a flow reading the starting HUD, has time before any target can be missed.
- Fixer (spec-screen): the first 3 waves are 1 object on a high arc, 90-120 steps apart, so a session with no input lasts well over 8 s.
- Fixer (spec-screen): acceleration is 500 pt/s^2 (airtime about 3 s), so each object stays reachable long enough to swipe.
- Fixer (spec-screen): the Start again button has a 44 x 44 pt minimum hit target.
- Flow repair: req-launch `qa/launch-start.flow.json` read "Chances: 0" after launch latency let the no-input session end before the read; sent to a repair worker (cause still-red).
- spec-engine's minor review finding (no test for 2 target missed in 1 step or stepping after the end) was non-blocking and merged as is.

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-launch | flow | `qa/launch-start.flow.json` | spec-screen | spec-validation | |
| req-screen | flow | `qa/ended-restart.flow.json` | spec-engine, spec-screen | spec-validation | |
| req-motion | | | | | data: launches are random in the running app; EngineCoreTests in spec-engine check arcs, acceleration and fixed steps |
| req-seed | | | | | data: the seed is internal; EngineCoreTests in spec-engine compare 2 runs of 1 seed |
| req-cut-test | | | | | data: geometry only; EngineCoreTests in spec-engine check hit, miss and graze |
| req-cut-target | | | | | data: a swipe through a moving random target can't be aimed in a scripted flow; EngineCoreTests in spec-engine place a target and swipe it |
| req-hazard | | | | | data: a hazard's position is random in the running app; EngineCoreTests in spec-engine place a hazard and swipe it |
| req-miss | | | | | data: the session-over flow shows chances running out; EngineCoreTests in spec-engine count each missed target |
| req-existing-tests | | | | | gate: final runs every area's whole suite |

### spec-contract
Declare the session engine, reducer and view types with stub bodies, behaviour unchanged.
- Deps: none · Gate: slice · estLines: 220
- Why: the engine and the screen are built in parallel against 1 declared shape.
- Scope:
  - `EngineCore` target and `EngineCoreTests` test target in `Packages/AppFeature/Package.swift`; AppCore depends on EngineCore
  - `EngineCore` types: `Vector`, `ObjectKind`, `FlyingObject`, `CutTest`, `SeededGenerator`, `LaunchSchedule`, `Simulation` with stub mutating methods; initial state (count 0, 3 chances) is real
  - `TargetFeature` reducer stub in AppCore, `TargetView` stub and `TargetAccessibilityID` in AppUI; `AppView` unchanged
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - any motion, cutting, counting or UI behaviour
- Covers: req-launch
- Writes: .swiftgate.toml, Packages/AppFeature/Package.swift, Packages/AppFeature/Sources/EngineCore/, Packages/AppFeature/Tests/EngineCoreTests/, Packages/AppFeature/Sources/AppCore/TargetFeature.swift, Packages/AppFeature/Sources/AppUI/TargetView.swift

### spec-engine
Implement the pure simulation: seeded launches, acceleration arcs, fixed steps, cutting, count and chances.
- Deps: spec-contract · Gate: slice · estLines: 300
- Why: spec section 1, "The simulation", and the acceptance criteria on cutting, hazards, misses, the cut test and seeds.
- Scope:
  - `SeededGenerator` as SplitMix64; `LaunchSchedule` launches from below the world bottom with upward velocity, mostly target, sometimes a hazard, on a cadence drawn from the generator
  - `Simulation.step()` applies acceleration and velocity per fixed step of `Simulation.timeStep`, launches due objects, removes objects that fell off the bottom and charges a chance for each uncut target; the end at 0 chances
  - `Simulation.advance(by:)` runs whole fixed steps for the elapsed time and carries the remainder
  - `CutTest.segment(_:_:intersects:radius:)` segment-to-circle distance test; `Simulation.cut(along:)` marks each object hit by any consecutive segment cut, adds 1 per target, ends the session on a hazard; no effect after the end
- Acceptance:
  - EngineCoreTests fail on the stubs first, then pass: cut hit, miss, edge graze (tangent) and near-miss; 2 simulations of 1 seed produce identical launches and a different seed differs; a target swiped adds 1 point; a swipe that misses cuts nothing; a hazard swiped ends the session; each missed target costs 1 chance and the third ends the session; advance(by:) with frame times 1/30 and 1/120 reaches the same state over 1 s; a launched object rises then falls
  - slice is GREEN
- Out of scope:
  - the reducer, the view and the UI tests
- Covers: req-motion, req-seed, req-cut-test, req-cut-target, req-hazard, req-miss
- Writes: Packages/AppFeature/Sources/EngineCore/, Packages/AppFeature/Tests/EngineCoreTests/
- Tests: Packages/AppFeature/Tests/EngineCoreTests/

### spec-screen
Build the session reducer and screen and make it the app's first screen.
- Deps: spec-contract · Gate: slice · estLines: 280
- Why: spec section 2, "The session screen", and "Launching the app starts a session with a count of 0 and 3 chances".
- Scope:
  - `TargetFeature`: `.task` runs a clock timer sending `.tick(seconds:)` that forwards to `simulation.advance(by:)`; `.dragChanged` appends to `trail` and cuts along the last segment; `.dragEnded` clears `trail`; `.restartButtonTapped` starts a new `Simulation` with seed + 1; the timer keeps running across sessions
  - `AppFeature` gains `session: TargetFeature.State` and `case session(TargetFeature.Action)` with a `Scope`; posts state and actions stay as they are
  - `TargetView`: a canvas drawing each object (target and hazard distinct, cut ones hidden or faded) scaled from the 400 x 800 world, the trail as a path, "Count: N" and "Chances: N" labels, and an overlay with "Ended", "Final count: N" and a "Start again" button, using the `TargetAccessibilityID` ids; `AppView` shows `TargetView` and no longer loads posts
  - rewrite `UITests/LaunchFlowUITests.swift` to assert "Count: 0" and "Chances: 3" on launch
- Acceptance:
  - TargetFeatureTests (non-exhaustive TestStore where the engine changes state) fail first, then pass: drag points build the trail and drag end clears it; start again on a session-over session resets to count 0, 3 chances, not over, with seed + 1; ticks forward elapsed time
  - existing AppFeatureTests still pass unchanged; slice is GREEN
- Out of scope:
  - engine behaviour in EngineCore; particles, sound, high counts, pause
- Covers: req-launch, req-screen, req-existing-tests
- Writes: Packages/AppFeature/Sources/AppCore/TargetFeature.swift, Packages/AppFeature/Sources/AppCore/AppFeature.swift, Packages/AppFeature/Sources/AppUI/TargetView.swift, Packages/AppFeature/Sources/AppUI/AppView.swift, Packages/AppFeature/Tests/AppCoreTests/TargetFeatureTests.swift, UITests/LaunchFlowUITests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/TargetFeatureTests.swift, UITests/LaunchFlowUITests.swift

### spec-validation
Write the flow checks against the contract's names, and record why each fails now.
- Deps: spec-contract · Gate: slice · estLines: 80
- Why: every screen requirement needs a check that fails before its tasks merge and passes after.
- Scope:
  - `launch-start.flow.json`: launch, see "Count: 0" on `target.count` and "Chances: 3" on `target.chances`
  - `ended-restart.flow.json`: launch, touch nothing, wait up to 60 s for `target.ended` ("Ended") as missed target drain the chances, see `target.finalCount` and `target.restart`, tap it, see "Chances: 3"
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-launch, req-screen
- Writes: .harness/qa/spec/
