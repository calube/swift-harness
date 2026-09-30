#!/usr/bin/env python3
"""Writes the frozen-design holdout set to dev-holdout/ (written after round 2, never tuned on). An agent wrote and labelled these cases for design exploration; they
never count toward calibration or the benchmark.

Labels (same meaning as the repo's labels.json expected answers):
  fib  fails-if-broken: "yes" the test would fail if the behavior its name names broke, else "no"
  name name-specificity: vague / partial / specific
  ai   asserts-implementation: "yes" / "no"
  kind short failure-mode tag, for the error analysis only
"""
import json, os

P = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(P, "dev-holdout")

CASES = []


def case(id, kind, fib, name, ai, test, diff, tier="T1", expected_tier="T1"):
    CASES.append(dict(id=id, kind=kind, declaredTier=tier,
                      expected={"fails-if-broken": fib, "name-specificity": name,
                                "asserts-implementation": ai, "tier": expected_tier},
                      test=test.strip("\n") + "\n", diff=diff.strip("\n") + "\n"))



case("h-own-fake-rates", "own-fake", "no", "specific", "no", """
@Test("pull to refresh replaces stale rates — catches travellers converting at yesterday's rate")
func refreshReplacesRates() async throws {
  let client = RatesClient(fetch: { ["EUR": 0.91] })
  let rates = try await client.fetch()
  #expect(rates["EUR"] == 0.91)
}
""", """
+  case .refreshPulled:
+    return .run { send in await send(.ratesLoaded(try await ratesClient.fetch())) }
+  case let .ratesLoaded(rates):
+    state.rates = rates
+    state.updatedAt = now
+    return .none
""")

case("h-wrong-field-eta", "wrong-field", "no", "specific", "no", """
@Test("a weekend pickup delivers on Tuesday — catches ETAs that count Saturday as a business day")
func weekendPickupEta() {
  let shipment = Shipment(pickup: .saturday, carrier: "UPS", businessDays: 1)
  #expect(shipment.carrier == "UPS")
  #expect(shipment.businessDays == 1)
}
""", """
+  public var eta: Weekday {
+    var day = pickup.nextBusinessDay
+    for _ in 0..<businessDays { day = day.nextBusinessDay }
+    return day
+  }
""")

case("h-mock-token", "mock-mock", "no", "partial", "no", """
@Test("the interceptor adds the auth header — catches a bug with expired tokens")
func addsHeader() {
  let provider = MockTokenProvider()
  let token = MockToken(value: "abc")
  provider.tokenToReturn = token
  #expect(provider.currentToken() === token)
}
""", """
+  public func adapt(_ request: URLRequest) -> URLRequest {
+    var request = request
+    request.setValue("Bearer \\(provider.currentToken().value)", forHTTPHeaderField: "Authorization")
+    return request
+  }
""")

case("h-dark-mode", "good", "yes", "specific", "no", """
@Test("turning on dark mode saves the choice — catches the app reverting to light mode on relaunch")
func darkModePersists() async {
  let defaults = LockIsolated<[String: Bool]>([:])
  let store = TestStore(initialState: Appearance.State(isDark: false)) { Appearance() } withDependencies: {
    $0.settings.setBool = { value, key in defaults.withValue { $0[key] = value } }
  }
  await store.send(.darkModeToggled(true)) { $0.isDark = true }
  #expect(defaults.value["isDark"] == true)
}
""", """
+  case let .darkModeToggled(isOn):
+    state.isDark = isOn
+    return .run { _ in await settings.setBool(isOn, "isDark") }
""")

case("h-upload-backoff", "good-timing", "yes", "specific", "no", """
@Test("a failed upload retries after 2 seconds and completes — catches uploads abandoned after one network blip")
func uploadRetries() async {
  let clock = TestClock()
  var calls = 0
  let store = TestStore(initialState: Backup.State()) { Backup() } withDependencies: {
    $0.continuousClock = clock
    $0.backupClient.upload = { calls += 1; if calls == 1 { throw URLError(.networkConnectionLost) } }
  }
  await store.send(.startTapped) { $0.status = .uploading }
  await clock.advance(by: .seconds(2))
  await store.receive(\.uploadFinished) { $0.status = .done }
}
""", """
+  case .startTapped:
+    state.status = .uploading
+    return .run { send in
+      do { try await backupClient.upload() }
+      catch { try await clock.sleep(for: .seconds(2)); try await backupClient.upload() }
+      await send(.uploadFinished)
+    }
""")

case("h-analytics-help", "impl-collab", "no", "specific", "yes", """
@Test("tapping Help opens the help sheet — catches the Help button doing nothing")
func helpOpensSheet() async {
  let analytics = AnalyticsSpy()
  let store = TestStore(initialState: Home.State()) { Home() } withDependencies: { $0.analytics = analytics.client }
  store.exhaustivity = .off
  await store.send(.helpTapped)
  #expect(analytics.events.map(\.name) == ["help_tapped"])
  #expect(analytics.trackCallCount == 1)
}
""", """
+  case .helpTapped:
+    state.destination = .help(HelpSheet.State())
+    return .run { _ in await analytics.track(.init(name: "help_tapped")) }
""")

case("h-private-inflight", "impl-private", "yes", "vague", "yes", """
@Test("load finishes — catches load bugs")
func loadFinishes() async throws {
  let model = OrdersModel(api: .stub(orders: [.fixture]))
  try await model.load()
  #expect(model._isRequestInFlight == false)
  #expect(model._requestGeneration == 1)
}
""", """
+  public func load() async throws {
+    _isRequestInFlight = true
+    _requestGeneration += 1
+    defer { _isRequestInFlight = false }
+    orders = try await api.orders()
+  }
""")

case("h-convert-vague", "good", "yes", "vague", "no", """
@Test("converts — catches conversion failures")
func converts() {
  #expect(Temperature.fahrenheit(fromCelsius: 100) == 212)
  #expect(Temperature.fahrenheit(fromCelsius: -40) == -40)
}
""", """
+  public static func fahrenheit(fromCelsius c: Double) -> Double { c * 9 / 5 + 32 }
""")

case("h-existence-receipt", "existence", "no", "specific", "no", """
@Test("the receipt includes 8% tax — catches receipts that understate the amount paid")
func receiptIncludesTax() async {
  let store = TestStore(initialState: Checkout.State(subtotal: 100)) { Checkout() }
  store.exhaustivity = .off
  await store.send(.payTapped)
  #expect(store.state.receipt != nil)
}
""", """
+  case .payTapped:
+    state.receipt = Receipt(subtotal: state.subtotal, tax: state.subtotal * 0.08)
+    return .none
""")

case("h-reminder-schedule", "good-spy-output", "yes", "specific", "no", """
@Test("setting a 9am reminder schedules one notification at 9am — catches reminders firing at the wrong hour")
func schedulesReminder() async {
  let scheduled = LockIsolated<[DateComponents]>([])
  let store = TestStore(initialState: Reminders.State()) { Reminders() } withDependencies: {
    $0.notifications.schedule = { at in scheduled.withValue { $0.append(at) } }
  }
  await store.send(.reminderTimeChosen(hour: 9)) { $0.reminderHour = 9 }
  #expect(scheduled.value == [DateComponents(hour: 9, minute: 0)])
}
""", """
+  case let .reminderTimeChosen(hour):
+    state.reminderHour = hour
+    return .run { _ in await notifications.schedule(DateComponents(hour: hour, minute: 0)) }
""")

case("h-badge-partial", "good", "yes", "partial", "no", """
@Test("badge text — catches problems with more than 99 unread")
func capsBadge() {
  #expect(Badge.text(for: 120) == "99+")
  #expect(Badge.text(for: 7) == "7")
}
""", """
+  public static func text(for count: Int) -> String { count > 99 ? "99+" : String(count) }
""")

case("h-constructed-sort", "constructed", "no", "vague", "no", """
@Test("merge sort sorts — catches merge sort not sorting")
func mergeSorts() {
  let expected = [1, 2, 3]
  let result = expected.sorted()
  #expect(result == expected)
}
""", """
+  public static func mergeSort(_ values: [Int]) -> [Int] {
+    guard values.count > 1 else { return values }
+    let mid = values.count / 2
+    return merge(mergeSort(Array(values[..<mid])), mergeSort(Array(values[mid...])))
+  }
""")

case("h-xctest-discount", "good", "yes", "vague", "no", """
func testStudentDiscount() {
  let price = Pricing.price(base: 40, for: .student)
  XCTAssertEqual(price, 30)
}
""", """
+  public static func price(base: Decimal, for customer: CustomerKind) -> Decimal {
+    customer == .student ? base * 0.75 : base
+  }
""")

case("h-wrong-field-favorite", "wrong-field", "no", "specific", "no", """
@Test("favoriting a recipe raises its heart count — catches a count that stays at zero")
func favoriteRaisesCount() async {
  let store = TestStore(initialState: RecipeRow.State(isFavorite: false, favoriteCount: 0)) { RecipeRow() }
  store.exhaustivity = .off
  await store.send(.heartTapped) { $0.isFavorite = true }
}
""", """
+  case .heartTapped:
+    state.isFavorite.toggle()
+    state.favoriteCount += state.isFavorite ? 1 : -1
+    return .none
""")


def main():
    os.makedirs(os.path.join(OUT, "cases"), exist_ok=True)
    labels = []
    for c in CASES:
        d = os.path.join(OUT, "cases", c["id"])
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "Test.swift.txt"), "w").write(c["test"])
        open(os.path.join(d, "Change.diff"), "w").write(c["diff"])
        labels.append({**{k: c[k] for k in ("id", "kind", "declaredTier", "expected")},
                       "labeller": "agent"})
    json.dump({"schema": 1, "questionSet": "test-quality@1", "cases": labels},
              open(os.path.join(OUT, "labels.json"), "w"), indent=1)
    from collections import Counter
    print(len(CASES), "cases")
    for q in ("fails-if-broken", "name-specificity", "asserts-implementation"):
        print(q, Counter(c["expected"][q] for c in CASES))


if __name__ == "__main__":
    main()
