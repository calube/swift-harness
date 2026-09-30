# Testing playbook

How tests are written, placed, and judged in a swift-harness app. It's for anyone adding a test: a new engineer or an agent. The code rules (concurrency, architecture, clients, errors, logging) live in [standards.md](standards.md); this file owns everything about tests.

Every rule here names what enforces it:

- A `swiftgate` command and rule id: `swiftgate lint`, `testlint`, `arch`, `impact`, `coverage`, `check`, `test`, `prove`, `stress`, `reach`, `mutate`, `snapshots record`, `judge`, `stats`. Every rule id is listed in [standards.md § Rule id index](standards.md#rule-id-index).
- `review`: human or review-agent judgment. No tool can see it.

Waivers use the same-line syntax from [standards.md § Escape hatches](standards.md#escape-hatches): `// swiftgate:allow <rule-id> — <reason>`. A bare allow is itself a gating finding, and every allow is counted in the run report.

## 1. Tiers

| Tier | What runs | Runner | Budget | Why it's deterministic |
|---|---|---|---|---|
| T0 static | `swift format`, `swiftgate lint` (determinism bans in Core: `Date()`, `UUID()`, `Task.sleep`, `asyncAfter`, `.random`), `swiftgate arch`, `swiftgate testlint`, `swiftgate impact` | `swiftgate` | < 5s | No IO. |
| T1 host | `TestStore` tests (exhaustive), client tests, engine rule and replay tests | `swift test` on the affected packages | < 60s | Injected dependencies, `TestClock`/`ImmediateClock`, `withMainSerialExecutor` only inside `.serialized` suites. |
| T2 simulator | Snapshot tests, view and integration tests | `xcodebuild test` on a cloned simulator | minutes | Pinned device and OS, no network, dependency overrides. |
| T3 flow | A thin XCUITest smoke test per critical flow | `xcodebuild test` on a cloned simulator | minutes | Launch-argument scenario injection. |

`swiftgate check --tier` composes the tiers:

| `--tier` | Runs |
|---|---|
| `fast` | T0, plus T1 on the affected packages |
| `push` | T0, T1 on every Core package, T2, `impact`, `coverage`, T1 presence per module |
| `ready` | `push`, plus T3, `stress`, `prove`, per-test reach, and `mutate` on new or changed code |

Pick the lowest tier that can see the behavior. If a behavior can only be reached from the simulator, the logic is probably in the wrong module: move it into a Core or Client module and test it at T1.

## 2. How to name a test

Every Swift Testing test gets a display name in this shape:

```swift
@Test("<behavior> — catches <regression>")
```

- **Behavior:** what the code does, in words a user or caller would recognise.
- **Regression:** the bug this test turns red on, stated as its symptom.

```swift
// Good: the behavior, and the symptom a user would see if it broke.
@Test("a failed fact request stops loading and logs an error — catches a stuck spinner and a silent failure")

// Bad: no display name. `test.unnamed` fails the gate.
@Test func factFailure() async { … }

// Bad: names exist, but the regression is vague. The judge scores this low.
@Test("fact works — catches bugs")
```

XCTest methods (XCUITests) can't carry a display name. Put the regression in a `///` doc comment on the method instead, the way `UITests/CounterFlowUITests.swift` does.

If you can't write the "catches" half, the test probably doesn't protect anything. Delete it or find the regression it guards.

**Enforced by:** `swiftgate testlint` rule `test.unnamed` (missing display name); `swiftgate judge` question `judge.name-specificity` ("how specific is the regression name"); review.

## 3. Rules

Each rule has the same shape as the standards: **Do** · **Tell** (how you see it broke) · **Enforced by** · **Source** (upstream doc, or the incident behind it).

**P1. Every test names the regression it catches.**
- **Do:** name every test with section 2's convention. The regression is a user-visible or caller-visible symptom.
- **Tell:** a `@Test` with no string; a "catches" clause that restates the behavior ("catches increment not incrementing") or says nothing ("catches bugs").
- **Enforced by:** `testlint` `test.unnamed`; `judge` (advisory; gates at `ready` only past `block_threshold`); review · **Source:** incident: none yet.

**P2. A new test fails red before it passes green.**
- **Do:** write the test first and watch it fail on an **assertion**, not on a compile error or a missing import. Then write the code.
- **Tell:** a test that passes with the source change reverted.
- **Enforced by:** `swiftgate prove` (also in `check --tier ready`): runs each new or changed host test on the change, then in a scratch git worktree that restores production source to the merge base while tests, manifests and resources keep the change. It retries a test that only stops compiling at each `--proof-base` ancestor, such as a surface commit (`build proof-bases`). Rules `prove.not-proven` (passes with the source reverted), `prove.compile-only` (only stops compiling), `prove.crashed`, `prove.fails-at-head` (fails on the change itself). Simulator tests aren't proven yet · **Source:** incident: interview trial run 2.

**P3. Verdicts come from evidence, not exit codes.**
- **Do:** trust the gate's reading of the test results: more than 0 tests executed, no unaccounted skips. Never pass `-retry-tests-on-failure`.
- **Tell:** a green run with 0 tests executed (a filter that matched nothing); a retry flag in a script. A retried pass hides a flake.
- **Enforced by:** `swiftgate test` / `check` read the xUnit reports (T1) and the xcresult (T2, T3) · **Source:** incident: none yet.

**P4. Snapshots never record during a test run.**
- **Do:** leave `record:` out, or set it to `.never`. Re-record only through `swiftgate snapshots record` on the pinned simulator from `.swiftgate.toml`, so reference changes show up in the diff.
- **Tell:** `record: .all`, `.missing` or `.failed` in a test; a new `__Snapshots__/*.png` that nobody reviewed. The library default, `.missing`, silently writes a new reference and **passes**.
- **Enforced by:** `lint` `snap.record-mode` (any `record:` other than `.never` or `nil` is RED); the gate runs every tier with `SNAPSHOT_TESTING_RECORD=never` (the SwiftPM adapter sets it; `test --tier t2|t3` sets `TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never` for `xcodebuild`) so a missing reference fails · **Source:** [swift-snapshot-testing record modes](https://github.com/pointfreeco/swift-snapshot-testing). Incident: none yet.

**P5. `TestStore` is exhaustive by default.**
- **Do:** assert every state change in `send`'s and `receive`'s trailing closure. If a test must be non-exhaustive, justify it on the same line.
- **Tell:** `store.exhaustivity = .off` or `withExhaustivity(.off)` with no reason.
- **Enforced by:** `testlint` `test.non-exhaustive-store` (waive with `// swiftgate:allow test.non-exhaustive-store — <reason>`) · **Source:** [TCA testing](https://pointfreeco.github.io/swift-composable-architecture/main/documentation/composablearchitecture/testingtca). Incident: none yet.

**P6. `TestClock`-driven tests run in a `.serialized` suite, inside `withMainSerialExecutor`.**
- **Do:** when a test advances a `TestClock` and expects work to have happened in between, put the suite under `@Suite(.serialized, .timeLimit(.minutes(1)))` and wrap the test body in `withMainSerialExecutor { … }`. Keep TestStore tests that don't touch a clock out of those suites so they stay parallel.
- **Tell:** a test that calls `clock.advance` outside `withMainSerialExecutor`; `withMainSerialExecutor` in a suite without `.serialized`; a suite that passes alone and hangs when the whole package runs.
- **Enforced by:** `testlint` `test.testclock-serialized` (a Swift Testing test that uses `TestClock` or `withMainSerialExecutor` with no enclosing `@Suite(.serialized …)`; XCTest is exempt because it runs a class's tests one at a time); review for the `withMainSerialExecutor` wrap and `.timeLimit` · **Source:** `withMainSerialExecutor` sets a process-global executor hook, and its docs only cover XCTest. Swift Testing runs tests in parallel by default, so an unserialized suite lets one test swap the hook while another runs. **Incident:** building the sample app, the `APIClientLiveTests` retry tests hung under load until the suite was marked `.serialized` and each test wrapped in `withMainSerialExecutor`. `.timeLimit` turns any future hang into a failure instead of a stuck run.

**P7. No real time or swallowed errors in tests.**
- **Do:** drive time with `TestClock` or `ImmediateClock`. Let errors propagate (`async throws` tests) or record them with `Issue.record`.
- **Tell:** `Task.sleep` or `usleep` in a test; `try?` or an empty `catch` in a test body.
- **Enforced by:** `testlint` `test.sleep`, `test.swallowed-error`; Core code is covered by `lint` `det.*` ([standards.md § 3](standards.md#3-dependencies-and-clients), D1) · **Source:** incident: none yet.

**P8. Stress new and changed tests before ready.**
- **Do:** expect new or changed host tests to run 10 times at the `ready` tier. Any failure is RED. `stress` runs N separate `swift test --parallel` processes over the selected tests. It does not shuffle: `swift test` on Swift 6.2 has no shuffle or repeat option. What varies between runs is scheduling: Swift Testing runs the tests concurrently and XCTest spreads them over worker processes.
- **Tell:** a test that depends on shared mutable state, wall time, or another test running first or concurrently. A dependency on declaration order alone can survive `stress`; review looks for it.
- **Enforced by:** `swiftgate stress --n 10` (also in `check --tier ready`) rule `stress.failed` · **Source:** incident: none yet.

**P9. A changed Core, Client or Live file comes with a test change in the same module.**
- **Do:** change `<Module>Tests` in the same commit range, or file an exemption with a reason in `.harness/impact-exemptions.json`:
  ```json
  { "schema": 1, "exemptions": [ { "module": "GameEngine", "reason": "renamed a private helper" } ] }
  ```
  An entry names exactly one of `module` or `path`, and a reason. A file whose tokens match the merge base (only whitespace and comments changed, as after `swift format`) needs neither. A file that uses `#line`, `#column` or `#sourceLocation`, or doesn't parse, always counts as changed.
- **Tell:** a logic change with no test diff. UI-flow (T3) test changes don't count.
- **Enforced by:** `swiftgate impact` (compares against the merge base with `--base`, default `origin/main`) rule `impact.untested-change` · **Source:** incident: none yet.

**P10. Every engine module has a replay test.**
- **Do:** seed plus input log gives an identical final state across runs. Pin the RNG algorithm with a reference-sequence test so a change to it can't silently invalidate recorded replays.
- **Tell:** an `engine` module in `.swiftgate.toml` with no replay test; two replays that disagree.
- **Enforced by:** `arch` `arch.engine-replay-test`: some test in a target that depends on the engine has "replay" in its function name or in its display name before the `— catches` clause. A replay mentioned only in the catches clause, such as an RNG or reset test guarding recorded replays, doesn't count. The heuristic reads names, so review still checks that the test replays a seed and input log; `det.*` and [standards.md § 8](standards.md#8-engine-modules) (G1) cover the engine code itself · **Source:** incident: none yet.

**P11. T3 is a closed list of flows.**
- **Do:** declare each end-to-end flow as a `[[flows]]` entry with a reason. Name the XCUITest class or method (after `test`) starting with the flow name; matching ignores case and punctuation.
- **Tell:** an XCUITest whose class and method match no flow; more flows than `pyramid.max_flows`.
- **Enforced by:** `testlint` `test.xcuitest-unlisted-flow`; `test --tier t3` (and `check --tier ready`) judges the UI tests that actually ran: `t3.unmapped-flow` (a test matching no flow), `t3.flow-untested` (a flow no test covered), `t3.max-flows` (more UI tests than `pyramid.max_flows`). Loading `.swiftgate.toml` also rejects more `[[flows]]` entries than `max_flows` · **Source:** incident: none yet.

**P12. A fixture that hangs on purpose ends by itself.**
- **Do:** give any script or source a test writes out that loops or waits on purpose its own bound: a `Date` or `DispatchTime` deadline, `timeout <n>`, `alarm(`, or an exit in the loop.
- **Tell:** a string literal in a test holding a constant-true loop (`while true`, `while :`, `while True:`, `for (;;)`, `repeat … while true`) with no `break`, `return` or `exit` in its body, or `sleep infinity`, `RunLoop…run()`, `dispatchMain()` or `pause()`, and no deadline anywhere in the literal.
- **Enforced by:** `testlint` `test.hang-without-deadline` · **Source:** incident: prove and mutate run tests against reverted code, and the orphan test's `while true {}` mutant spun on after every such run until it gained a 90 s deadline.

## 4. Pyramid enforcement

Raw tier counts are easy to game, so the gate checks where tests live and what they reach.

| Rule | How it's detected | Enforced by |
|---|---|---|
| Every XCUITest maps to a `[[flows]]` entry | test and class names vs. config | `testlint` `test.xcuitest-unlisted-flow` |
| At most `max_flows` flows, and at most `max_flows` UI tests | config; the UI tests a T3 run executed | config validation (`swiftgate.config`); `test --tier t3` rule `t3.max-flows` |
| A T2 test that renders no view or snapshot and imports only Core/Client modules belongs at T1 | SwiftSyntax import and call scan | `testlint` `test.misplaced-t2` |
| Every Core, Client and Live module has at least one T1 test | module graph vs. discovered tests | `swiftgate coverage` / `check --tier push` rule `coverage.no-t1-tests` |
| At least `diff_coverage_min` of changed Core/Client/Live lines are covered by T1 alone | `swift test --enable-code-coverage` → llvm-cov JSON ∩ diff | `swiftgate coverage` |
| Tier runtimes stay within budget; p95 trend | run history in `.harness/runs/history.jsonl` | `swiftgate stats` |

Diff coverage from T1 alone is what keeps the pyramid honest: if a line is reachable only from the simulator, its logic is in the wrong module.

## 5. Useless-test detection

Three layers, cheapest first. Each check lives at the lowest tier where it's reliable.

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
| `test.duplicate` | Same normalized body as another test |
| `test.unnamed` | `@Test` without a display name |
| `test.non-exhaustive-store` | Non-exhaustive `TestStore` without a same-line justification |
| `test.xcuitest-unlisted-flow` | XCUITest outside `[[flows]]` |
| `test.misplaced-t2` | T2 test that should be T1 |
| `test.testclock-serialized` | A Swift Testing test using `TestClock` or `withMainSerialExecutor` outside a `.serialized` suite (P6) |
| `test.hang-without-deadline` | A string literal that waits forever with no deadline (P12) |

Run it on a path relative to the repository root, e.g. `swiftgate testlint Packages/CounterFeature/Tests` in an app repository. With no argument it checks everything.

### 5.2 Behavioral (push and ready)

- **`prove`:** each new or changed host test fails on an assertion with the source change reverted (P2).
- **`mutate` (`swiftgate mutate`, and in `check --tier ready`):** mutation testing on **changed** Core/Client/Live lines, re-running the affected T1 tests. Operators: negate a conditional, shift a relational boundary (`<` ↔ `<=`), return a default, remove a call, remove an effect or `send`. Any surviving mutant is RED `mutate.survived` at `ready`, unless the line carries `// swiftgate:equivalent-mutant — <reason>`; a mutant that doesn't compile is `mutate.unviable` and left out of the kill rate. Each mutant builds and tests in its own scratch worktree, in parallel workers: seconds for a small package, minutes for TCA packages. Workers default to min(cores − 1, ceil(mutants / 2), 4), since each pays a cold build per package; set `[mutation] max_workers` (or `--jobs`) to change it. Each worker compiles and runs tests with cores ÷ workers jobs, and mutant builds carry no debug information, so no `dsymutil` runs. Mutate seeds each worker's tree with a clone of the package's `.build` (module cache dropped), which saves the dependency fetch but not the compile: SwiftPM rebuilds for the tree's new paths. Capped at `[mutation] max_mutants` (default 30) with sampling beyond; skipped while T1 is RED; never runs in the Stop hook. `review-input` also runs it, so reviewers see surviving mutants.
- **Per-test reach (`swiftgate reach`, and in `check --tier ready`):** each new or changed host test runs alone with coverage. Zero production lines covered in the module it targets (`<Module>` for `<Module>Tests`, otherwise its local production dependencies) is RED `reach.no-production-lines`; failing when run alone is RED `reach.fails-alone`.

### 5.3 Judgment

Some slop only a reader sees: vacuous or restated regression names, tests coupled to implementation details, over-mocking, the wrong abstraction level. The `swift-test-gate` skill carries a rubric for these, and review agents apply it.

### 5.4 Judge seam: `swiftgate judge`

A `Judge` protocol takes typed questions and returns calibrated probabilities, never free-form verdicts.

| Question | Answer type |
|---|---|
| Would this test fail if the behavior it names were broken? | binary → p |
| Which tier does this test belong in (T1/T2/T3)? | choice → p per option |
| How specific is the regression name (vague / partial / specific)? | score → level + p |
| Does it assert implementation details rather than behavior? | binary → p |

- **In:** test source, its diff, a versioned question set. **Out:** findings with question, answer, probability, any rationale, and the deciding backend.
- **Policy is thresholds:** on a blocking question (rows 1, 4), p ≥ `block_threshold` may block at `ready`; from `advisory_threshold` up is advisory; the gate drops the rest. Below `ready`, the judge never turns a run RED.
- **Cache:** keyed by test, diff, questions as sent, backend and model.
- **Calibration:** `gate/Fixtures/judge/` holds labeled good and useless tests plus 1 recording per backend. `swiftgate self-test --judge` scores each offline and fails if per-question precision or recall drops; `--judge-backend <backend> --record` re-records it live.
- **Commands:** `swiftgate judge [--ready]` asks about new and changed host tests; `check --tier ready` runs it. The commit hook asks advisory comment questions. `judge ask --input <file>` asks any question set and prints JSON with no policy. A backend failure is a non-gating `judge.not-run` note.
- **Opt-in:** off by default (`backend = "none"`). A remote backend sends test source off the machine, so each repository opts in and sets both thresholds.

| `[judge] backend` | `claude` | `jev` (TypeSafe's Jev, over HTTP) |
|---|---|---|
| Model | `model`, default `sonnet` | pinned `jev-1.13.0`; config refuses an alias such as `jev-latest` |
| Egress | the `claude` CLI | `send_to = "api.typesafe.ai"` required |
| Key | none in swiftgate | `TYPESAFE_API_KEY` in the environment; config refuses a key |
| Question set | `test-quality@1` | `test-quality@2-jev`: narrower sub-questions, scored on `@1`'s labels |
| Recording | `recording.json` | `recording-jev.json` |
| `judge bench` arm | `claude:claude-sonnet-5-5` | `jev:jev-1.13.0#test-quality@2-jev`; `cascade:jev-1.13.0,claude-sonnet-5-5` for both |

- **Jev blocks, Claude settles:** a Jev answer at or above `block_threshold` on a blocking question blocks `ready`, with no calibration step. Claude writes the reason; if it can't, the block keeps the template reason and `failureScenario` says why. When Jev's p falls in the uncertain band, Claude answers in `@1`'s words instead; if Claude fails, Jev's answer stays advisory.
- **Benchmark:** `judge bench` scores each `--backend` arm; `judge bench-render` prints the comparison. Before setting Jev's thresholds, run the benchmark first; its summary lists the bands.

## 6. Library notes for tests

Pins and hazards are in [standards.md § 0](standards.md#library-pins). The ones that bite in tests:

- **`TestStore` is `@MainActor`.** Mark the suite `@MainActor`. Build the store inside each test; don't share one across tests.
- **Exhaustivity** is `store.exhaustivity = .on` / `.off(...)`. Keep it on (P5).
- **`@DependencyClient` test values fail loudly.** `static let testValue = Self()` makes every endpoint unimplemented, so a test that forgets to override one fails instead of passing on a silent default. Override only the endpoints the test exercises, in `withDependencies:`.
- **Clocks:** `TestClock` when the test controls time step by step; `ImmediateClock` when time only has to pass. Both from swift-clocks.
- **`withMainSerialExecutor`** (swift-concurrency-extras) is process-global. Only use it inside a `.serialized` suite (P6).
- **Snapshots:** record modes are `.all`, `.failed`, `.missing`, `.never`; the default `.missing` records silently (P4). Use the `record:` parameter, `withSnapshotTesting`, or the `.snapshots(record:)` trait. The `isRecording` and `diffTool` globals are deprecated and banned (`tca.banned-api` covers them; see [standards.md § 2](standards.md#2-architecture), A6).
- **Structural diffs:** `expectNoDifference` from swift-custom-dump; prefer the `.customDump` snapshot strategy over `.dump`.
- **Headless `xcodebuild`** needs `-skipMacroValidation`; `swiftgate` passes it for T2 and T3.

## 7. Worked examples

All from the swift-harness repository's sample app, `examples/SampleApp`, which the plugin doesn't
ship. Paths are relative to that folder.

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
- `@MainActor` suite, store built inside the test, exhaustive by default (P5). An extra state change or an unreceived action fails the test.
- Only the two endpoints the test exercises are overridden; everything else stays unimplemented and would fail loudly.
- The log assertion checks the whole record, including the privacy tag, so a log that loses its category or leaks the count as private data fails. The recorder replaces `emit`, following [standards.md § 5](standards.md#5-observability) (O1).
- No clock is involved, so this suite stays parallel (P6 doesn't apply).

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
- The backoff is asserted at its edges: nothing at 999ms, a retry at 1s. An off-by-one in the delay, or a retry with no delay at all, fails. This is also the kind of test that kills `<` ↔ `<=` mutants (`mutate`).
- The comment above the suite is a kept *why*: it explains a footgun a reader can't recover from the code.
- `.serialized` plus `withMainSerialExecutor` is the P6 incident fix; `.timeLimit` turns a regression of it into a failure rather than a hang.
- No real sleeps (`test.sleep`); the clock is injected.

### 7.3 Client Live test with a fake transport (T1)

Same file. `APIClientLive` is tested against a scripted `HTTPClient`, not the network:

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
- The response body is **captured from the real API**, not hand-written. The capture command is recorded next to it in `Tests/APIClientLiveTests/Fixtures/README.md`. A hand-authored fixture only proves the decoder agrees with its author.
- It asserts both directions of the boundary: what the client decodes, and what it sent (URL, `Accept` header). Asserting only the decoded text would pass even if the request went to the wrong endpoint.
- The fake records calls but the assertions check the client's behavior, not values the test configured on the fake (`test.asserts-own-double`).
- `clientErrorNotRetried` in the same suite shows the negative case: a 404 throws `HTTPError.unacceptableStatus(404)` and exactly one request is sent.

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
- `GameEngine` is declared `kind = "engine"` in `.swiftgate.toml`, so P10 requires the replay test.
- Replay equality alone can't tell a deterministic engine from one that ignores its RNG entirely. The second test closes that gap, and the reference-sequence test pins the RNG so old recorded logs stay valid.
- The input log crosses a `.reset`, so state that survives reset is part of what's replayed.
- `first == second` compares two separate runs, so it isn't a `test.tautology`.

### 7.5 Snapshot test with recording off (T2)

`Packages/CounterFeature/Tests/CounterUISnapshotTests/CounterViewSnapshotTests.swift`, reference image in `__Snapshots__/CounterViewSnapshotTests/counterWithFact.1.png`.

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
- No `record:` argument, so `snap.record-mode` is clean, and the mode comes from the environment. The gate runs it with recording off; until `swiftgate test --tier t2` lands, the manual equivalent from `Packages/CounterFeature` is:
  ```sh
  TEST_RUNNER_SNAPSHOT_TESTING_RECORD=never xcodebuild test -scheme CounterFeature-Package \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' -skipMacroValidation
  ```
  `xcodebuild` forwards `TEST_RUNNER_`-prefixed variables to the test process without the prefix. If the PNG is missing, this fails instead of recording one.
- Device, OS (`[simulator]` in `.swiftgate.toml`), layout, and color scheme are all fixed, so the image only changes when the view does.
- It imports SwiftUI and SnapshotTesting and renders a view, so it's correctly at T2 (`test.misplaced-t2` stays quiet). The behavior behind the view is tested at T1 in 7.1.

### 7.6 XCUITest mapped to a flow (T3)

`UITests/CounterFlowUITests.swift`, flow declared in `.swiftgate.toml`:

```toml
[[flows]]
name = "counter"
reason = "the one end-to-end path: launch, count, fetch a fact through the live API client"
```

```swift
final class CounterFlowUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  /// Regression: the counter buttons stop updating the on-screen value (store not wired to the view).
  @MainActor
  func testIncrementAndDecrementUpdateTheDisplayedCount() {
    let app = XCUIApplication()
    app.launch()
    let value = app.staticTexts["counter.value"]
    XCTAssertTrue(value.waitForExistence(timeout: 10))
    XCTAssertEqual(value.label, "0")
    app.buttons["counter.increment"].tap()
    app.buttons["counter.increment"].tap()
    XCTAssertEqual(value.label, "2")
    app.buttons["counter.decrement"].tap()
    XCTAssertEqual(value.label, "1")
  }
}
```

Why it passes the gate:
- The class name starts with `Counter`, which matches flow `counter`, so `test.xcuitest-unlisted-flow` is clean. A new XCUITest for an undeclared flow fails T0 before any simulator boots.
- It checks one thing only T3 can see: the store is wired to the real view in the real app. The counting logic itself is covered at T1 (7.1). Don't copy T1 cases into T3.
- It finds elements by accessibility identifier (`counter.value`, `counter.increment`), which the view must carry anyway ([standards.md § 7](standards.md#7-accessibility), X1).
- `waitForExistence` with a timeout, never a sleep.

## 8. Before you push

1. Every new `@Test` has a `"<behavior> — catches <regression>"` name, and you saw it fail on an assertion first.
2. `swiftgate testlint` and `swiftgate lint` are green on your changes.
3. `swiftgate impact --base <your base branch>` is green, or you filed an exemption with a reason.
4. `swiftgate coverage` meets `diff_coverage_min` from T1 alone.
5. No snapshot reference changed unless you re-recorded it on purpose on the pinned simulator, and the new PNG is in your diff.
6. Any test that advances a `TestClock` is in a `.serialized` suite, inside `withMainSerialExecutor`.
7. Any new XCUITest belongs to a declared `[[flows]]` entry.
