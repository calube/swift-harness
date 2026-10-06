# Testing playbook

How to write, place and judge tests in a swift-harness app. Read it before you write a test, when
a `swiftgate` verdict cites a `P` rule or a `test.*` rule id, or when you judge whether a test can
catch anything. The code rules (concurrency, architecture, clients, errors, logging) live in
[standards.md](standards.md). This file owns everything about tests.

Every rule here names what enforces it:

- A `swiftgate` command and rule id: `swiftgate lint`, `testlint`, `arch`, `impact`, `coverage`,
  `check`, `test`, `prove`, `stress`, `reach`, `mutate`, `snapshots record`, `judge` or `stats`.
  [standards.md § Rule id index](standards.md#rule-id-index) lists every rule id.
- `review`: human or review-agent judgment, for what no tool can see.

A waiver uses the same-line syntax from [standards.md § Escape hatches](standards.md#escape-hatches):
`// swiftgate:allow <rule-id> — <reason>`. A bare allow is itself a gating finding, and the run
report counts every allow.

## 1. Tiers

| Tier | What runs | Runner | Budget | Why it's deterministic |
|---|---|---|---|---|
| T0 static | `swift format`, `swiftgate lint` (determinism bans in Core: `Date()`, `UUID()`, `Task.sleep`, `asyncAfter`, `.random`), `swiftgate arch`, `swiftgate testlint`, and `swiftgate impact` at `push` and above | `swiftgate` | 5 s (`[budgets] t0`) | No IO. |
| T1 host | `TestStore` tests (exhaustive), client tests, engine rule and replay tests | `swift test` on the affected packages | 60 s (`[budgets] t1`) | Injected dependencies, `TestClock`/`ImmediateClock`, `withMainSerialExecutor` only inside `.serialized` suites. |
| T2 simulator | Snapshot tests, view and integration tests | `xcodebuild test` on a cloned simulator | none by default (`[budgets] t2`) | Pinned device and OS, no network, dependency overrides. |
| T3 flow | A thin XCUITest smoke test per critical flow | `xcodebuild test` on a cloned simulator | none by default (`[budgets] t3`) | Launch-argument scenario injection (`-harness-scenario <name>`). |

Budgets are in seconds in `.swiftgate.toml`. A tier over its budget gets a minor `swiftgate.budget`
finding in the run report, and `swiftgate stats` tracks the p50 and p95 against it.

Gate T1 and `prove` builds skip dSYMs, so links don't stall on `dsymutil`. For a symbolicated
crash trace, rerun `swift test` yourself.

`swiftgate check --tier` composes the tiers:

| `--tier` | Runs |
|---|---|
| `fast` | T0, plus T1 on the affected packages |
| `push` | T0, T1 on every package, T2 on the affected packages, `impact`, `coverage`, and T1 presence per module |
| `ready` | everything `push` runs, plus T3, `stress`, `prove`, per-test `reach`, `mutate` on new or changed code, and the judge when `[judge]` turns it on |

| `check` flag | Effect |
|---|---|
| `--base <ref>` | Measure changes from the merge base of HEAD and this ref (default `origin/main`) |
| `--prove`, `--mutate`, `--impact`, `--coverage` | Add that step to a tier below the one that runs it anyway |
| `--app-build` | Also compile the app scheme for a generic simulator, which the host build can't |
| `--proof-base <ref>` | An ancestor where `prove` retries a compile-only test (P2); repeatable, oldest first |

`prove`, `stress` and `reach` cover host (T1) tests only. At `ready`, `check` notes that
simulator prove and stress did not run, and that note never reads as green.

Pick the lowest tier that can see the behavior. If only the simulator can reach it, its logic is
in the wrong module: move it into a Core or Client module and test it at T1.

## 2. How to name a test

Every Swift Testing test gets a display name in this shape:

```swift
@Test("<behavior> — catches <regression>")
```

- **Behavior:** what the code does, in words a user or caller would recognize.
- **Regression:** the bug this test turns red on, stated as its symptom.

```swift
// Good: the behavior, and the symptom a user would see if it broke.
@Test("a failed fact request stops loading and logs an error — catches a stuck spinner and a silent failure")

// Bad: no display name. `test.unnamed` fails the gate.
@Test func factFailure() async { … }

// Bad: names exist, but the regression is vague. The judge scores this low.
@Test("fact works — catches bugs")
```

An XCTest method (an XCUITest) can't carry a display name. Put the regression in a `///` doc
comment on the method instead, the way `UITests/CounterFlowUITests.swift` does in section 7.6.

If you can't write the "catches" half, the test likely protects nothing. Delete it or find the
regression it guards.

A test name never carries a ledger, claim or doc id, or a plan codename such as `Phase 2`
(`test.leaked-id`).

**Enforced by:** `swiftgate testlint` rules `test.unnamed` (missing display name) and
`test.leaked-id`; `swiftgate judge` question `name-specificity` ("how specific is the regression
name"); review.

## 3. Rules

Each rule has the same shape as the standards:

- **Do:** what to write.
- **Tell:** how you see it broke.
- **Enforced by:** the check, or review.
- **Source:** the upstream doc, or the incident behind it.

**P1. Every test names the regression it catches.**
- **Do:** name every test with section 2's convention. The regression is a user-visible or caller-visible symptom.
- **Tell:** a `@Test` with no string; a "catches" clause that restates the behavior ("catches increment not incrementing") or says nothing ("catches bugs").
- **Enforced by:** `testlint` `test.unnamed`; `judge` (advisory; gates at `ready` only past `block_threshold`); review · **Source:** incident: none yet.

**P2. A new test fails red before it passes green.**
- **Do:** write the test first and watch it fail on an **assertion**, not on a compile error or a missing import. Then write the code.
- **Tell:** a test that passes with the source change reverted.
- **Enforced by:** `swiftgate prove` (also in `check --tier ready`). It runs each new or changed host test on the change. Then it runs them in a scratch git worktree that restores production source to the merge base, while tests, manifests and resources keep the change. A test that only stops compiling there gets a retry at each `--proof-base` ancestor, such as a surface commit (`build proof-bases` lists them). Rules:
  - `prove.not-proven`: passes with the source reverted, or skipped.
  - `prove.compile-only`: only stops compiling.
  - `prove.crashed`: crashes with the source reverted.
  - `prove.hangs-at-base`: runs past its bound with the source reverted, where it should fail on an assertion.
  - `prove.fails-at-head`: fails on the change itself.

  `prove` covers host tests only; it doesn't prove simulator tests · **Source:** incident: a trial run's new test passed with its source change reverted.

**P3. Verdicts come from evidence, not exit codes.**
- **Do:** trust the gate's reading of the test results: more than 0 tests executed, no unaccounted skips. Never pass `-retry-tests-on-failure`.
- **Tell:** a green run with 0 tests executed (a filter that matched nothing); a retry flag in a script. A retried pass hides a flake.
- **Enforced by:** `swiftgate test` and `check` read the xUnit reports (T1) and the xcresult (T2, T3). The gate builds every `xcodebuild test` call from a closed argument list, so `-retry-tests-on-failure`, `-test-iterations`, `-run-tests-until-failure` and `-test-repetition-relaunch-enabled` can't reach it · **Source:** incident: none yet.

**P4. Snapshots never record during a test run.**
- **Do:** leave `record:` out, or set it to `.never`. Re-record only through `swiftgate snapshots record` on the pinned simulator from `.swiftgate.toml`, so reference changes show up in the diff.
- **Tell:** `record: .all`, `.missing` or `.failed` in a test; a new `__Snapshots__/*.png` that nobody reviewed. The library default, `.missing`, writes a new reference without a word and **passes**.
- **Enforced by:** `lint` `snap.record-mode` (any `record:` other than `.never` or `nil` is RED). The gate runs every tier with `SNAPSHOT_TESTING_RECORD=never`, so a missing reference fails. The SwiftPM adapter sets it, and `test --tier t2|t3` sets `TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never` for `xcodebuild` · **Source:** [swift-snapshot-testing record modes](https://github.com/pointfreeco/swift-snapshot-testing). Incident: none yet.

**P5. `TestStore` is exhaustive by default.**
- **Do:** assert every state change in `send`'s and `receive`'s trailing closure. If a test must be non-exhaustive, justify it on the same line.
- **Tell:** `store.exhaustivity = .off` or `withExhaustivity(.off)` with no reason.
- **Enforced by:** `testlint` `test.non-exhaustive-store` (waive with `// swiftgate:allow test.non-exhaustive-store — <reason>`) · **Source:** [TCA testing](https://pointfreeco.github.io/swift-composable-architecture/main/documentation/composablearchitecture/testingtca). Incident: none yet.

**P6. `TestClock`-driven tests run in a `.serialized` suite, inside `withMainSerialExecutor`.**
- **Do:** when a test advances a `TestClock` and expects work to have happened in between, put the suite under `@Suite(.serialized, .timeLimit(.minutes(1)))` and wrap the test body in `withMainSerialExecutor { … }`. Keep TestStore tests that don't touch a clock out of those suites so they stay parallel.
- **Tell:** a test that calls `clock.advance` outside `withMainSerialExecutor`; `withMainSerialExecutor` in a suite without `.serialized`; a suite that passes alone and hangs when the whole package runs.
- **Enforced by:** `testlint` `test.testclock-serialized`: a Swift Testing test that uses `TestClock` or `withMainSerialExecutor` with no enclosing `@Suite(.serialized …)`. XCTest is exempt because it runs a class's tests one at a time. Review checks the `withMainSerialExecutor` wrap and `.timeLimit`.
- **Source:** `withMainSerialExecutor` sets a process-global executor hook, and its docs cover XCTest alone. Swift Testing runs tests in parallel by default. In an unserialized suite, a test can swap the hook while another test runs. **Incident:** in the sample app, the `APIClientLiveTests` retry tests hung under load until the suite became `.serialized` and each test ran inside `withMainSerialExecutor`. `.timeLimit` turns any future hang into a failure instead of a stuck run.

**P7. No real time or swallowed errors in tests.**
- **Do:** drive time with `TestClock` or `ImmediateClock`. Let errors propagate (`async throws` tests) or record them with `Issue.record`.
- **Tell:** `Task.sleep`, `usleep` or a counted `Task.yield()` loop in a test; `try?` or an empty `catch` in a test body.
- **Enforced by:** `testlint` `test.sleep`, `test.yield-loop`, `test.swallowed-error`. For Core code, `lint` `det.*` does the same job ([standards.md § 3](standards.md#3-dependencies-and-clients), D1) · **Source:** incident: none yet.

**P8. Stress new and changed tests before ready.**
- **Do:** expect new or changed host tests to run 10 times at the `ready` tier. Any failure is RED. `stress` runs N separate `swift test --parallel` processes over the selected tests. It does not shuffle: `swift test` on Swift 6.2 has no shuffle or repeat option. What varies between runs is scheduling: Swift Testing runs the tests in parallel, and XCTest spreads them over worker processes.
- **Tell:** a test that depends on shared mutable state, wall time, or another test running first or at the same time. A dependency on declaration order alone can survive `stress`, so review looks for it.
- **Enforced by:** `swiftgate stress --n 10` (also in `check --tier ready`), rules `stress.failed` and `stress.crashed` · **Source:** incident: none yet.

**P9. A changed Core, Client or Live file comes with a test change in the same module.**
- **Do:** change `<Module>Tests` in the same commit range, or file an exemption with a reason in `.harness/impact-exemptions.json`:
  ```json
  { "schema": 1, "exemptions": [ { "module": "GameEngine", "reason": "renamed a private helper" } ] }
  ```
  An entry names either a `module` or a `path`, never both, and gives a reason. A file whose tokens match the merge base needs neither. That covers a change to whitespace and comments alone, as after `swift format`. A file that uses `#line`, `#column` or `#sourceLocation`, or doesn't parse, always counts as changed.
- **Tell:** a logic change with no test diff. UI-flow (T3) test changes don't count.
- **Enforced by:** `swiftgate impact` (compares against the merge base of `--base`, default `origin/main`), rule `impact.untested-change` · **Source:** incident: none yet.

**P10. Every engine module has a replay test.**
- **Do:** seed plus input log gives an identical final state across runs. Pin the RNG algorithm with a reference-sequence test, so a change to it can't invalidate recorded replays without a red test.
- **Tell:** an `engine` module in `.swiftgate.toml` with no replay test; 2 replays that disagree.
- **Enforced by:** `arch` `arch.engine-replay-test`. Some test in a target that depends on the engine must have "replay" in its function name, or in its display name before the `— catches` clause. A replay the catches clause alone mentions doesn't count, such as an RNG or reset test that guards recorded replays. The heuristic reads names, so review still checks that the test replays a seed and input log. `det.*` and [standards.md § 8](standards.md#8-engine-modules) (G1) cover the engine code itself · **Source:** incident: none yet.

**P11. T3 is a closed list of flows.**
- **Do:** declare each end-to-end flow as a `[[flows]]` entry with a `name` and a `reason`. Start the XCUITest class or method name (after `test`) with the flow name; matching ignores case and punctuation.
- **Tell:** an XCUITest whose class and method match no flow; more flows than `pyramid.max_flows` (default 10).
- **Enforced by:** `testlint` `test.xcuitest-unlisted-flow`. `test --tier t3` (and `check --tier ready`) judges the UI tests that ran:
  - `t3.unmapped-flow`: a test that matches no flow.
  - `t3.flow-untested`: a flow no test covered.
  - `t3.max-flows`: more UI tests than `pyramid.max_flows`.
  - `t3.app-container`: no `.xcworkspace` or `.xcodeproj` at the repository root to run the app scheme from, or more than 1 of a kind. A workspace wins over a project.

  Loading `.swiftgate.toml` also rejects more `[[flows]]` entries than `max_flows` (`swiftgate.config`). With no `[[flows]]` at all, T3 runs nothing and leaves a note · **Source:** incident: none yet.

**P12. A fixture that hangs on purpose ends by itself.**
- **Do:** a test may write out a script or source that loops or waits on purpose. Give it its own bound: a `Date` or `DispatchTime` deadline, `timeout <n>`, `alarm(`, or an exit in the loop.
- **Tell:** a string literal in a test that holds a constant-true loop (`while true`, `while :`, `while True:`, `for (;;)`, `repeat … while true`) with no `break`, `return` or `exit` in its body. Or one that holds `sleep infinity`, `RunLoop…run()`, `dispatchMain()` or `pause()`. In both cases, with no deadline anywhere in the literal.
- **Enforced by:** `testlint` `test.hang-without-deadline`, `test.unbounded-wait` · **Source:** incident: `prove` and `mutate` run tests against reverted code. A test's `while true {}` fixture kept spinning after every such run until it gained a 90 s deadline.

## 4. Pyramid enforcement

Raw tier counts are easy to game, so the gate checks where tests live and what they reach.

| Rule | How it's detected | Enforced by |
|---|---|---|
| Every XCUITest maps to a `[[flows]]` entry | test and class names vs. config | `testlint` `test.xcuitest-unlisted-flow` |
| At most `pyramid.max_flows` flows (default 10), and at most that many UI tests | config; the UI tests a T3 run executed | config validation (`swiftgate.config`); `test --tier t3` rule `t3.max-flows` |
| A T2 test that renders no view or snapshot and imports only Core/Client modules belongs at T1 | SwiftSyntax import and call scan | `testlint` `test.misplaced-t2` |
| Every Core, Client and Live module has at least 1 T1 test | module graph vs. discovered tests | `swiftgate coverage` / `check --tier push` rule `coverage.no-t1-tests` |
| T1 alone covers at least `pyramid.diff_coverage_min` (default 0.90) of changed Core/Client/Live lines | `swift test --enable-code-coverage` → llvm-cov JSON ∩ diff | `swiftgate coverage` rule `coverage.diff` (RED), with `coverage.uncovered-lines` naming the lines |
| Tier runtimes stay within budget; p95 trend | run history in `.harness/runs/history.jsonl` | `swiftgate stats` |

Diff coverage from T1 alone keeps the pyramid honest. If only the simulator reaches a line, its
logic is in the wrong module.

## 5. Useless-test detection

3 layers, cheapest first. Each check lives at the lowest tier where it's reliable.

### 5.1 Static: `swiftgate testlint` (T0)

SwiftSyntax over test files. Every rule is RED.

| Rule id | Fires on |
|---|---|
| `test.no-assertion` | No `#expect`, `#require`, `XCTAssert*`, `store.send`/`receive` state assertion, `assertSnapshot` or `expectNoDifference` |
| `test.tautology` | An assertion that can't fail: `#expect(true)`, `x == x`, a value the test just built |
| `test.existence-only` | Non-nil checks are the only assertions |
| `test.asserts-own-double` | Asserting a value the test configured on its own double |
| `test.swallowed-error` | `try?` or an empty `catch` without `Issue.record` |
| `test.sleep` | `Task.sleep` or `usleep` |
| `test.yield-loop` | A counted loop that only awaits `Task.yield()`, a sleep-like wait (P7) |
| `test.duplicate` | Same normalized body as another test |
| `test.unnamed` | `@Test` without a display name |
| `test.leaked-id` | A ledger, claim or doc id, or a plan-codename shape, in a test's display name or method name |
| `test.non-exhaustive-store` | Non-exhaustive `TestStore` without a same-line justification |
| `test.xcuitest-unlisted-flow` | XCUITest outside `[[flows]]` |
| `test.misplaced-t2` | T2 test that should be T1 |
| `test.testclock-serialized` | A Swift Testing test using `TestClock` or `withMainSerialExecutor` outside a `.serialized` suite (P6) |
| `test.hang-without-deadline` | A string literal that waits forever with no deadline (P12) |
| `test.unbounded-wait` | A loop in a test that awaits with no deadline, attempt cap or exit, or a `for await` that leaves after its first element with no timeout around it (P12) |

Run it on a path relative to the repository root, such as
`swiftgate testlint Packages/CounterFeature/Tests` in an app repository. With no argument it
checks everything.

### 5.2 Behavioral (push and ready)

- **`prove`:** each new or changed host test fails on an assertion with the source change
  reverted (P2).
- **`mutate`** (`swiftgate mutate`, and in `check --tier ready`): mutation testing on the
  **changed** Core/Client/Live lines, rerunning the T1 test targets that depend on each mutated
  module. See the next list.
- **Per-test reach** (`swiftgate reach`, and in `check --tier ready`): each new or changed host
  test runs alone with coverage.
  - RED `reach.no-production-lines`: it covers 0 production lines in the module it targets. That
    is `<Module>` for `<Module>Tests`, otherwise its local production dependencies.
  - RED `reach.fails-alone`: it fails when run alone.

How `mutate` works:

| Aspect | Behavior |
|---|---|
| Operators | Negate a conditional, shift a relational boundary (`<` ↔ `<=`), return a default, remove a call, remove an effect or `send` |
| Verdicts | A surviving mutant is RED `mutate.survived` at `ready`, unless its line carries `// swiftgate:equivalent-mutant — <reason>`. A mutant that doesn't compile is `mutate.unviable` and stays out of the kill rate |
| Workers | Each mutant builds and tests in its own scratch worktree, workers in parallel: seconds to minutes per package. Default min(cores − 1, ceil(mutants / 2), 4), since each worker pays a cold build per package; `[mutation] max_workers` or `--jobs` overrides it. Each worker gets cores ÷ workers jobs and builds without debug information |
| Build seeding | Each worker's tree starts from a clone of the package's `.build`, minus the module cache. That saves the dependency fetch but not the compile: SwiftPM rebuilds for the tree's new paths |
| Cap | `[mutation] max_mutants` (default 30). Beyond it, mutate samples with a seed taken from the diff, so a rerun judges the same mutants |
| When it runs | `check` skips it while T1 is RED; the Stop hook never runs it. `review-input` runs it too, so reviewers see surviving mutants |

### 5.3 Judgment

Some slop only a reader sees: vacuous or restated regression names, tests coupled to
implementation details, over-mocking, the wrong abstraction level. The `test-gate` skill carries a
rubric for these, and the `test-quality` review agent applies it.

### 5.4 Judge seam: `swiftgate judge`

A `Judge` protocol takes typed questions and returns calibrated probabilities, never free-form
verdicts. The `test-quality@1` question set asks 4 questions:

| Question id | Question | Answer type | May block |
|---|---|---|---|
| `fails-if-broken` | Would this test fail if the behavior it names were broken? | binary → p | yes |
| `tier` | Which tier does this test belong in (T1/T2/T3)? | choice → p per option | no |
| `name-specificity` | How specific is the regression name (vague / partial / specific)? | score → level + p | no |
| `asserts-implementation` | Does it assert implementation details rather than behavior? | binary → p | yes |

The judge is off by default (`backend = "none"`), since remote backends send test source off the
machine. Below `ready` it never turns a run RED.

| Aspect | Behavior |
|---|---|
| In / out | In: test source, diff, versioned question set. Out: findings with answer, probability, rationale and deciding backend |
| Policy | On a blocking question, p ≥ `block_threshold` (default 0.9) may block at `ready`. From `advisory_threshold` (default 0.6) up is advisory. The gate drops the rest |
| Cache | `.harness/judge-cache/`, keyed by test, diff, questions as sent, backend and model |
| Calibration | `gate/Fixtures/judge/` holds labeled tests and 1 recording per backend. `swiftgate self-test --judge` scores each recording offline against its baseline and fails on a per-question precision or recall drop. `--judge-backend <backend> --record` re-records live |
| `swiftgate judge tests [--ready]` | Judges new and changed host tests, as `check --tier ready` does. Plain `swiftgate judge` runs it |
| `swiftgate judge ask --input <file>` | Prints JSON answers to any question set, with no policy |
| Commit hook | Asks advisory comment questions on a Claude-authored commit |
| Backend failure below `ready` | A non-gating `judge.not-run` note |

| `[judge] backend` | `claude` | `jev` (TypeSafe's Jev, over HTTP) |
|---|---|---|
| Model | `model`, default `sonnet` | pinned `jev-1.13.0`; config refuses an alias such as `jev-latest` |
| Egress | the `claude` CLI | `send_to = "api.typesafe.ai"` required |
| Key | none in swiftgate | `TYPESAFE_API_KEY` in the environment (`doctor` checks); config refuses a key |
| Question set | `test-quality@1` | `test-quality@2-jev`: narrower sub-questions, scored on `@1`'s labels |
| Recording | `recording.json` | `recording-jev.json` |
| `judge bench` arm | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0#test-quality@2-jev`; `cascade:jev-1.13.0,claude-sonnet-5-5` for both |

| With `jev` | Behavior |
|---|---|
| Jev blocks, Claude settles | A Jev answer at or above `block_threshold` on a blocking question blocks `ready`, with Claude's reason, or the template's and a `failureScenario` that says why. In the uncertain band Claude answers in `@1`'s words; if Claude fails, Jev's answer stays advisory |
| Jev down at `ready` | Claude takes the blocking questions a retried Jev can't answer. If Claude can't either, `judge.blocked` makes the gate BLOCKED |
| Benchmark | `judge bench` scores each `--backend` arm; `judge bench-render` compares them and lists the bands. Run it before you set Jev's thresholds |

The audit log is `swiftgate judge events`; see [judge-audit.md](judge-audit.md).

## 6. Library notes for tests

[standards.md § 0](standards.md#library-pins) lists the pins and hazards. These are the ones that
bite in tests:

- **`TestStore` is `@MainActor`.** Mark the suite `@MainActor`. Build the store inside each test;
  don't share 1 store across tests.
- **Exhaustivity** is `store.exhaustivity = .on` / `.off(...)`. Keep it on (P5).
- **`@DependencyClient` test values fail on use.** `static let testValue = Self()` makes every
  endpoint unimplemented. A test that forgets to override 1 then fails, where a silent default
  would let it pass. Override only the endpoints the test exercises, in `withDependencies:`.
- **Clocks:** use `TestClock` when the test controls time step by step, and `ImmediateClock` when
  time only has to pass. Both come from swift-clocks.
- **`withMainSerialExecutor`** (swift-concurrency-extras) is process-global. Use it only inside a
  `.serialized` suite (P6).
- **Snapshots:** record modes are `.all`, `.failed`, `.missing` and `.never`. The default,
  `.missing`, records without failing (P4). Use the `record:` parameter, `withSnapshotTesting`,
  or the `.snapshots(record:)` trait. The `isRecording` and `diffTool` globals are deprecated and
  banned: `tca.banned-api` covers them ([standards.md § 2](standards.md#2-architecture), A6).
- **Structural diffs:** use `expectNoDifference` from swift-custom-dump, and prefer the
  `.customDump` snapshot strategy over `.dump`.
- **Headless `xcodebuild`** needs `-skipMacroValidation`. `swiftgate` passes it for T2 and T3.

## 7. Worked examples

Each example comes from the sample app in the swift-harness source repository,
`examples/SampleApp`. The plugin doesn't ship it. Paths are relative to that folder.

### 7.1 Exhaustive `TestStore` (T1)

`Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift`

```swift
@MainActor
struct CounterFeatureTests {
  @Test("a failed fact request stops loading and logs an error — catches a stuck spinner and a silent failure")
  func factFailureLogs() async {
    let records = LockIsolated<[LogRecord]>([])
    let store = TestStore(initialState: CounterFeature.State(count: 7)) {
      CounterFeature()
    } withDependencies: {
      $0.apiClient.randomFact = { throw FactUnavailable() }
      $0.logClient.emit = { record in records.withValue { $0.append(record) } }
    }

    await store.send(.factButtonTapped) { $0.isLoadingFact = true }
    await store.receive(\.factFailed) { $0.isLoadingFact = false }
    #expect(records.value == [
      LogRecord(level: .error, category: "Counter", message: "fact request failed",
                attributes: [.public("count", 7)])
    ])
  }
}
```

Why it passes the gate:
- `@MainActor` suite, store built inside the test, exhaustive by default (P5). An extra state
  change or an unreceived action fails the test.
- The test overrides only the 2 endpoints it exercises. Every other endpoint stays unimplemented
  and fails the test if called.
- The log assertion checks the whole record, including the privacy tag. A log that loses its
  category, or leaks the count as private data, fails. The recorder replaces `emit`, following
  [standards.md § 5](standards.md#5-observability) (O1).
- The test uses no clock, so this suite stays parallel (P6 doesn't apply).

### 7.2 `TestClock` in a `.serialized` suite (T1)

`Packages/APIClient/Tests/APIClientLiveTests/APIClientLiveTests.swift`

```swift
// `.serialized` because `withMainSerialExecutor` swaps a process-global executor hook; it makes
// `TestClock.advance` deterministic by running the retrying task to its next sleep before advancing.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct APIClientLiveTests {
  @Test("server errors retry with exponential backoff on the injected clock — catches retries hammering the server without delay")
  func retriesWithBackoff() async throws {
    try await withMainSerialExecutor {
      let transport = ScriptedTransport([
        .status(503), .transportError(.networkConnectionLost),
        .status(200, try fixture("catfact-fact")),
      ])
      let clock = TestClock()
      let client = APIClient.live(http: transport.client, clock: clock,
                                  retry: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1)))

      let task = Task { try await client.randomFact() }
      defer { task.cancel() }

      await clock.advance(by: .milliseconds(999))
      #expect(transport.requests.count == 1)
      await clock.advance(by: .milliseconds(1))
      #expect(transport.requests.count == 2)
      // … the second backoff (2s) is checked the same way …
    }
  }
}
```

Why it passes the gate:
- The test checks the backoff at its edges: nothing at 999 ms, a retry at 1 s. An off-by-one in
  the delay, or a retry with no delay at all, fails. This kind of test also kills `<` ↔ `<=`
  mutants (`mutate`).
- The comment above the suite is a kept *why*: it explains a footgun a reader can't recover from
  the code.
- `.serialized` plus `withMainSerialExecutor` is the P6 incident fix. `.timeLimit` turns a
  regression of it into a failure rather than a hang.
- No real sleeps (`test.sleep`); the test injects the clock. For a reducer's repeating timer, see
  [testing-clock-effects.md](testing-clock-effects.md).

### 7.3 Client Live test with a fake transport (T1)

Same file. The test runs `APIClientLive` against a scripted `HTTPClient`, not the network:

```swift
@Test("a captured catfact response decodes into a Fact — catches a JSON key mapping regression")
func decodesCapturedResponse() async throws {
  let transport = ScriptedTransport([.status(200, try fixture("catfact-fact"))])
  let client = APIClient.live(http: transport.client, clock: TestClock())

  let fact = try await client.randomFact()

  #expect(fact.text.hasPrefix("Cat families usually play best in even numbers."))
  #expect(transport.requests.map(\.url?.absoluteString) == ["https://catfact.ninja/fact"])
  #expect(transport.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
}
```

Why it passes the gate:
- The response body is a **capture from the real API**, not hand-written. The capture command
  sits next to it in `Tests/APIClientLiveTests/Fixtures/README.md`. A hand-authored fixture only
  proves the decoder agrees with its author.
- It asserts both directions of the boundary: what the client decodes, and what it sent (URL,
  `Accept` header). Asserting only the decoded text would pass even if the request went to the
  wrong endpoint.
- The fake records calls, but the assertions check the client's behavior, not values the test
  configured on the fake (`test.asserts-own-double`).
- `clientErrorNotRetried` in the same suite shows the negative case: a 404 throws
  `HTTPError.unacceptableStatus(404)`, and the client sends 1 request.

### 7.4 Engine replay (T1)

`Packages/GameEngine/Tests/GameEngineTests/GameEngineTests.swift`

```swift
struct SeededGeneratorTests {
  @Test("SplitMix64 matches the reference sequence — catches an RNG algorithm change that would invalidate recorded replays")
  func referenceSequence() {
    var generator = SeededGenerator(seed: 0)
    #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
  }
}

struct GameEngineReplayTests {
  @Test("seed plus input log replays to an identical final state — catches hidden nondeterminism in the engine")
  func replayIsDeterministic() {
    let first = GameEngine.replay(seed: 42, inputs: Self.inputs)
    let second = GameEngine.replay(seed: 42, inputs: Self.inputs)
    #expect(first == second)
  }

  @Test("the seed drives the computer's moves — catches the engine ignoring its injected RNG")
  func seedChangesComputerMoves() {
    let boards = (0..<8).map { GameEngine.replay(seed: $0, inputs: [.humanPlaced(4)]).board }
    #expect(Set(boards.map { $0.firstIndex(of: .o) }).count > 1)
  }
}
```

Why it passes the gate:
- `.swiftgate.toml` declares `GameEngine` as `kind = "engine"`, so P10 requires the replay test.
- Replay equality alone can't tell a deterministic engine from one that ignores its RNG. The
  second test closes that gap, and the reference-sequence test pins the RNG so old recorded logs
  stay valid.
- The input log crosses a `.reset`, so the replay covers any state that survives reset.
- `first == second` compares 2 separate runs, so it isn't a `test.tautology`.

### 7.5 Snapshot test with recording off (T2)

`Packages/CounterFeature/Tests/CounterUISnapshotTests/CounterViewSnapshotTests.swift`, reference
image in `__Snapshots__/CounterViewSnapshotTests/counterWithFact.1.png`.

```swift
@MainActor
struct CounterViewSnapshotTests {
  @Test("counter with a loaded fact renders unchanged — catches layout regressions in the counter screen")
  func counterWithFact() {
    let store = Store(initialState: CounterFeature.State(count: 42, fact: "Cats sleep for around 13 to 14 hours a day.")) {
      CounterFeature()
    }
    assertSnapshot(
      of: UIHostingController(rootView: CounterView(store: store)),
      as: .image(on: .iPhone13, traits: UITraitCollection(userInterfaceStyle: .light))
    )
  }
}
```

Why it passes the gate:
- It has no `record:` argument, so `snap.record-mode` is clean, and the mode comes from the
  environment. `swiftgate test --tier t2` runs it with recording off. The manual equivalent, from
  `Packages/CounterFeature`, is:
  ```sh
  TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never xcodebuild test -scheme CounterFeature-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' -skipMacroValidation
  ```
  `xcodebuild` forwards `TEST_RUNNER_`-prefixed variables to the test process without the prefix.
  If the PNG is missing, this run fails instead of recording one.
- Device, OS (`[simulator]` in `.swiftgate.toml`), layout and color scheme are all fixed, so the
  image changes only when the view does.
- It imports SwiftUI and SnapshotTesting and renders a view, so it belongs at T2
  (`test.misplaced-t2` stays quiet). Section 7.1 tests the behavior behind the view at T1.

### 7.6 XCUITest mapped to a flow (T3)

`UITests/CounterFlowUITests.swift`, with its flow declared in `.swiftgate.toml`:

```toml
[[flows]]
name = "counter"
reason = "the one end-to-end path: launch, count, fetch a fact through the live API client"
```

```swift
import AccessibilityIDs
import XCTest

final class CounterFlowUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  /// Regression: the counter buttons stop updating the on-screen value (store not wired to the view).
  @MainActor
  func testIncrementAndDecrementUpdateTheDisplayedCount() {
    let app = XCUIApplication()
    app.launch()
    let value = app.staticTexts[AccessibilityID.counterValue.rawValue]
    XCTAssertTrue(value.waitForExistence(timeout: 10))
    XCTAssertEqual(value.label, "0")
    app.buttons[AccessibilityID.counterIncrement.rawValue].tap()
    app.buttons[AccessibilityID.counterIncrement.rawValue].tap()
    XCTAssertEqual(value.label, "2")
    app.buttons[AccessibilityID.counterDecrement.rawValue].tap()
    XCTAssertEqual(value.label, "1")
  }
}
```

Why it passes the gate:
- The class name starts with `Counter`, which matches flow `counter`, so
  `test.xcuitest-unlisted-flow` is clean. A new XCUITest for an undeclared flow fails T0 before
  any simulator boots.
- It checks 1 thing only T3 can see: the real app wires the store to the real view. Section 7.1
  covers the counting logic at T1. Don't copy T1 cases into T3.
- It finds elements by accessibility identifier, which the view must carry anyway
  ([standards.md § 7](standards.md#7-accessibility), X1). The identifiers come from the shared
  `AccessibilityID` enum (`counter.value`, `counter.increment`), so a renamed identifier fails to
  compile instead of failing a tap.
- It waits with `waitForExistence` and a timeout, never a sleep.

## 8. Before you push

1. Every new `@Test` has a `"<behavior> — catches <regression>"` name, and you saw it fail on an
   assertion first.
2. `swiftgate testlint` and `swiftgate lint` are green on your changes.
3. `swiftgate impact --base <your base branch>` is green, or you filed an exemption with a reason.
4. `swiftgate coverage` meets `pyramid.diff_coverage_min` from T1 alone.
5. No snapshot reference changed unless you re-recorded it on purpose on the pinned simulator, and
   the new PNG is in your diff.
6. Any test that advances a `TestClock` is in a `.serialized` suite, inside
   `withMainSerialExecutor`.
7. Any new XCUITest belongs to a declared `[[flows]]` entry.
