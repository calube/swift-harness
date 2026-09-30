#!/usr/bin/env python3
"""Writes the hand-written development set to dev-set/. An agent wrote and labelled
these cases for design exploration; they never count toward calibration or the benchmark.

Labels (same meaning as the repo's labels.json expected answers):
  fib  fails-if-broken: "yes" the test would fail if the behavior its name names broke, else "no"
  name name-specificity: vague / partial / specific
  ai   asserts-implementation: "yes" / "no"
  kind short failure-mode tag, for the error analysis only
"""
import json, os

P = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(P, "dev-set")

CASES = []


def case(id, kind, fib, name, ai, test, diff, tier="T1", expected_tier="T1"):
    CASES.append(dict(id=id, kind=kind, declaredTier=tier,
                      expected={"fails-if-broken": fib, "name-specificity": name,
                                "asserts-implementation": ai, "tier": expected_tier},
                      test=test.strip("\n") + "\n", diff=diff.strip("\n") + "\n"))


# ---------------------------------------------------------------- good tests (controls)
case("tip-rounding", "good", "yes", "specific", "no", '''
@Test("a 15% tip on $10.05 rounds to $1.51 — catches diners shown a tip one cent short")
func tipRoundsHalfUp() {
  let tip = TipCalculator.tip(for: Decimal(string: "10.05")!, percent: 15)
  #expect(tip == Decimal(string: "1.51")!)
}
''', '''
+  public static func tip(for amount: Decimal, percent: Int) -> Decimal {
+    var raw = amount * Decimal(percent) / 100
+    var rounded = Decimal()
+    NSDecimalRound(&rounded, &raw, 2, .plain)
+    return rounded
+  }
''')

case("email-disables-login", "good", "yes", "specific", "no", '''
@Test("an email without an @ keeps Log In disabled — catches users submitting a malformed email")
func invalidEmailDisablesLogin() async {
  let store = TestStore(initialState: SignIn.State(password: "hunter22")) { SignIn() }
  await store.send(.emailChanged("ada.example.com")) {
    $0.email = "ada.example.com"
    $0.isLoginEnabled = false
  }
}
''', '''
+  case let .emailChanged(email):
+    state.email = email
+    state.isLoginEnabled = email.contains("@") && !state.password.isEmpty
+    return .none
''')

case("feed-retry-backoff", "good-timing", "yes", "specific", "no", '''
@Test("two failed fetches then a success shows the feed — catches the feed staying empty after a brief outage")
func retriesWithBackoff() async {
  let clock = TestClock()
  var attempts = 0
  let store = TestStore(initialState: Feed.State()) { Feed() } withDependencies: {
    $0.continuousClock = clock
    $0.feedClient.load = {
      attempts += 1
      if attempts < 3 { throw URLError(.timedOut) }
      return [Post(id: 1, title: "Hello")]
    }
  }
  await store.send(.onAppear) { $0.isLoading = true }
  await clock.advance(by: .seconds(1))
  await clock.advance(by: .seconds(2))
  await store.receive(\\.loaded) {
    $0.isLoading = false
    $0.posts = [Post(id: 1, title: "Hello")]
  }
}
''', '''
+  case .onAppear:
+    state.isLoading = true
+    return .run { send in
+      var delay = Duration.seconds(1)
+      for attempt in 1...3 {
+        do { return await send(.loaded(try await feedClient.load())) }
+        catch where attempt < 3 { try await clock.sleep(for: delay); delay *= 2 }
+      }
+    }
''')

case("search-debounce", "good-timing", "yes", "specific", "no", '''
@Test("typing two characters within 300ms sends one search — catches a request per keystroke")
func debouncesQuery() async {
  let clock = TestClock()
  let store = TestStore(initialState: Search.State()) { Search() } withDependencies: {
    $0.continuousClock = clock
    $0.searchClient.search = { query in [Result(title: query)] }
  }
  await store.send(.queryChanged("s")) { $0.query = "s" }
  await store.send(.queryChanged("sw")) { $0.query = "sw" }
  await clock.advance(by: .milliseconds(300))
  await store.receive(\\.searchResponse) { $0.results = [Result(title: "sw")] }
}
''', '''
+  case let .queryChanged(query):
+    state.query = query
+    return .run { send in
+      try await clock.sleep(for: .milliseconds(300))
+      await send(.searchResponse(try await searchClient.search(query)))
+    }
+    .cancellable(id: CancelID.search, cancelInFlight: true)
''')

