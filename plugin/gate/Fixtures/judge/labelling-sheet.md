# Test-quality labelling sheet

When every answer is in, turn the sheet into `labels.json` from the repository root with:

```sh
node tests/judge_labelling_sheet.mjs apply
```

You are labelling blind: each case shows only a test, the production change it covers, and
the tier the test lives in today, exactly as the judge sees them. Case numbers and keys say
nothing about the answer, and the order is arbitrary.

How to fill it in:

- The subject of every case is a Swift test function from an iOS app built with The Composable Architecture, and the production code change it covers.
- For each case, write one option after each `Answer <question>:` line, exactly as listed
  (`yes`, `no`, `T1`, `T2`, `T3`, `vague`, `partial`, `specific`).
- Leave an answer empty to skip that question for that case. A case with every answer
  empty is skipped entirely.
- Answer from the text shown only. Don't open the case directories: their names and the
  existing labels would unblind you.
- Don't edit anything outside the answer lines; the `key` on each case heading is how the
  answers find their case.

The command records every answered case with `labeller: "person"` and refuses the whole sheet
if any answer isn't one of its question's options.

## Case 1 · key 02bc0469

The subject currently lives in T1.

Test:

```swift
@Test("the fact button loads and shows a fact — catches the loading state never resolving")
func factLoads() async {
  let calls = LockIsolated(0)
  let store = TestStore(initialState: CounterFeature.State()) {
    CounterFeature()
  } withDependencies: {
    $0.apiClient.randomFact = {
      calls.withValue { $0 += 1 }
      return Fact(text: "Cats have five toes on their front paws.")
    }
  }

  await store.send(.factButtonTapped) { $0.isLoadingFact = true }
  await store.receive(\.factResponse) {
    $0.isLoadingFact = false
    $0.fact = "Cats have five toes on their front paws."
  }
  #expect(calls.value == 1)
}
```

Change:

```diff
       case .factButtonTapped:
-        return .none
+        state.isLoadingFact = true
+        return .run { [count = state.count, apiClient, log] send in
+          do {
+            await send(.factResponse(try await apiClient.randomFact().text))
+          } catch {
+            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
+            await send(.factFailed)
+          }
+        }
+
+      case .factResponse(let fact):
+        state.isLoadingFact = false
+        state.fact = fact
+        return .none
+
+      case .factFailed:
+        state.isLoadingFact = false
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 2 · key 04c93fbb

The subject currently lives in T1.

Test:

```swift
@Test("a human move is answered by one computer move — catches the computer skipping its turn")
func computerAnswersHumanMove() {
  let start = GameState(seed: 1)
  let state = GameEngine.step(start, .humanPlaced(4))

  var expectedRNG = start.rng
  _ = expectedRNG.next()
  #expect(state.rng == expectedRNG)
}
```

Change:

```diff
+    case .humanPlaced(let cell):
+      guard next.outcome == .inProgress, next.board.indices.contains(cell), next.board[cell] == nil
+      else { return state }
+      next.board[cell] = .x
+      next.outcome = GameState.outcome(of: next.board)
+      guard next.outcome == .inProgress else { return next }
+      let empty = next.board.indices.filter { next.board[$0] == nil }
+      next.board[empty[next.rng.nextIndex(below: empty.count)]] = .o
+      next.outcome = GameState.outcome(of: next.board)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 3 · key 074c4ab2

The subject currently lives in T2.

Test:

```swift
@Test(
  "the minimum level gates lower severities only — catches debug logs shipping in release or errors being dropped"
)
func minimumLevelGate() {
  let client = LogClient.osLog(subsystem: "test", minimumLevel: .notice)
  #expect(client.isEnabled(.info, "Any") == false)
  #expect(client.isEnabled(.notice, "Any"))
  #expect(client.isEnabled(.fault, "Any"))
}
```

Change:

```diff
+  static func severity(of level: LogLevel) -> Int {
+    switch level {
+    case .debug: 0
+    case .info: 1
+    case .notice: 2
+    case .error: 3
+    case .fault: 4
+    }
+  }
@@
+    let minimum = OSLogRendering.severity(of: minimumLevel)
+    return Self(
+      isEnabled: { level, _ in OSLogRendering.severity(of: level) >= minimum },
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 4 · key 08c9a7d9

The subject currently lives in T2.

Test:

```swift
@Test("log levels map to OSLog types — catches errors being filed as debug noise in Console")
func levelMapping() {
  #expect(OSLogRendering.type(for: .debug) == .debug)
  #expect(OSLogRendering.type(for: .info) == .info)
  #expect(OSLogRendering.type(for: .notice) == .default)
  #expect(OSLogRendering.type(for: .error) == .error)
  #expect(OSLogRendering.type(for: .fault) == .fault)
}
```

Change:

```diff
+  static func type(for level: LogLevel) -> OSLogType {
+    switch level {
+    case .debug: .debug
+    case .info: .info
+    case .notice: .default
+    case .error: .error
+    case .fault: .fault
+    }
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 5 · key 0b12c751

The subject currently lives in T1.

Test:

```swift
@Test("2xx responses return the body — catches successful responses being treated as failures")
func successReturnsBody() async throws {
  let response = HTTPURLResponse(
    url: Self.url, statusCode: 204, httpVersion: nil, headerFields: nil)!

  _ = try await Self.client(status: 204, body: Data("ok".utf8)).data(
    for: URLRequest(url: Self.url))

  #expect(response.statusCode == 204)
}
```

Change:

```diff
+extension HTTPClient {
+  public func data(for request: URLRequest) async throws -> Data {
+    let (data, response) = try await send(request)
+    guard (200..<300).contains(response.statusCode) else {
+      throw HTTPError.unacceptableStatus(response.statusCode)
+    }
+    return data
+  }
+}
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 6 · key 0efb9b6a

The subject currently lives in T2.

Test:

```swift
@Test("fact failure — catches failures")
func factFailure() async {
  let records = LockIsolated<[LogRecord]>([])
  let store = TestStore(initialState: CounterFeature.State(count: 2)) {
    CounterFeature()
  } withDependencies: {
    $0.apiClient.randomFact = { throw FactUnavailable() }
    $0.logClient.emit = { record in records.withValue { $0.append(record) } }
  }

  await store.send(.factButtonTapped) { $0.isLoadingFact = true }
  await store.receive(\.factFailed) { $0.isLoadingFact = false }
  #expect(records.value.first?.message == "fact request failed")
  #expect(records.value.first?.category == "Counter")
}
```

Change:

```diff
       case .factButtonTapped:
-        return .none
+        state.isLoadingFact = true
+        return .run { [count = state.count, apiClient, log] send in
+          do {
+            await send(.factResponse(try await apiClient.randomFact().text))
+          } catch {
+            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
+            await send(.factFailed)
+          }
+        }
+
+      case .factResponse(let fact):
+        state.isLoadingFact = false
+        state.fact = fact
+        return .none
+
+      case .factFailed:
+        state.isLoadingFact = false
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 7 · key 158edf38

The subject currently lives in T2.

Test:

```swift
@Test("reset and the generator — catches reset problems")
func resetGenerator() {
  let played = GameEngine.step(GameState(seed: 9), .humanPlaced(0))
  let reset = GameEngine.step(played, .reset)
  #expect(reset.board.allSatisfy { $0 == nil })
  #expect(reset.rng != GameState(seed: 9).rng)
}
```

Change:

```diff
     case .reset:
-      next = GameState(seed: 0)
+      next.board = Array(repeating: nil, count: GameState.cellCount)
+      next.outcome = .inProgress
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 8 · key 18be36b6

The subject currently lives in T1.

Test:

```swift
@Test(
  "the test value fails an unstubbed call instead of answering — catches a feature test passing on a made-up fact it never stubbed"
)
func unstubbedCallFails() async {
  let client = APIClient.testValue

  await withKnownIssue {
    await #expect(throws: (any Error).self) { try await client.randomFact() }
  } matching: { issue in
    issue.description.contains("randomFact")
  }
}
```

Change:

```diff
+@DependencyClient
+public struct APIClient: Sendable {
+  public var randomFact: @Sendable () async throws -> Fact
+}
+
+extension APIClient: TestDependencyKey {
+  public static let testValue = APIClient()
+}
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 9 · key 1d67c3ab

The subject currently lives in T1.

Test:

```swift
@Test("an unknown status string decodes as .unknown — catches the whole order list failing to load when the server adds a status")
func unknownStatus() throws {
  let order = try JSONDecoder().decode(Order.self, from: Data(#"{"status":"refunded_partial"}"#.utf8))
  #expect(order.status == .unknown)
}
```

Change:

```diff
+  public init(from decoder: Decoder) throws {
+    let raw = try decoder.singleValueContainer().decode(String.self)
+    self = Status(rawValue: raw) ?? .unknown
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 10 · key 2489d605

The subject currently lives in T1.

Test:

```swift
@Test("adding the same item twice increments quantity — catches duplicate cart lines")
func addTwice() {
  var cart = Cart()
  cart.add(Item(id: 1))
  cart.add(Item(id: 1))
  #expect(cart._storageForTesting.count == 1)
  #expect(cart._storageForTesting.capacity >= 1)
  #expect(cart._mutationCountForTesting == 2)
}
```

Change:

```diff
+  public mutating func add(_ item: Item) {
+    if let index = storage.firstIndex(where: { $0.id == item.id }) { storage[index].quantity += 1 }
+    else { storage.append(item) }
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 11 · key 26e6b308

The subject currently lives in T1.

Test:

```swift
@Test("row renders — catches row rendering issues")
func rowRenders() {
  let view = PriceRow(title: "Coffee", price: "$3")
  assertSnapshot(of: UIHostingController(rootView: view), as: .image(on: .iPhone13))
}
```

Change:

```diff
+  var body: some View {
+    HStack { Text(title); Spacer(); Text(price) }
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 12 · key 32c6c57c

The subject currently lives in T2.

Test:

```swift
@Test("fact response — catches fact display issues")
func factResponse() async {
  let store = TestStore(initialState: CounterFeature.State(isLoadingFact: true)) {
    CounterFeature()
  }

  await store.send(.factResponse("Cats have five toes on their front paws.")) {
    $0.isLoadingFact = false
    $0.fact = "Cats have five toes on their front paws."
  }
}
```

Change:

```diff
       case .factButtonTapped:
-        return .none
+        state.isLoadingFact = true
+        return .run { [count = state.count, apiClient, log] send in
+          do {
+            await send(.factResponse(try await apiClient.randomFact().text))
+          } catch {
+            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
+            await send(.factFailed)
+          }
+        }
+
+      case .factResponse(let fact):
+        state.isLoadingFact = false
+        state.fact = fact
+        return .none
+
+      case .factFailed:
+        state.isLoadingFact = false
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 13 · key 32d0b1be

The subject currently lives in T1.

Test:

```swift
@Test("refresh calls fetchItems exactly once then logs 'refresh done' — catches refresh regressions")
func refreshCallsAPI() async {
  let calls = LockIsolated<[String]>([])
  let model = ItemsModel(api: .init(fetchItems: { calls.withValue { $0.append("fetchItems") }; return [] }), log: { calls.withValue { $0.append($0) } })
  await model.refresh()
  #expect(calls.value == ["fetchItems", "refresh done"])
}
```

Change:

```diff
+  public func refresh() async {
+    items = (try? await api.fetchItems()) ?? items
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 14 · key 3573a785

The subject currently lives in T1.

Test:

```swift
@Test("decrement — catches counter bugs")
func decrementCount() async {
  let store = TestStore(initialState: CounterFeature.State()) { CounterFeature() }
  store.exhaustivity = .off

  await store.send(.decrementButtonTapped)

  #expect(store.state.count == -1)
}
```

Change:

```diff
+      case .decrementButtonTapped:
+        state.count -= 1
+        state.fact = nil
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 15 · key 35efd779

The subject currently lives in T3.

Test:

```swift
@Test(
  "counter with a loaded fact renders unchanged — catches layout regressions in the counter screen"
)
func counterWithFact() {
  let store = Store(
    initialState: CounterFeature.State(
      count: 42, fact: "Cats sleep for around 13 to 14 hours a day.")
  ) {
    CounterFeature()
  }
  assertSnapshot(
    of: UIHostingController(rootView: CounterView(store: store)),
    as: .image(on: .iPhone13, traits: UITraitCollection(userInterfaceStyle: .light))
  )
}
```

Change:

```diff
+      Button("Cat fact") { store.send(.factButtonTapped) }
+        .disabled(store.isLoadingFact)
+        .accessibilityIdentifier("counter.fact")
+
+      if store.isLoadingFact {
+        ProgressView()
+      } else if let fact = store.fact {
+        Text(fact)
+          .multilineTextAlignment(.center)
+          .accessibilityIdentifier("counter.factText")
+      }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 16 · key 3700e7fa

The subject currently lives in T1.

Test:

```swift
@Test("a task due at 23:59 today reads 'Due today', not 'Overdue' — catches tasks flagged overdue hours early")
func dueLateToday() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/New_York")!
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let due = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now)!
  #expect(DueLabel.dueLabel(for: due, now: now, calendar: calendar) == "Due today")
}
```

Change:

```diff
+  public static func dueLabel(for due: Date, now: Date, calendar: Calendar) -> String {
+    calendar.isDate(due, inSameDayAs: now) ? "Due today" : due < now ? "Overdue" : "Upcoming"
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 17 · key 40af9c77

The subject currently lives in T1.

Test:

```swift
@Test("leaving the screen stops polling — catches a background poll draining battery after dismissal")
func stopsPolling() async {
  let clock = TestClock()
  let store = TestStore(initialState: Status.State()) { Status() } withDependencies: { $0.continuousClock = clock }
  await store.send(.onAppear)
  await store.send(.onDisappear)
  await clock.advance(by: .seconds(60))
}
```

Change:

```diff
+  case .onDisappear:
+    return .cancel(id: CancelID.poll)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 18 · key 41e02839

The subject currently lives in T1.

Test:

```swift
@Test("counter screen renders — catches rendering issues")
func counterScreen() {
  let store = Store(
    initialState: CounterFeature.State(count: 42, fact: "Cats sleep for around 13 to 14 hours a day.")
  ) {
    CounterFeature()
  }
  assertSnapshot(
    of: UIHostingController(rootView: CounterView(store: store)),
    as: .image(on: .iPhone13, traits: UITraitCollection(userInterfaceStyle: .light))
  )
}
```

Change:

```diff
+      Button("Cat fact") { store.send(.factButtonTapped) }
+        .disabled(store.isLoadingFact)
+        .accessibilityIdentifier("counter.fact")
+
+      if store.isLoadingFact {
+        ProgressView()
+      } else if let fact = store.fact {
+        Text(fact)
+          .multilineTextAlignment(.center)
+          .accessibilityIdentifier("counter.factText")
+      }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 19 · key 44713ce7

The subject currently lives in T1.

Test:

```swift
@Test("game over — catches regressions")
func gameOver() {
  var finished = GameState(seed: 1)
  finished.board = [.x, .x, .x, .o, .o, nil, nil, nil, nil]
  finished.outcome = .won(.x)
  #expect(GameEngine.step(finished, .humanPlaced(8)) == finished)
}
```

Change:

```diff
+    case .humanPlaced(let cell):
+      guard next.outcome == .inProgress, next.board.indices.contains(cell), next.board[cell] == nil
+      else { return state }
+      next.board[cell] = .x
+      next.outcome = GameState.outcome(of: next.board)
+      guard next.outcome == .inProgress else { return next }
+      let empty = next.board.indices.filter { next.board[$0] == nil }
+      next.board[empty[next.rng.nextIndex(below: empty.count)]] = .o
+      next.outcome = GameState.outcome(of: next.board)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 20 · key 485a060a

The subject currently lives in T1.

Test:

```swift
@Test(
  "an mmdc that can't launch means not on PATH and validates nothing — catches design-lint blocking where mmdc is absent"
)
func launchFailureIsNotOnPath() async {
  let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
    throw .launchFailed(executable: invocation.executable, reason: "not found")
  }

  let outcome = await MermaidValidation.validate(fences: Self.fences, runner: runner)

  #expect(outcome == .notOnPath)
  #expect(runner.invocations.count == 1)
}
```

Change:

```diff
+  private static func isOnPath(runner: any ProcessRunner, timeout: Duration) async -> Bool {
+    do throws(ProcessRunnerError) {
+      _ = try await runner.run(
+        ProcessInvocation(executable: "mmdc", arguments: ["--version"]), timeout: timeout)
+      return true
+    } catch .launchFailed {
+      return false
+    } catch {
+      return true
+    }
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 21 · key 4e227400

The subject currently lives in T1.

Test:

```swift
@Test("toggleFavoriteTapped toggles favorite — catches toggleFavoriteTapped not toggling favorite")
func toggles() async {
  let store = TestStore(initialState: Row.State(id: 1)) { Row() } withDependencies: { $0.api.setFavorite = { _, _ in } }
  await store.send(.toggleFavoriteTapped) { $0.isFavorite = true }
}
```

Change:

```diff
+  case .toggleFavoriteTapped:
+    state.isFavorite.toggle()
+    return .run { [id = state.id, fav = state.isFavorite] _ in try await api.setFavorite(id, fav) }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 22 · key 4fb170cc

The subject currently lives in T1.

Test:

```swift
@Test("replaying seed 42 with the recorded inputs reaches the recorded final state — catches nondeterminism that breaks saved replays")
func replay() throws {
  let log = try InputLog.fixture("level1")
  let final = log.inputs.reduce(Engine.State(seed: 42), Engine.step)
  #expect(final == log.expectedFinalState)
}
```

Change:

```diff
+  public static func step(_ state: State, _ input: Input) -> State {
+    var next = state
+    next.position += input.thrust * state.dt
+    next.rng.advance()
+    return next
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 23 · key 509875df

The subject currently lives in T1.

Test:

```swift
@Test("the seed drives the computer's moves — catches the engine ignoring its injected RNG")
func seedChangesComputerMoves() {
  let first = GameEngine.replay(seed: 3, inputs: [.humanPlaced(4)])
  let second = GameEngine.replay(seed: 3, inputs: [.humanPlaced(4)])
  #expect(first.board == second.board)
}
```

Change:

```diff
+    case .humanPlaced(let cell):
+      guard next.outcome == .inProgress, next.board.indices.contains(cell), next.board[cell] == nil
+      else { return state }
+      next.board[cell] = .x
+      next.outcome = GameState.outcome(of: next.board)
+      guard next.outcome == .inProgress else { return next }
+      let empty = next.board.indices.filter { next.board[$0] == nil }
+      next.board[empty[next.rng.nextIndex(below: empty.count)]] = .o
+      next.outcome = GameState.outcome(of: next.board)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 24 · key 5170df5f

The subject currently lives in T1.

Test:

```swift
@Test(
  "reads the test tree and build results with the Xcode 26.2 subcommands — catches the reader calling a subcommand 26.2 does not have"
)
func invocations() async throws {
  let runner = replaying("fail")

  let contents = try await LiveXcresultReader(runner: runner).read(bundlePath: "/r/T2.xcresult")

  #expect(
    runner.invocations.map { [$0.executable] + $0.arguments } == [
      [
        "/usr/bin/xcrun", "xcresulttool", "get", "test-results", "tests", "--path",
        "/r/T2.xcresult",
      ],
      ["/usr/bin/xcrun", "xcresulttool", "get", "build-results", "--path", "/r/T2.xcresult"],
    ])
  #expect(contents.testResults == (try Fixture.data("Xcresult/fail.tests.json")))
  #expect(contents.buildResults == (try Fixture.data("Xcresult/fail.build-results.json")))
}
```

Change:

```diff
   public func read(bundlePath: String) async throws(XcresultReadError) -> XcresultContents {
-    let tests = try await xcresulttool(["get", "--format", "json", "--path", bundlePath])
+    let tests = try await xcresulttool(["get", "test-results", "tests", "--path", bundlePath])
     guard tests.status.isSuccess else {
       throw .failed(status: tests.status, stderr: Self.firstLine(tests.stderr.text))
     }
-    return XcresultContents(testResults: tests.stdout.bytes, buildResults: nil)
+    let build = try await xcresulttool(["get", "build-results", "--path", bundlePath])
+    return XcresultContents(
+      testResults: tests.stdout.bytes,
+      buildResults: build.status.isSuccess ? build.stdout.bytes : nil
+    )
   }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 25 · key 52f492a4

The subject currently lives in T1.

Test:

```swift
@Test("parse returns something — catches parse failures")
func parses() throws {
  let config = try? Config.parse(Data("{}".utf8))
  #expect(config != nil || config == nil)
}
```

Change:

```diff
+  public static func parse(_ json: Data) throws -> Config {
+    try JSONDecoder().decode(Config.self, from: json)
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 26 · key 5826a5a8

The subject currently lives in T1.

Test:

```swift
@Test("a log call emits level, category, message and tagged attributes — catches lost log fields")
func emitsFullRecord() {
  let records = LockIsolated<[LogRecord]>([])
  var client = LogClient.testValue
  client.emit = { record in records.withValue { $0.append(record) } }

  client.log(
    .error, "fact request failed", category: "Counter",
    [.public("attempt", 3), .private("email", "a@b.c")])

  #expect(
    records.value == [
      LogRecord(
        level: .error,
        category: "Counter",
        message: "fact request failed",
        attributes: [
          LogAttribute(key: "attempt", value: "3", privacy: .public),
          LogAttribute(key: "email", value: "a@b.c", privacy: .private),
        ]
      )
    ]
  )
}
```

Change:

```diff
 extension LogClient {
   public func log(
     _ level: LogLevel,
     _ message: StaticString,
     category: String,
-    _ attributes: [LogAttribute] = []
+    _ attributes: @autoclosure () -> [LogAttribute] = []
   ) {
     guard isEnabled(level, category) else { return }
     emit(
-      LogRecord(level: level, category: category, message: "\(message)", attributes: attributes))
+      LogRecord(level: level, category: category, message: "\(message)", attributes: attributes()))
   }
 }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 27 · key 5a225be3