case("order-status-unknown", "good", "yes", "specific", "no", '''
@Test("an unrecognized status decodes as .unknown — catches the whole order list failing to load when the server adds a status")
func unknownStatusDecodes() throws {
  let json = Data(#"{"id": 4, "status": "on_hold"}"#.utf8)
  let order = try JSONDecoder().decode(Order.self, from: json)
  #expect(order.status == .unknown)
}
''', '''
+  public init(from decoder: Decoder) throws {
+    let raw = try decoder.singleValueContainer().decode(String.self)
+    self = OrderStatus(rawValue: raw) ?? .unknown
+  }
''')

case("relative-just-now", "good", "yes", "specific", "no", '''
@Test("a message sent 59 seconds ago reads 'just now' — catches timestamps showing '0 minutes ago'")
func underAMinuteIsJustNow() {
  let now = Date(timeIntervalSince1970: 1_000)
  let label = RelativeTime.label(for: now.addingTimeInterval(-59), now: now)
  #expect(label == "just now")
}
''', '''
+  public static func label(for date: Date, now: Date) -> String {
+    let seconds = now.timeIntervalSince(date)
+    if seconds < 60 { return "just now" }
+    return "\\(Int(seconds / 60)) minutes ago"
+  }
''')

case("upload-failure-banner", "good", "yes", "specific", "no", '''
@Test("a failed upload shows the retry banner and clears the progress bar — catches a progress bar frozen at 99%")
func uploadFailureShowsBanner() async {
  let store = TestStore(initialState: Upload.State(progress: 0.99)) { Upload() }
  await store.send(.uploadFinished(.failure(.network))) {
    $0.progress = nil
    $0.banner = .retry(message: "Upload failed. Tap to retry.")
  }
}
''', '''
+  case .uploadFinished(.failure):
+    state.progress = nil
+    state.banner = .retry(message: "Upload failed. Tap to retry.")
+    return .none
''')

case("page-two-appends", "good", "yes", "specific", "no", '''
@Test("reaching the end of the list appends page 2 — catches page 1 being replaced instead of extended")
func appendsNextPage() async {
  let page1 = (1...20).map { Photo(id: $0) }
  let page2 = (21...40).map { Photo(id: $0) }
  let store = TestStore(initialState: Gallery.State(photos: page1, nextPage: 2)) { Gallery() } withDependencies: {
    $0.photoClient.page = { _ in page2 }
  }
  await store.send(.reachedEnd)
  await store.receive(\\.pageLoaded) {
    $0.photos = page1 + page2
    $0.nextPage = 3
  }
}
''', '''
+  case let .pageLoaded(photos):
+    state.photos.append(contentsOf: photos)
+    state.nextPage += 1
+    return .none
''')

case("countdown-stops-on-dismiss", "good-timing", "yes", "specific", "no", '''
@Test("leaving the screen stops the countdown — catches the timer ticking in the background")
func dismissCancelsTimer() async {
  let clock = TestClock()
  let store = TestStore(initialState: Countdown.State(remaining: 10)) { Countdown() } withDependencies: {
    $0.continuousClock = clock
  }
  await store.send(.onAppear)
  await clock.advance(by: .seconds(1))
  await store.receive(\\.tick) { $0.remaining = 9 }
  await store.send(.onDisappear)
  await clock.advance(by: .seconds(5))
}
''', '''
+  case .onDisappear:
+    return .cancel(id: CancelID.timer)
''')

case("password-rules", "good", "yes", "specific", "no", '''
@Test("'abc' fails both the length and digit rules — catches weak passwords accepted at sign-up")
func weakPasswordFailsRules() {
  #expect(PasswordRule.violations(in: "abc") == [.tooShort, .noDigit])
}
''', '''
+  public static func violations(in password: String) -> [PasswordRule] {
+    var out: [PasswordRule] = []
+    if password.count < 8 { out.append(.tooShort) }
+    if !password.contains(where: \\.isNumber) { out.append(.noDigit) }
+    return out
+  }
''')

case("euro-format-de", "good", "yes", "specific", "no", '''
@Test("1234.5 EUR in German shows '1.234,50 €' — catches German users seeing US-style prices")
func germanEuroFormat() {
  let text = PriceFormatter.string(1234.5, currency: "EUR", locale: Locale(identifier: "de_DE"))
  #expect(text == "1.234,50\\u{00A0}€")
}
''', '''
+  public static func string(_ amount: Double, currency: String, locale: Locale) -> String {
+    amount.formatted(.currency(code: currency).locale(locale))
+  }
''')

case("autosave-draft", "good-spy-output", "yes", "specific", "no", '''
@Test("pausing typing for 2s saves the draft — catches a half-written reply lost when the app is killed")
func savesDraftAfterPause() async {
  let clock = TestClock()
  let saved = LockIsolated<[Draft]>([])
  let store = TestStore(initialState: Compose.State()) { Compose() } withDependencies: {
    $0.continuousClock = clock
    $0.drafts.save = { draft in saved.withValue { $0.append(draft) } }
  }
  await store.send(.textChanged("see you at 6")) { $0.text = "see you at 6" }
  await clock.advance(by: .seconds(2))
  #expect(saved.value == [Draft(text: "see you at 6")])
}
''', '''
+  case let .textChanged(text):
+    state.text = text
+    return .run { _ in
+      try await clock.sleep(for: .seconds(2))
+      try await drafts.save(Draft(text: text))
+    }
+    .cancellable(id: CancelID.autosave, cancelInFlight: true)
''')

case("empty-inbox-state", "good", "yes", "partial", "no", '''
@Test("loaded messages update the inbox — catches a bug when the server returns no messages")
func emptyInbox() async {
  let store = TestStore(initialState: Inbox.State(isLoading: true)) { Inbox() }
  await store.send(.loaded([])) {
    $0.isLoading = false
    $0.messages = []
    $0.showsEmptyState = true
  }
}
''', '''
+  case let .loaded(messages):
+    state.isLoading = false
+    state.messages = messages
+    state.showsEmptyState = messages.isEmpty
+    return .none
''')

case("sort-works", "good", "yes", "vague", "no", '''
@Test("sort works — catches sort not working")
func sortsContacts() {
  let sorted = ContactSorter.sorted([Contact(last: "Zhu"), Contact(last: "Abe"), Contact(last: "Lee")])
  #expect(sorted.map(\\.last) == ["Abe", "Lee", "Zhu"])
}
''', '''
+  public static func sorted(_ contacts: [Contact]) -> [Contact] {
+    contacts.sorted { $0.last.localizedCaseInsensitiveCompare($1.last) == .orderedAscending }
+  }
''')

case("xctest-name-only", "good", "yes", "vague", "no", '''
func testMileageConversion() {
  let km = Distance(miles: 26.2).kilometers
  XCTAssertEqual(km, 42.16, accuracy: 0.01)
}
''', '''
+  public var kilometers: Double { miles * 1.609344 }
''')

case("discount-edges", "good", "yes", "partial", "no", '''
@Test("coupon totals — catches a bug with coupons past their expiry date")
func expiredCouponIgnored() {
  let now = Date(timeIntervalSince1970: 2_000)
  let coupon = Coupon(percent: 20, expires: now.addingTimeInterval(-1))
  #expect(Checkout.total(subtotal: 50, coupon: coupon, now: now) == 50)
}
''', '''
+  public static func total(subtotal: Decimal, coupon: Coupon?, now: Date) -> Decimal {
+    guard let coupon, coupon.expires > now else { return subtotal }
+    return subtotal * (1 - Decimal(coupon.percent) / 100)
+  }
''')

case("streak-reset", "good", "yes", "partial", "no", '''
@Test("streak counting — catches wrong handling of a skipped day")
func missedDayResetsStreak() {
  let cal = Calendar(identifier: .gregorian)
  let days = [DateComponents(year: 2026, month: 3, day: 1), DateComponents(year: 2026, month: 3, day: 3)]
    .map { cal.date(from: $0)! }
  #expect(Streak.current(days: days, calendar: cal) == 1)
}
''', '''
+  public static func current(days: [Date], calendar: Calendar) -> Int {
+    var streak = 1
+    for (a, b) in zip(days, days.dropFirst()).reversed() {
+      guard calendar.dateComponents([.day], from: a, to: b).day == 1 else { break }
+      streak += 1
+    }
+    return streak
+  }
''')

case("vague-good-toggle", "good", "yes", "vague", "no", '''
@Test("muteTapped mutes — catches muteTapped not muting")
func mutes() async {
  let store = TestStore(initialState: Player.State(isMuted: false, volume: 0.8)) { Player() }
  await store.send(.muteTapped) {
    $0.isMuted = true
    $0.volume = 0
  }
}
''', '''
+  case .muteTapped:
+    state.isMuted.toggle()
+    state.volume = state.isMuted ? 0 : state.savedVolume
+    return .none
''')

case("timer-ticks", "good-timing", "yes", "specific", "no", '''
@Test("three seconds on the clock lowers the timer from 10 to 7 — catches a workout timer that never counts down")
func ticksDown() async {
  let clock = TestClock()
  let store = TestStore(initialState: Workout.State(remaining: 10)) { Workout() } withDependencies: {
    $0.continuousClock = clock
  }
  await store.send(.start) { $0.isRunning = true }
  await clock.advance(by: .seconds(3))
  await store.receive(\\.tick) { $0.remaining = 9 }
  await store.receive(\\.tick) { $0.remaining = 8 }
  await store.receive(\\.tick) { $0.remaining = 7 }
  await store.send(.stop) { $0.isRunning = false }
}
''', '''
+  case .start:
+    state.isRunning = true
+    return .run { send in
+      for await _ in clock.timer(interval: .seconds(1)) { await send(.tick) }
+    }
+    .cancellable(id: CancelID.timer)
+  case .tick:
+    state.remaining -= 1
+    return .none
''')

# ---------------------------------------------------------------- only exercises its own fake
case("own-fake-weather", "own-fake", "no", "specific", "no", '''
@Test("the forecast shows Fahrenheit for US users — catches US users seeing Celsius")
func showsFahrenheit() async throws {
  let client = WeatherClient(current: { Weather(celsius: 20) })
  let weather = try await client.current()
  #expect(weather.celsius == 20)
}
''', '''
+  public func temperatureText(locale: Locale) async throws -> String {
+    let weather = try await client.current()
+    let f = weather.celsius * 9 / 5 + 32
+    return locale.region == .unitedStates ? "\\(Int(f))°F" : "\\(Int(weather.celsius))°C"
+  }
''')

case("own-fake-search", "own-fake", "no", "partial", "no", '''
@Test("search returns matches — catches bugs with uppercase queries")
func searchReturnsMatches() async throws {
  let client = SearchClient(search: { _ in [Result(title: "Swift")] })
  let results = try await client.search("sw")
  #expect(results == [Result(title: "Swift")])
}
''', '''
+  case let .searchTapped:
+    return .run { [query = state.query] send in
+      await send(.searchResponse(try await searchClient.search(query.lowercased())))
+    }
+  case let .searchResponse(results):
+    state.results = results.filter { !$0.title.isEmpty }
+    return .none
''')

case("own-fake-clock", "own-fake", "no", "vague", "no", '''
@Test("session expiry — catches session expiry bugs")
func sessionExpires() {
  var clock = FakeClock(now: Date(timeIntervalSince1970: 0))
  clock.now = clock.now.addingTimeInterval(3_601)
  #expect(clock.now.timeIntervalSince1970 == 3_601)
}
''', '''
+  public func isExpired(now: Date) -> Bool {
+    now.timeIntervalSince(issuedAt) > 3_600
+  }
''')

case("own-fake-keychain", "own-fake", "no", "specific", "no", '''
@Test("signing out removes the token from the keychain — catches the next user inheriting the previous session")
func signOutClearsToken() async throws {
  let keychain = InMemoryKeychain()
  keychain.set("tok_123", for: "auth")
  keychain.remove("auth")
  #expect(keychain.get("auth") == nil)
}
''', '''
+  public func signOut() async {
+    keychain.remove("auth")
+    await api.revoke()
+    currentUser = nil
+  }
''')

case("own-fake-formatter", "own-fake", "no", "vague", "no", '''
@Test("formats the duration — catches formatting failures")
func formatsDuration() {
  let formatter = StubDurationFormatter(result: "1h 5m")
  #expect(formatter.string(from: 3_900) == "1h 5m")
}
''', '''
+  public static func string(from seconds: Int) -> String {
+    let h = seconds / 3_600, m = (seconds % 3_600) / 60
+    return h > 0 ? "\\(h)h \\(m)m" : "\\(m)m"
+  }
''')

# ---------------------------------------------------------------- asserts the wrong field
case("wrong-field-tax", "wrong-field", "no", "specific", "no", '''
@Test("sales tax is added to the order total — catches orders charged without tax")
func addsTax() {
  let order = Order(items: [LineItem(price: 10), LineItem(price: 20)], taxRate: 0.08)
  #expect(order.items.count == 2)
  #expect(order.taxRate == 0.08)
}
''', '''
+  public var total: Decimal {
+    let subtotal = items.reduce(0) { $0 + $1.price }
+    return subtotal + subtotal * taxRate
+  }
''')

case("wrong-field-error-message", "wrong-field", "no", "specific", "no", '''
@Test("a failed save shows 'Couldn't save' — catches a silent failure the user never sees")
func failedSaveShowsError() async {
  let store = TestStore(initialState: Editor.State(isSaving: true)) { Editor() }
  store.exhaustivity = .off
  await store.send(.saveResponse(.failure(.disk))) {
    $0.isSaving = false
  }
}
''', '''
+  case .saveResponse(.failure):
+    state.isSaving = false
+    state.errorMessage = "Couldn't save"
+    return .none
''')

case("wrong-field-display-name", "wrong-field", "no", "partial", "no", '''
@Test("display name — catches a problem when the last name is empty")
func displayName() {
  let member = Member(id: 7, first: "Grace", last: "Hopper")
  #expect(member.id == 7)
  #expect(member.first == "Grace")
}
''', '''
+  public var displayName: String {
+    [first, last].filter { !$0.isEmpty }.joined(separator: " ")
+  }
''')

case("wrong-field-badge", "wrong-field", "no", "specific", "no", '''
@Test("reading a message lowers the unread badge — catches a badge stuck at the old count")
func readingLowersBadge() async {
  let store = TestStore(initialState: Inbox.State(messages: [.unread(1), .unread(2)], unreadCount: 2)) { Inbox() }
  store.exhaustivity = .off
  await store.send(.opened(id: 1)) {
    $0.selectedID = 1
  }
}
''', '''
+  case let .opened(id):
+    state.selectedID = id
+    state.messages[id: id]?.isRead = true
+    state.unreadCount = state.messages.filter { !$0.isRead }.count
+    return .none
''')

# ---------------------------------------------------------------- a mock returning a mock
case("mock-session-task", "mock-mock", "no", "specific", "no", '''
@Test("load resumes the data task — catches requests that are built but never sent")
func loadResumesTask() {
  let session = MockURLSession()
  let task = MockDataTask()
  session.nextTask = task
  #expect(session.dataTask(with: URLRequest(url: .init(string: "https://x.test")!)) === task)
}
''', '''
+  public func load(_ request: URLRequest) {
+    let task = session.dataTask(with: request)
+    task.resume()
+  }
''')

case("mock-factory-vm", "mock-mock", "no", "vague", "no", '''
@Test("makeDetail builds the detail view model — catches makeDetail not building it")
func makesDetail() {
  let factory = MockViewModelFactory()
  let stub = MockDetailViewModel()
  factory.detailToReturn = stub
  #expect(factory.makeDetail(id: 3) === stub)
}
''', '''
+  public func makeDetail(id: Int) -> DetailViewModel {
+    DetailViewModel(id: id, api: api, analytics: analytics)
+  }
''')

case("mock-cache-hit", "mock-mock", "no", "specific", "no", '''
@Test("a cached avatar is shown without a download — catches every scroll re-downloading avatars")
func cachedAvatarSkipsDownload() async {
  let cache = MockImageCache()
  let image = MockImage()
  cache.stubbedImage = image
  let result = cache.image(for: URL(string: "https://x.test/a.png")!)
  #expect(result === image)
}
''', '''
+  public func avatar(at url: URL) async throws -> Image {
+    if let cached = cache.image(for: url) { return cached }
+    let image = try await downloader.download(url)
+    cache.insert(image, for: url)
+    return image
+  }
''')

case("mock-repo-service", "mock-mock", "no", "partial", "no", '''
@Test("account loading — catches mishandling of suspended accounts")
func returnsStoredAccount() async throws {
  let repo = MockAccountRepository()
  repo.accountToReturn = .fixture
  let service = MockAccountService(repository: repo)
  let account = try await service.repository.load()
  #expect(account == .fixture)
}
''', '''
+  public func currentAccount() async throws -> Account {
+    let account = try await repository.load()
+    return account.isSuspended ? .guest : account
+  }
''')

# ---------------------------------------------------------------- existence / constructed / tautology
case("existence-rows", "existence", "no", "specific", "no", '''
@Test("chats sort newest first — catches old conversations shown at the top")
func sortsNewestFirst() async {
  let store = TestStore(initialState: Chats.State()) { Chats() } withDependencies: {
    $0.chatClient.list = { [Chat(id: 1, updated: .distantPast), Chat(id: 2, updated: .now)] }
  }
  store.exhaustivity = .off
  await store.send(.onAppear)
  await store.skipReceivedActions()
  #expect(!store.state.chats.isEmpty)
}
''', '''
+  case let .listLoaded(chats):
+    state.chats = chats.sorted { $0.updated > $1.updated }
+    return .none
''')

case("existence-parse", "existence", "no", "vague", "no", '''
@Test("parses the price field — catches problems parsing prices")
func parsesPrice() throws {
  let product = try? Product.parse(Data(#"{"name":"Mug","price":"12.50"}"#.utf8))
  #expect(product != nil)
}
''', '''
+  public static func parse(_ data: Data) throws -> Product {
+    let raw = try JSONDecoder().decode(RawProduct.self, from: data)
+    return Product(name: raw.name, price: Decimal(string: raw.price) ?? 0)
+  }
''')

case("constructed-money", "constructed", "no", "specific", "no", '''
@Test("$4.999 rounds to 500 cents — catches prices a cent short at checkout")
func roundsToCents() {
  let expected = Money(cents: 500)
  let money = expected
  #expect(money.cents == 500)
}
''', '''
+  public init(dollars: Decimal) {
+    var raw = dollars * 100
+    var rounded = Decimal()
+    NSDecimalRound(&rounded, &raw, 0, .plain)
+    cents = NSDecimalNumber(decimal: rounded).intValue
+  }
''')

case("no-assertion-sync", "no-assert", "no", "vague", "no", '''
@Test("sync runs — catches sync failures")
func syncRuns() async throws {
  let engine = SyncEngine(store: .inMemory, api: .mock)
  _ = try? await engine.run()
  #expect(true)
}
''', '''
+  public func run() async throws -> SyncReport {
+    let remote = try await api.changes(since: store.cursor)
+    try store.apply(remote)
+    return SyncReport(applied: remote.count)
+  }
''')

case("tautology-count", "tautology", "no", "vague", "no", '''
@Test("dedupe removes duplicates — catches dedupe not removing duplicates")
func dedupes() {
  let tags = TagList(["a", "b", "a"]).deduplicated()
  #expect(tags.count == tags.count)
}
''', '''
+  public func deduplicated() -> TagList {
+    var seen = Set<String>()
+    return TagList(values.filter { seen.insert($0).inserted })
+  }
''')

# ---------------------------------------------------------------- asserts implementation details
case("spy-call-order", "impl-order", "yes", "vague", "yes", '''
@Test("saving a profile — catches a regression in the save flow")
func saveOrder() async throws {
  let spy = CallRecorder()
  let saver = ProfileSaver(validator: spy.validator, store: spy.store, notifier: spy.notifier)
  try await saver.save(Profile(name: "Ada"))
  #expect(spy.calls == ["validate", "persist", "notify"])
}
''', '''
+  public func save(_ profile: Profile) async throws {
+    try validator.validate(profile)
+    try await store.persist(profile)
+    await notifier.notify(.profileSaved)
+  }
''')

case("formatter-call-count", "impl-count", "no", "specific", "yes", '''
@Test("the price label reads '$12.50' — catches prices rendered without cents")
func priceLabel() {
  let formatter = SpyCurrencyFormatter()
  let model = PriceRowModel(amount: 12.5, formatter: formatter)
  _ = model.label
  _ = model.label
  #expect(formatter.formatCallCount == 1)
}
''', '''
+  public lazy var label: String = formatter.string(from: amount)
''')

case("cache-internal-storage", "impl-private", "yes", "specific", "yes", '''
@Test("fetching a user twice hits the network once — catches duplicate profile requests")
func cachesUser() async throws {
  let loader = UserLoader(api: .mock)
  _ = try await loader.user(id: 1)
  _ = try await loader.user(id: 1)
  #expect(loader._storage.count == 1)
  #expect(loader._storage.keys.first == 1)
}
''', '''
+  public func user(id: Int) async throws -> User {
+    if let cached = _storage[id] { return cached }
+    let user = try await api.user(id)
+    _storage[id] = user
+    return user
+  }
''')

case("log-text", "impl-log", "no", "specific", "yes", '''
@Test("uploading three photos sends all three — catches photos silently dropped from an upload")
func uploadsAll() async throws {
  let logger = CapturingLogger()
  let uploader = PhotoUploader(api: .noop, logger: logger)
  try await uploader.upload([.fixture, .fixture, .fixture], to: "photos")
  #expect(logger.messages == ["Uploading 3 files to bucket photos", "Upload complete"])
}
''', '''
+  public func upload(_ photos: [Photo], to bucket: String) async throws {
+    logger.info("Uploading \\(photos.count) files to bucket \\(bucket)")
+    for photo in photos { try await api.put(photo, bucket) }
+    logger.info("Upload complete")
+  }
''')

case("invalidate-called", "impl-collab", "yes", "vague", "yes", '''
@Test("logout invalidates the repository — catches a problem in logout")
func logoutInvalidates() async {
  let repo = SpyRepository()
  let session = Session(repository: repo)
  await session.logout()
  #expect(repo.didCallInvalidate)
  #expect(repo.invalidateCallCount == 1)
}
''', '''
+  public func logout() async {
+    await repository.invalidate()
+    token = nil
+  }
''')

case("encoder-args", "impl-args", "yes", "vague", "yes", '''
@Test("encodes the payload — catches encoding failures")
func encodesPayload() throws {
  let encoder = SpyEncoder()
  let request = try CreateNote.request(Note(id: 1, text: "hi"), encoder: encoder)
  #expect(encoder.encodedTypes == ["Note"])
  #expect(encoder.encodeCallCount == 1)
  _ = request
}
''', '''
+  public static func request(_ note: Note, encoder: JSONEncoderProtocol) throws -> URLRequest {
+    var request = URLRequest(url: .notes)
+    request.httpMethod = "POST"
+    request.httpBody = try encoder.encode(note)
+    return request
+  }
''')


DROPPED = {"euro-format-de", "page-two-appends", "upload-failure-banner"}
CASES[:] = [c for c in CASES if c["id"] not in DROPPED]


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