The subject currently lives in T1.

Test:

```swift
@Test("three retryable failures surface .unavailable — catches the client retrying forever on a dead server")
func givesUpAfterThree() async {
  let attempts = LockIsolated(0)
  let client = APIClient.live(transport: .init { _ in attempts.withValue { $0 += 1 }; throw TransportError.timeout }, clock: ImmediateClock())
  await #expect(throws: APIError.unavailable) { try await client.fetchItems() }
  #expect(attempts.value == 3)
}
```

Change:

```diff
+  for attempt in 0..<3 {
+    do { return try await transport.send(request) }
+    catch let error as TransportError where error.isRetryable {
+      try await clock.sleep(for: .seconds(1 << attempt))
+    }
+  }
+  throw APIError.unavailable
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 28 · key 5b71c2b6

The subject currently lives in T1.

Test:

```swift
@Test("counter controls carry accessibility identifiers — catches UI tests losing their handles")
func identifiers() {
  let store = Store(initialState: CounterFeature.State()) { CounterFeature() }

  let description = String(describing: CounterView(store: store).body)

  #expect(description.contains("counter.increment"))
  #expect(description.contains("counter.decrement"))
}
```

Change:

```diff
+    VStack(spacing: 24) {
+      Text("\(store.count)")
+        .font(.system(size: 64, weight: .bold, design: .rounded))
+        .monospacedDigit()
+        .accessibilityIdentifier("counter.value")
+
+      HStack(spacing: 32) {
+        Button("Decrement", systemImage: "minus") { store.send(.decrementButtonTapped) }
+          .accessibilityIdentifier("counter.decrement")
+        Button("Increment", systemImage: "plus") { store.send(.incrementButtonTapped) }
+          .accessibilityIdentifier("counter.increment")
+      }
+      .labelStyle(.iconOnly)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 29 · key 5f0607a0

The subject currently lives in T1.

Test:

```swift
@Test(
  "emit writes the record to unified logging — catches the live client silently dropping every log line"
)
func emitReachesUnifiedLogging() throws {
  let subsystem = "com.example.SampleApp.tests.\(UUID().uuidString)"
  let store = try OSLogStore(scope: .currentProcessIdentifier)
  let start = store.position(date: Date().addingTimeInterval(-1))

  LogClient.osLog(subsystem: subsystem).emit(
    LogRecord(
      level: .error, category: "Emission", message: "fact request failed",
      attributes: [.public("count", 7)])
  )

  let entries = try store.getEntries(
    at: start, matching: NSPredicate(format: "subsystem == %@", subsystem)
  )
  .compactMap { $0 as? OSLogEntryLog }
  #expect(entries.count == 1)
  let entry = try #require(entries.first)
  #expect(entry.category == "Emission")
  #expect(entry.level == .error)
  #expect(entry.composedMessage.hasPrefix("fact request failed count=7"))
}
```

Change:

```diff
+  public static func osLog(subsystem: String, minimumLevel: LogLevel = .debug) -> Self {
+    let minimum = OSLogRendering.severity(of: minimumLevel)
+    return Self(
+      isEnabled: { level, _ in OSLogRendering.severity(of: level) >= minimum },
+      emit: { record in
+        let segments = OSLogRendering.segments(for: record.attributes)
+        Logger(subsystem: subsystem, category: record.category).log(
+          level: OSLogRendering.type(for: record.level),
+          "\(record.message, privacy: .public) \(segments.publicText, privacy: .public) \(segments.privateText, privacy: .private) \(segments.sensitiveText, privacy: .sensitive)"
+        )
+      }
+    )
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 30 · key 64c1d80d

The subject currently lives in T1.

Test:

```swift
@Test("reset clears the board — catches a board left full after reset")
func resetClearsBoard() {
  let played = GameEngine.step(GameState(seed: 1), .humanPlaced(4))
  let reset = GameEngine.step(played, .reset)
  #expect(reset.rng == played.rng)
}
```

Change:

```diff
     case .reset:
-      next = GameState(seed: 0)
+      next.board = Array(repeating: nil, count: GameState.cellCount)
+      next.outcome = .inProgress
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 31 · key 65ae5f16

The subject currently lives in T1.

Test:

```swift
@Test("the fact request asks for JSON — catches the server answering with an HTML page")
func requestsJSON() async throws {
  let transport = ScriptedTransport([.status(200, try fixture("catfact-fact"))])
  let client = APIClient.live(http: transport.client, clock: TestClock())

  _ = try await client.randomFact()

  #expect(transport.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
}
```

Change:

```diff
     Self(randomFact: {
-      let request = URLRequest(url: baseURL.appending(path: "fact"))
+      var request = URLRequest(url: baseURL.appending(path: "fact"))
+      request.setValue("application/json", forHTTPHeaderField: "Accept")
       let data = try await withRetry(retry, clock: clock) { [request] in
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 32 · key 6afeda06

The subject currently lives in T1.

Test:

```swift
@Test("loadProfile returns the profile — catches loadProfile not returning the profile")
func loadsProfile() async throws {
  let api = APIClient(fetchProfile: { Profile(name: "Ada") })
  let profile = try await api.fetchProfile()
  #expect(profile.name == "Ada")
}
```

Change:

```diff
+  public func loadProfile() async throws -> Profile {
+    let profile = try await api.fetchProfile()
+    return Profile(name: profile.name.trimmingCharacters(in: .whitespaces))
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 33 · key 7139fbea

The subject currently lives in T1.

Test:

```swift
@Test("1999 cents renders $19.99 in en_US — catches prices shown as $1,999.00")
func cents() {
  #expect(PriceFormatter(locale: Locale(identifier: "en_US")).formatted(1999) == "$19.99")
}
```

Change:

```diff
+  public func formatted(_ cents: Int) -> String {
+    let dollars = Decimal(cents) / 100
+    return dollars.formatted(.currency(code: "USD").locale(locale))
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 34 · key 71ef1b73

The subject currently lives in T3.

Test:

```swift
@Test("decrement works — catches bugs")
func decrement() async {
  let store = TestStore(initialState: CounterFeature.State(count: 2)) { CounterFeature() }

  await store.send(.decrementButtonTapped) { $0.count = 1 }
}
```

Change:

```diff
+      case .decrementButtonTapped:
+        state.count -= 1
+        state.fact = nil
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 35 · key 74bbb7c4

The subject currently lives in T1.

Test:

```swift
@Test("disabled levels never build their attributes — catches logging cost paid when disabled")
func disabledLevelSkipsAttributeConstruction() {
  let records = LockIsolated<[LogRecord]>([])
  let client = LogClient(
    isEnabled: { level, _ in level == .error },
    emit: { record in records.withValue { $0.append(record) } }
  )
  var attributeBuilds = 0
  func expensiveAttributes() -> [LogAttribute] {
    attributeBuilds += 1
    return [.public("k", "v")]
  }

  client.log(.debug, "dropped", category: "Test", expensiveAttributes())
  client.log(.error, "kept", category: "Test", expensiveAttributes())

  #expect(attributeBuilds == 1)
  #expect(records.value.map(\.message) == ["kept"])
}
```

Change:

```diff
 extension LogClient {
   public func log(
     _ level: LogLevel,
     _ message: StaticString,
     category: String,
-    _ attributes: [LogAttribute] = []
+    _ attributes: @autoclosure () -> [LogAttribute] = []
   ) {
     guard isEnabled(level, category) else { return }
     emit(
-      LogRecord(level: level, category: category, message: "\(message)", attributes: attributes))
+      LogRecord(level: level, category: category, message: "\(message)", attributes: attributes()))
   }
 }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 36 · key 76726b6b

The subject currently lives in T1.

Test:

```swift
@Test("tapping + twice shows 2 — catches the counter not advancing on tap")
func incrementTwice() async {
  let store = TestStore(initialState: Counter.State()) { Counter() }
  await store.send(.incrementButtonTapped) { $0.count = 1 }
  await store.send(.incrementButtonTapped) { $0.count = 2 }
}
```

Change:

```diff
+  case .incrementButtonTapped:
+    state.count += 1
+    return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 37 · key 793a4d33

The subject currently lives in T1.

Test:

```swift
@Test("draw works — catches draw bugs")
func draw() {
  let board: [Player?] = [.x, .o, .x, .x, .o, .o, .o, .x, .x]
  #expect(GameState.outcome(of: board) == .draw)
}
```

Change:

```diff
+  public static let winningLines: [[Int]] = [
+    [0, 1, 2], [3, 4, 5], [6, 7, 8],
+    [0, 3, 6], [1, 4, 7], [2, 5, 8],
+    [0, 4, 8], [2, 4, 6],
+  ]
+
+  public static func outcome(of board: [Player?]) -> Outcome {
+    for line in winningLines {
+      if let player = board[line[0]], board[line[1]] == player, board[line[2]] == player {
+        return .won(player)
+      }
+    }
+    return board.contains(nil) ? .inProgress : .draw
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 38 · key 7f7ab108

The subject currently lives in T1.

Test:

```swift
@Test(
  "server errors retry with exponential backoff — catches retries hammering the server without delay"
)
func retriesWithBackoff() async throws {
  let transport = ScriptedTransport([
    .status(503), .status(503), .status(200, try fixture("catfact-fact")),
  ])
  let client = APIClient.live(http: transport.client, clock: ImmediateClock())

  _ = try await client.randomFact()

  #expect(transport.requests.count == 3)
}
```

Change:

```diff
+  /// Only failures a later attempt can plausibly fix: transport errors, throttling, and 5xx.
+  func isRetryable(_ error: any Error) -> Bool {
+    switch error {
+    case HTTPError.unacceptableStatus(let status): status == 429 || (500..<600).contains(status)
+    case is URLError: true
+    default: false
+    }
+  }
+
+  func delay(beforeRetry retry: Int) -> Duration {
+    baseDelay * (1 << (retry - 1))
+  }
@@
+    var attempt = 1
+    while true {
+      do {
+        return try await operation()
+      } catch where attempt < policy.maxAttempts && policy.isRetryable(error) {
+        try await clock.sleep(for: policy.delay(beforeRetry: attempt))
+        attempt += 1
+      }
+    }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 39 · key 815fe8b3

The subject currently lives in T1.

Test:

```swift
@Test("an empty response shows the empty state — catches a blank screen when the user has no items")
func emptyResponse() async {
  let store = TestStore(initialState: Items.State()) { Items() }
  await store.send(.itemsResponse(.success([]))) { $0.isEmptyStateVisible = true }
}
```

Change:

```diff
+  case .itemsResponse(.success(let items)):
+    state.items = IdentifiedArray(uniqueElements: items)
+    state.isEmptyStateVisible = items.isEmpty
+    return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 40 · key 888fabd3

The subject currently lives in T1.

Test:

```swift
@Test("a failed fact request logs an error — catches a silent failure")
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
  #expect(records.value.map(\.message) == ["fact request failed"])
}
```

Change:

```diff
       case .factButtonTapped:
-        return .none
+        state.isLoadingFact = true
+        return .run { [count = state.count, apiClient, log] send in
+          do {
+            await send(.factResponse(try await apiClient.randomFact().text))
+          } catch {
+            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
+            await send(.factFailed)
+          }
+        }
+
+      case .factResponse(let fact):
+        state.isLoadingFact = false
+        state.fact = fact
+        return .none
+
+      case .factFailed:
+        state.isLoadingFact = false
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 41 · key 8c9897d7

The subject currently lives in T3.

Test:

```swift
@MainActor
func testIncrementUpdatesTheCount() {
  let app = XCUIApplication()
  app.launch()

  XCTAssertTrue(app.buttons["counter.increment"].waitForExistence(timeout: 10))
  app.buttons["counter.increment"].tap()
  XCTAssertTrue(app.staticTexts["counter.value"].exists)
}
```

Change:

```diff
+    VStack(spacing: 24) {
+      Text("\(store.count)")
+        .font(.system(size: 64, weight: .bold, design: .rounded))
+        .monospacedDigit()
+        .accessibilityIdentifier("counter.value")
+
+      HStack(spacing: 32) {
+        Button("Decrement", systemImage: "minus") { store.send(.decrementButtonTapped) }
+          .accessibilityIdentifier("counter.decrement")
+        Button("Increment", systemImage: "plus") { store.send(.incrementButtonTapped) }
+          .accessibilityIdentifier("counter.increment")
+      }
+      .labelStyle(.iconOnly)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 42 · key 917c6be9

The subject currently lives in T1.

Test:

```swift
@Test("typing two queries within 300ms searches only the last — catches a stale result overwriting the newest query")
func debounced() async {
  let clock = TestClock()
  let store = TestStore(initialState: Search.State()) { Search() } withDependencies: {
    $0.continuousClock = clock
    $0.api.search = { query in [Result(title: query)] }
  }
  await store.send(.queryChanged("sw")) { $0.query = "sw" }
  await store.send(.queryChanged("swift")) { $0.query = "swift" }
  await clock.advance(by: .milliseconds(300))
  await store.receive(\.searchResponse) { $0.results = [Result(title: "swift")] }
}
```

Change:

```diff
+  case .queryChanged(let query):
+    state.query = query
+    return .run { send in
+      try await clock.sleep(for: .milliseconds(300))
+      await send(.searchResponse(try await api.search(query)))
+    }
+    .cancellable(id: CancelID.search, cancelInFlight: true)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 43 · key 91f22ba6

The subject currently lives in T1.

Test:

```swift
@Test("a rejected password shows an alert — catches silent login failures")
func loginFailureShowsAlert() async {
  let store = TestStore(initialState: Login.State(isLoading: true)) { Login() }
  store.exhaustivity = .off
  await store.send(.loginResponse(.failure(.invalidCredentials))) {
    $0.isLoading = false
  }
}
```

Change:

```diff
+  case .loginResponse(.failure(let error)):
+    state.isLoading = false
+    state.alert = AlertState { TextState(error.userMessage) }
+    return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 44 · key 97c1c536

The subject currently lives in T1.

Test:

```swift
@Test("status codes — catches status bugs")
func statusCodes() {
  let codes = [200, 204, 299]
  #expect(codes.allSatisfy { (200..<300).contains($0) })
}
```

Change:

```diff
+extension HTTPClient {
+  public func data(for request: URLRequest) async throws -> Data {
+    let (data, response) = try await send(request)
+    guard (200..<300).contains(response.statusCode) else {
+      throw HTTPError.unacceptableStatus(response.statusCode)
+    }
+    return data
+  }
+}
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 45 · key 9988aa4b

The subject currently lives in T1.

Test:

```swift
@Test("retries wait 1s then 2s — catches a backoff that does not grow between attempts")
func backoffGrows() async throws {
  let clock = SleepRecordingClock()
  let transport = ScriptedTransport([
    .status(503), .status(502), .status(200, try fixture("catfact-fact")),
  ])
  let client = APIClient.live(
    http: transport.client, clock: clock,
    retry: RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1)))

  _ = try await client.randomFact()

  #expect(clock.sleeps == [.seconds(1), .seconds(2)])
}
```

Change:

```diff
+  /// Only failures a later attempt can plausibly fix: transport errors, throttling, and 5xx.
+  func isRetryable(_ error: any Error) -> Bool {
+    switch error {
+    case HTTPError.unacceptableStatus(let status): status == 429 || (500..<600).contains(status)
+    case is URLError: true
+    default: false
+    }
+  }
+
+  func delay(beforeRetry retry: Int) -> Duration {
+    baseDelay * (1 << (retry - 1))
+  }
@@
+    var attempt = 1
+    while true {
+      do {
+        return try await operation()
+      } catch where attempt < policy.maxAttempts && policy.isRetryable(error) {
+        try await clock.sleep(for: policy.delay(beforeRetry: attempt))
+        attempt += 1
+      }
+    }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 46 · key 9af281c0

The subject currently lives in T1.

Test:

```swift
@Test("each row, column and diagonal wins — catches a missing win line")
func everyLineWins() {
  #expect(GameState.winningLines.count == 8)
  #expect(Set(GameState.winningLines.flatMap { $0 }) == Set(0..<9))
}
```

Change:

```diff
+  public static let winningLines: [[Int]] = [
+    [0, 1, 2], [3, 4, 5], [6, 7, 8],
+    [0, 3, 6], [1, 4, 7], [2, 5, 8],
+    [0, 4, 8], [2, 4, 6],
+  ]
+
+  public static func outcome(of board: [Player?]) -> Outcome {
+    for line in winningLines {
+      if let player = board[line[0]], board[line[1]] == player, board[line[2]] == player {
+        return .won(player)
+      }
+    }
+    return board.contains(nil) ? .inProgress : .draw
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 47 · key a337c520

The subject currently lives in T1.

Test:

```swift
@Test("a 10% discount on two $5 items totals $9 — catches customers charged the undiscounted price")
func discountedTotal() {
  let cart = Cart(items: [Item(price: 5, quantity: 2)], discount: 0.1)
  #expect(cart.total == 9)
}
```

Change:

```diff
+  public var total: Decimal {
+    let subtotal = items.reduce(0) { $0 + $1.price * Decimal($1.quantity) }
+    return discount.map { subtotal * (1 - $0) } ?? subtotal
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 48 · key a57d9f80

The subject currently lives in T1.

Test:

```swift
@Test("sync logs the upload — catches sync not logging")
func syncLogs() async throws {
  let log = LogRecorder()
  try await Syncer(store: .mock(pending: 2), api: .noop, logger: log).sync()
  #expect(log.messages == ["sync uploaded 2 changes"])
}
```

Change:

```diff
+  public func sync() async throws {
+    let changes = try await store.pendingChanges()
+    try await api.upload(changes)
+    logger.info("sync uploaded \(changes.count) changes")
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 49 · key a580f178

The subject currently lives in T2.

Test:

```swift
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
```

Change:

```diff
+    VStack(spacing: 24) {
+      Text("\(store.count)")
+        .font(.system(size: 64, weight: .bold, design: .rounded))
+        .monospacedDigit()
+        .accessibilityIdentifier("counter.value")
+
+      HStack(spacing: 32) {
+        Button("Decrement", systemImage: "minus") { store.send(.decrementButtonTapped) }
+          .accessibilityIdentifier("counter.decrement")
+        Button("Increment", systemImage: "plus") { store.send(.incrementButtonTapped) }
+          .accessibilityIdentifier("counter.increment")
+      }
+      .labelStyle(.iconOnly)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 50 · key aa2739ca

The subject currently lives in T1.

Test:

```swift
@Test("a rejected password shows the error alert and stops the spinner — catches a login screen stuck loading after a 401")
func loginFailure() async {
  let store = TestStore(initialState: Login.State(isLoading: true)) { Login() }
  await store.send(.loginResponse(.failure(.invalidCredentials))) {
    $0.isLoading = false
    $0.alert = AlertState { TextState("That password didn't match.") }
  }
}
```

Change:

```diff
+  case .loginResponse(.failure(let error)):
+    state.isLoading = false
+    state.alert = AlertState { TextState(error.userMessage) }
+    return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 51 · key b1c573ad

The subject currently lives in T1.

Test:

```swift
@Test("counter works — catches counter bugs")
func counterWorks() {
  let state = Counter.State(count: 1)
  #expect(state.count == 1)
}
```

Change:

```diff
+  case .incrementButtonTapped:
+    state.count += 1
+    return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 52 · key bdc9d430

The subject currently lives in T1.

Test:

```swift
@Test("a failed fact request is handled — catches regressions")
func factFailure() async {
  let apiCalls = LockIsolated(0)
  let logCalls = LockIsolated(0)
  let store = TestStore(initialState: CounterFeature.State(count: 7)) {
    CounterFeature()
  } withDependencies: {
    $0.apiClient.randomFact = {
      apiCalls.withValue { $0 += 1 }
      throw FactUnavailable()
    }
    $0.logClient.emit = { _ in logCalls.withValue { $0 += 1 } }
  }

  await store.send(.factButtonTapped) { $0.isLoadingFact = true }
  await store.receive(\.factFailed) { $0.isLoadingFact = false }
  #expect(apiCalls.value == 1)
  #expect(logCalls.value == 1)
}
```

Change:

```diff
       case .factButtonTapped:
-        return .none
+        state.isLoadingFact = true
+        return .run { [count = state.count, apiClient, log] send in
+          do {
+            await send(.factResponse(try await apiClient.randomFact().text))
+          } catch {
+            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
+            await send(.factFailed)
+          }
+        }
+
+      case .factResponse(let fact):
+        state.isLoadingFact = false
+        state.fact = fact
+        return .none
+
+      case .factFailed:
+        state.isLoadingFact = false
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 53 · key c46759c5

The subject currently lives in T1.

Test:

```swift
@Test("non-2xx responses throw the status code — catches error pages being decoded as data")
func failureStatusThrows() async {
  await #expect(throws: (any Error).self) {
    try await Self.client(status: 500).data(for: URLRequest(url: Self.url))
  }
}
```

Change:

```diff
+extension HTTPClient {
+  public func data(for request: URLRequest) async throws -> Data {
+    let (data, response) = try await send(request)
+    guard (200..<300).contains(response.statusCode) else {
+      throw HTTPError.unacceptableStatus(response.statusCode)
+    }
+    return data
+  }
+}
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 54 · key c486dc47

The subject currently lives in T2.

Test:

```swift
@Test("one tap reads as singular — catches the counter label saying 1 taps")
func singularLabel() async {
  let store = TestStore(initialState: CounterFeature.State()) { CounterFeature() }

  await store.send(.incrementButtonTapped) { $0.count = 1 }

  #expect(store.state.countLabel == "1 tap")
}
```

Change:

```diff
     public var isLoadingFact: Bool
+
+    public var countLabel: String {
+      count == 1 ? "1 tap" : "\(count) taps"
+    }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 55 · key c7a88ced

The subject currently lives in T1.

Test:

```swift
@MainActor
func testFactButton() {
  let app = XCUIApplication()
  app.launch()

  app.buttons["counter.fact"].tap()

  let expected = "Cat fact"
  XCTAssertEqual(expected, "Cat fact")
}
```

Change:

```diff
+      Button("Cat fact") { store.send(.factButtonTapped) }
+        .disabled(store.isLoadingFact)
+        .accessibilityIdentifier("counter.fact")
+
+      if store.isLoadingFact {
+        ProgressView()
+      } else if let fact = store.fact {
+        Text(fact)
+          .multilineTextAlignment(.center)
+          .accessibilityIdentifier("counter.factText")
+      }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 56 · key c95ed111

The subject currently lives in T1.

Test:

```swift
@Test("changing the count clears a shown fact — catches a stale fact shown next to a new count")
func countChangeClearsFact() async {
  let factRequests = LockIsolated(0)
  let store = TestStore(initialState: CounterFeature.State(count: 3, fact: "old")) {
    CounterFeature()
  } withDependencies: {
    $0.apiClient.randomFact = {
      factRequests.withValue { $0 += 1 }
      return Fact(text: "new")
    }
    $0.logClient = LogClient(isEnabled: { _, _ in false }, emit: { _ in })
  }

  await store.send(.incrementButtonTapped) {
    $0.count = 4
    $0.fact = nil
  }
  #expect(factRequests.value == 0)
}
```

Change:

```diff
       case .incrementButtonTapped:
         state.count += 1
+        state.fact = nil
         return .none

       case .decrementButtonTapped:
         state.count -= 1
+        state.fact = nil
         return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 57 · key cc0c445e

The subject currently lives in T1.

Test:

```swift
@Test("tapping increment raises the count by one — catches the increment button doing nothing")
func incrementRaisesCount() async {
  let store = TestStore(initialState: CounterFeature.State(count: 4)) { CounterFeature() }
  store.exhaustivity = .off

  await store.send(.incrementButtonTapped)

  let expected = CounterFeature.State(count: 5)
  #expect(expected.count == 5)
}
```

Change:

```diff
       case .incrementButtonTapped:
         state.count += 1
+        state.fact = nil
         return .none

       case .decrementButtonTapped:
         state.count -= 1
+        state.fact = nil
         return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 58 · key ce1bcf1c

The subject currently lives in T1.

Test:

```swift
@Test("weather converts kelvin to celsius — catches temperatures shown 273 degrees too hot")
func converts() async throws {
  let service = MockWeatherService()
  service.stubbedForecast = Forecast(celsius: 20)
  let forecast = try await service.weather(for: "Paris")
  #expect(forecast.celsius == 20)
}
```

Change:

```diff
+  public func weather(for city: String) async throws -> Forecast {
+    let raw = try await transport.get("/weather?city=\(city)")
+    return try Forecast(celsius: raw.kelvin - 273.15)
+  }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 59 · key d199d59f

The subject currently lives in T2.

Test:

```swift
@Test("snapshot — catches changes")
func snapshot() {
  let store = Store(initialState: CounterFeature.State(count: 3, isLoadingFact: true)) {
    CounterFeature()
  }
  assertSnapshot(
    of: UIHostingController(rootView: CounterView(store: store)),
    as: .image(on: .iPhone13, traits: UITraitCollection(userInterfaceStyle: .dark))
  )
}
```

Change:

```diff
+      Button("Cat fact") { store.send(.factButtonTapped) }
+        .disabled(store.isLoadingFact)
+        .accessibilityIdentifier("counter.fact")
+
+      if store.isLoadingFact {
+        ProgressView()
+      } else if let fact = store.fact {
+        Text(fact)
+          .multilineTextAlignment(.center)
+          .accessibilityIdentifier("counter.factText")
+      }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 60 · key ddfdde71

The subject currently lives in T1.

Test:

```swift
@Test(
  "the preview value answers without a transport — catches previews and snapshots reaching for the network"
)
func previewAnswersOffline() {
  let fact = Fact(text: "Cats sleep for around 13 to 14 hours a day.")

  #expect(fact.text == "Cats sleep for around 13 to 14 hours a day.")
}
```

Change:

```diff
 extension APIClient: TestDependencyKey {
   public static let testValue = APIClient()
+  public static let previewValue = APIClient(randomFact: {
+    Fact(text: "Cats sleep for around 13 to 14 hours a day.")
+  })
 }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 61 · key e134681c

The subject currently lives in T2.

Test:

```swift
@Test(
  "an override set with withDependencies is what @Dependency(\\.apiClient) reads — catches the accessor wired to a different key than the override"
)
func overrideReachesReaders() async throws {
  let fact = try await withDependencies {
    $0.apiClient.randomFact = { Fact(text: "stubbed") }
  } operation: {
    @Dependency(\.apiClient) var apiClient
    return try await apiClient.randomFact()
  }

  #expect(fact == Fact(text: "stubbed"))
}
```

Change:

```diff
+extension DependencyValues {
+  public var apiClient: APIClient {
+    get { self[APIClient.self] }
+    set { self[APIClient.self] = newValue }
+  }
+}
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 62 · key e22435de

The subject currently lives in T1.

Test:

```swift
@Test("the counter view shows the count — catches the view reading the wrong state")
func showsCount() throws {
  let store = Store(initialState: CounterFeature.State(count: 42)) { CounterFeature() }

  let text = try CounterView(store: store).inspect().vStack().text(0).string()

  #expect(text == "42")
}
```

Change:

```diff
+    VStack(spacing: 24) {
+      Text("\(store.count)")
+        .font(.system(size: 64, weight: .bold, design: .rounded))
+        .monospacedDigit()
+        .accessibilityIdentifier("counter.value")
+
+      HStack(spacing: 32) {
+        Button("Decrement", systemImage: "minus") { store.send(.decrementButtonTapped) }
+          .accessibilityIdentifier("counter.decrement")
+        Button("Increment", systemImage: "plus") { store.send(.incrementButtonTapped) }
+          .accessibilityIdentifier("counter.increment")
+      }
+      .labelStyle(.iconOnly)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 63 · key e4d78fdf

The subject currently lives in T1.

Test:

```swift
@Test("checkout works — catches checkout bugs")
func checkoutFlow() throws {
  let app = XCUIApplication()
  app.launch()
  app.buttons["Add to cart"].tap()
  app.buttons["Checkout"].tap()
  XCTAssertTrue(app.staticTexts["Thanks!"].waitForExistence(timeout: 5))
}
```

Change:

```diff
+  Button("Checkout") { store.send(.checkoutTapped) }
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 64 · key f0025da2

The subject currently lives in T3.

Test:

```swift
@Test("a failed fact request stops the spinner — catches a spinner that never goes away")
func failureStopsSpinner() async {
  let store = TestStore(initialState: CounterFeature.State()) {
    CounterFeature()
  } withDependencies: {
    $0.apiClient.randomFact = { throw FactUnavailable() }
  }
  store.exhaustivity = .off

  await store.send(.factButtonTapped) { $0.isLoadingFact = true }
}
```

Change:

```diff
       case .factButtonTapped:
-        return .none
+        state.isLoadingFact = true
+        return .run { [count = state.count, apiClient, log] send in
+          do {
+            await send(.factResponse(try await apiClient.randomFact().text))
+          } catch {
+            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
+            await send(.factFailed)
+          }
+        }
+
+      case .factResponse(let fact):
+        state.isLoadingFact = false
+        state.fact = fact
+        return .none
+
+      case .factFailed:
+        state.isLoadingFact = false
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 65 · key f32eb266

The subject currently lives in T1.

Test:

```swift
@Test("view — catches regressions")
func view() {
  let store = Store(initialState: CounterFeature.State(count: 5)) { CounterFeature() }
  assertSnapshot(of: CounterView(store: store), as: .dump)
}
```

Change:

```diff
+    VStack(spacing: 24) {
+      Text("\(store.count)")
+        .font(.system(size: 64, weight: .bold, design: .rounded))
+        .monospacedDigit()
+        .accessibilityIdentifier("counter.value")
+
+      HStack(spacing: 32) {
+        Button("Decrement", systemImage: "minus") { store.send(.decrementButtonTapped) }
+          .accessibilityIdentifier("counter.decrement")
+        Button("Increment", systemImage: "plus") { store.send(.incrementButtonTapped) }
+          .accessibilityIdentifier("counter.increment")
+      }
+      .labelStyle(.iconOnly)
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:

## Case 66 · key fdc10e48

The subject currently lives in T1.

Test:

```swift
@Test("the fact button loads and shows a fact — catches the loading state never resolving")
func factLoads() async {
  let store = TestStore(initialState: CounterFeature.State()) {
    CounterFeature()
  } withDependencies: {
    $0.apiClient.randomFact = { Fact(text: "Cats have five toes on their front paws.") }
  }
  store.exhaustivity = .off

  await store.send(.factButtonTapped) { $0.isLoadingFact = true }
}
```

Change:

```diff
       case .factButtonTapped:
-        return .none
+        state.isLoadingFact = true
+        return .run { [count = state.count, apiClient, log] send in
+          do {
+            await send(.factResponse(try await apiClient.randomFact().text))
+          } catch {
+            log.log(.error, "fact request failed", category: "Counter", [.public("count", count)])
+            await send(.factFailed)
+          }
+        }
+
+      case .factResponse(let fact):
+        state.isLoadingFact = false
+        state.fact = fact
+        return .none
+
+      case .factFailed:
+        state.isLoadingFact = false
+        return .none
```

Questions:

- fails-if-broken: Would this test fail if the behavior it names were broken? Options: yes, no.
- tier: Which tier does this test belong in? T1: host unit test of logic (reducers, pure functions, clients with fakes). T2: simulator test of rendering or platform integration (snapshots, views). T3: end-to-end UI flow (XCUITest). Options: T1, T2, T3.
- name-specificity: How specific is the regression the test's name says it catches? vague: names no symptom or restates the behavior; partial: names an area but not the symptom; specific: names a user- or caller-visible symptom. Options: vague, partial, specific.
- asserts-implementation: Does the test assert implementation details (private call order, internal state, exact log text, which collaborator was called) rather than observable behavior? Options: yes, no.

Answer fails-if-broken:
Answer tier:
Answer name-specificity:
Answer asserts-implementation:
