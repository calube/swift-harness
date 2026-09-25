# Swift standards

The rules every module in a swift-harness app follows. Each rule has the same shape:

- **Do** — what to write.
- **Tell** — how you (or a reviewer) can see the rule was broken.
- **Enforced by** — a `swiftgate` rule id (`swiftgate lint` / `swiftgate arch` / `swiftgate comments`), `arch` (a module-graph check in `swiftgate arch`), or `review` (human or review-agent judgment).
- **Source** — the upstream doc or issue behind the rule, plus the production incident that justifies it. Until a rule has an incident it says "incident: none yet".

The testing rules (tiers, red/green, snapshots, flake stress) live in the testing playbook, not here.

## 0. Baseline

### Platform and toolchain

Swift 6 language mode (complete concurrency checking), iOS 18+, SwiftUI. Xcode 26.2 / Swift 6.2.3, pinned in `.swiftgate.toml`; `swiftgate doctor` blocks on a mismatch. The app is a thin app target plus local Swift packages. Core packages declare `.macOS` so `swift test` runs on the host.

### Library pins

No rule or example here uses an API that has not been verified against these tags. Re-verify on every harness release.

| Library | Pin (from) | Notes |
|---|---|---|
| swift-composable-architecture | 1.26.2 | Use the 1.x shape. TCA 2.0 (`@Feature`, `Update`) is a subscriber-only beta: don't use it. Keep the `ComposableArchitecture2Deprecations` package trait on permanently. |
| swift-dependencies | 1.17.1 | `@DependencyClient` endpoints fail and report by default; `static let testValue = Self()` is fully unimplemented. `@DependencyEntry` is available. App-launch overrides go through `prepareDependencies {}`. Previews: `#Preview(traits: .dependencies {})`. |
| swift-navigation | 2.11.2 | |
| swift-case-paths | 1.10.0 | Prefer `some CasePath` over `AnyCasePath`. |
| swift-snapshot-testing | 1.19.6 | Record modes `.all/.failed/.missing/.never`. Use the `record:` parameter, `withSnapshotTesting`, or the `.snapshots(record:)` trait. The `isRecording`/`diffTool` globals are deprecated. |
| swift-clocks | 1.1.1 | `TestClock`, `ImmediateClock`. |
| swift-custom-dump | 1.7.3 | `expectNoDifference`; the `.customDump` snapshot strategy, not `.dump`. |
| swift-concurrency-extras | 1.4.1 | `withMainSerialExecutor` sets a process-global hook. Treat it as unsafe under Swift Testing's parallel runs unless the suite is `.serialized`. |
| swift-issue-reporting | none | Don't declare it on Swift 6.2. The `IssueReporting` module (`reportIssue`) comes transitively from `xctest-dynamic-overlay` 1.13+; adding swift-issue-reporting 2.x fails with a conflicting-target error. |
| swift-sharing | 2.10.1 | |
| swift-perception | none | Not needed at iOS 18+ (native Observation). No `WithPerceptionTracking`. |

### Toolchain hazards

- TCA 1.26.2 needs Swift 6.1 or later.
- Headless `xcodebuild` needs `-skipMacroValidation` or macro targets fail. `swiftgate` passes it; the trust decision is made when a dependency is pinned.
- `@Reducer` enums break under `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` ([TCA #3768](https://github.com/pointfreeco/swift-composable-architecture/issues/3768), open). Core packages don't use MainActor default isolation.
- Moving to Xcode 26.4 (Swift 6.3) needs TCA 1.24+ and swift-sharing 2.8.0+, and rejects writable key paths to `@Shared` state. Xcode 27 (Swift 6.4) needs TCA 1.26+. `swiftgate doctor` reports these.

### Escape hatches

Some rules can be waived for one line. The waiver goes on the same line, names the rule, and gives a reason a reviewer can check:

```swift
// Good: rule id and a checkable reason, same line.
final class FrameRing: @unchecked Sendable { // swiftgate:allow safety.unchecked-sendable — every access holds `lock`; FrameRingTests hammers it from 8 tasks

let slug = try! Regex("^[a-z0-9-]+$") // swiftgate:allow safety.try-bang — literal pattern; SlugTests compiles it

// Bad: no reason. A bare allow is itself a finding.
final class FrameRing: @unchecked Sendable { // swiftgate:allow safety.unchecked-sendable
// Bad: reason on the line above. The comment check only reads the same line.
// Needed for performance.
let slug = try! Regex("^[a-z0-9-]+$")
```

Third-party suppressions (`swiftlint:disable*`, `swiftformat:disable`, `periphery:ignore`) follow the same rule: a reason on the same line, checked by `swiftgate comments`.

## 1. Concurrency

**C1. Swift 6 language mode everywhere.**
- **Do:** every package and target uses Swift 6 language mode with complete checking.
- **Tell:** a `swiftLanguageModes: [.v5]` or `-strict-concurrency=minimal` setting in a manifest.
- **Enforced by:** review · **Source:** [Swift 6 migration guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/). Incident: none yet.

**C2. Concurrency escape hatches carry a reason.**
- **Do:** fix the isolation. If you truly can't, `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` get a same-line `swiftgate:allow` with the invariant that makes them safe.
- **Tell:** any of the three with no same-line reason.
- **Enforced by:** `safety.unchecked-sendable`, `safety.nonisolated-unsafe`, `safety.preconcurrency` · **Source:** [Sendable](https://developer.apple.com/documentation/swift/sendable). Incident: none yet.

**C3. Structured tasks over unstructured ones.**
- **Do:** use `async let`, task groups, or a TCA `.run` effect, so child work is cancelled with its parent. `Task {}` only at a true sync-to-async boundary; `Task.detached` only with a written reason.
- **Tell:** a `Task {}` whose handle is dropped inside code that is already async; a `Task.detached` with no reason; work that keeps running after its screen is gone.
- **Enforced by:** review · **Source:** [Task](https://developer.apple.com/documentation/swift/task). Incident: none yet.

**C4. Honor cancellation.**
- **Do:** long loops and multi-step work call `try Task.checkCancellation()` (or check `Task.isCancelled`) between steps. Don't swallow `CancellationError` as a user-facing failure.
- **Tell:** a loop over network pages with no cancellation check; an error alert on back-navigation.
- **Enforced by:** review · **Source:** [checkCancellation()](https://developer.apple.com/documentation/swift/task/checkcancellation()). Incident: none yet.

**C5. No MainActor default isolation in Core packages.**
- **Do:** leave `SWIFT_DEFAULT_ACTOR_ISOLATION` unset for Core packages. Put `@MainActor` on the UI types that need it.
- **Tell:** `.defaultIsolation(MainActor.self)` in a Core package manifest; `CaseReducerState` conformance errors on `@Reducer` enums.
- **Enforced by:** review · **Source:** [TCA #3768](https://github.com/pointfreeco/swift-composable-architecture/issues/3768). Incident: none yet.

## 2. Architecture

Every module keeps three invariants: logic lives in a platform-neutral, host-testable Core module and the UI module is thin; every source of nondeterminism is a dependency; Core tests run under `swift test` on the host in seconds.

| Kind | Core shape | Use when |
|---|---|---|
| `feature` (default) | TCA reducer + `TestStore` | Event-driven screens and flows |
| `engine` | Pure `(State, Input) -> State`, seeded RNG, fixed timestep | Real-time loops (above ~30 Hz), hot pipelines |
| `render` | SpriteKit / `Canvas` / Metal reading engine state; no rules | Rendering layers |
| `library` | Plain Swift | Shared utilities |
| `client` | `FooClient` / `FooClientLive` pair (section 3) | Services: networking, images, analytics, persistence, keychain, auth, flags, push, location |

**A1. Declare every non-TCA Core.**
- **Do:** a Core that isn't a TCA feature gets a `[[modules]]` entry in `.swiftgate.toml` with a `kind` and a `reason`. Pick a non-`feature` kind when you see per-frame updates, render loops, high-rate sensor/audio/camera streams, thin SDK wrappers where a reducer is pure ceremony, or store overhead in a profile.
- **Tell:** a Core module with no `@Reducer` and no config entry.
- **Enforced by:** arch · **Source:** [TCA Performance](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/Sources/ComposableArchitecture/Documentation.docc/Articles/Performance.md). Incident: none yet.

**A2. Core imports no UI framework.**
- **Do:** Core modules import Foundation, TCA, Dependencies and other Cores/interfaces only.
- **Tell:** `import SwiftUI` or `import UIKit` in a Core module; a Core test that needs a simulator.
- **Enforced by:** arch · **Source:** [harness design §6.1](superpowers/specs/2026-09-24-swift-harness-foundation-design.md) (host-testable Core). Incident: none yet.

**A3. Canonical TCA 1.26 feature shape.**
- **Do:** `@Reducer struct` + `@ObservableState struct State` + `body` built from `Reduce`. Name actions for what happened (`saveButtonTapped`, `itemsResponse`), not what to do. Group actions as `view` / `delegate` / internal cases; this grouping is a house convention, not a TCA API.
- **Tell:** actions named as commands (`loadItems`, `setLoading`); a parent switching on a child's internal actions instead of its `delegate`.
- **Enforced by:** arch (reducer present) + review (naming, grouping) · **Source:** [Getting started](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/Sources/ComposableArchitecture/Documentation.docc/Articles/GettingStarted.md). Incident: none yet.

**A4. Navigation is state.**
- **Do:** drill-downs use `StackState` / `StackActionOf` + `.forEach`. Sheets, alerts and popovers use `@Presents` + `PresentationAction` + `.ifLet`, with one `@Reducer enum Destination` per feature, scoped in the view with `$store.scope(\.destination, action: \.destination).<case>`.
- **Tell:** `@State var isShowingSheet` in a view; several optional child states that can be set at once.
- **Enforced by:** review · **Source:** [Tree-based navigation](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/Sources/ComposableArchitecture/Documentation.docc/Articles/TreeBasedNavigation.md), [Stack-based navigation](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/Sources/ComposableArchitecture/Documentation.docc/Articles/StackBasedNavigation.md). Incident: none yet.

**A5. No logic in views.**
- **Do:** views read state and send actions. Formatting that needs a test goes in State or Core.
- **Tell:** an `if` in a view that decides business behavior; a view calling a dependency.
- **Enforced by:** review · **Source:** [Getting started](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/Sources/ComposableArchitecture/Documentation.docc/Articles/GettingStarted.md). Incident: none yet.

**A6. No banned TCA APIs.**
- **Do:** use only the 1.x observation-era APIs shown here.
- **Tell:** any of `ViewStore`, `WithViewStore`, `@BindingState`, `BindingViewState`, `TaskResult`, `AnyCasePath`, `Store.withState`, the Combine effect operators (`.debounce`, `.throttle`, `.animation`, `.transaction`), `Effect.map`, `Effect.concatenate`, `store.publisher`, the legacy `scope(state:action:)` optional-chained destination form, reentrant `send`, any TCA 2.0 API, or the snapshot `isRecording` / `diffTool` globals. With the `ComposableArchitecture2Deprecations` trait on, the compiler also warns on every `state:`-labelled `scope(state:action:)` / `Scope(state:action:)` and on `send(_:animation:)`; use the unlabelled `scope(_:action:)` / `Scope(_:action:_:)` and `withAnimation { _ = store.send(action) }`.
- **Enforced by:** `tca.banned-api` · **Source:** [TCA migration guides](https://github.com/pointfreeco/swift-composable-architecture/tree/1.26.2/Sources/ComposableArchitecture/Documentation.docc/Articles/MigrationGuides). Incident: none yet.

### Example: feature shape

```swift
import ComposableArchitecture
import ItemsClient

@Reducer
public struct ItemsFeature {
  @ObservableState
  public struct State: Equatable {
    public var items: [Item] = []
    public var isLoading = false
    @Presents public var destination: Destination.State?
    public init() {}
  }

  public enum Action {
    case view(View)
    case delegate(Delegate)
    case itemsResponse(Result<[Item], any Error>)
    case destination(PresentationAction<Destination.Action>)

    @CasePathable
    public enum View { case onAppear, addButtonTapped }
    @CasePathable
    public enum Delegate { case itemCountChanged(Int) }
  }

  @Reducer
  public enum Destination { case add(AddItemFeature) }

  @Dependency(\.itemsClient) var itemsClient

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .view(.onAppear):
        state.isLoading = true
        return .run { send in
          let items = try await itemsClient.fetchAll()
          await send(.itemsResponse(.success(items)))
        } catch: { error, send in
          await send(.itemsResponse(.failure(error)))
        }

      case .view(.addButtonTapped):
        state.destination = .add(AddItemFeature.State())
        return .none

      case .itemsResponse(.success(let items)):
        state.isLoading = false
        state.items = items
        return .send(.delegate(.itemCountChanged(items.count)))

      case .itemsResponse(.failure):
        state.isLoading = false
        return .none

      case .delegate, .destination:
        return .none
      }
    }
    .ifLet(\.$destination, action: \.destination)
  }
}
```

```swift
import ComposableArchitecture
import SwiftUI

struct ItemsView: View {
  @Bindable var store: StoreOf<ItemsFeature>

  var body: some View {
    List(store.items) { item in Text(item.title) }
    .toolbar {
      Button("Add") { store.send(.view(.addButtonTapped)) }
        .accessibilityIdentifier("items.add")
    }
    .sheet(item: $store.scope(\.destination, action: \.destination).add) { AddItemView(store: $0) }
    .onAppear { store.send(.view(.onAppear)) }
  }
}
```

```swift
// Bad: banned APIs, command-named actions, logic in the view.
WithViewStore(store, observe: { $0 }) { viewStore in          // ViewStore era
  if viewStore.items.isEmpty && Date() > launchDeadline {      // logic + raw Date()
    Button("Load") { viewStore.send(.loadItems) }              // command-named action
  }
}
case .loadItems:
  return .run { send in
    await send(.itemsResponse(TaskResult { try await client.fetchAll() }))  // TaskResult
  }
```

Test it with an exhaustive `TestStore` in a `@MainActor` suite, building the store inside the test:

```swift
import ComposableArchitecture
import ItemsClient
import ItemsFeature
import Testing

@MainActor
struct ItemsFeatureTests {
  @Test("onAppear shows fetched items — catches an empty list after launch")
  func onAppearShowsItems() async {
    let store = TestStore(initialState: ItemsFeature.State()) {
      ItemsFeature()
    } withDependencies: {
      $0.itemsClient.fetchAll = { [Item(id: 1, title: "Tea")] }
    }

    await store.send(.view(.onAppear)) { $0.isLoading = true }
    await store.receive(\.itemsResponse.success) {
      $0.isLoading = false
      $0.items = [Item(id: 1, title: "Tea")]
    }
    await store.receive(\.delegate.itemCountChanged)
  }
}
```

## 3. Dependencies and clients

**D1. Every nondeterminism source is a dependency.**
- **Do:** read time, randomness, IDs and waiting through `@Dependency(\.date)`, `\.uuid`, `\.withRandomNumberGenerator`, `\.continuousClock`. Tests pin them (`.constant(...)`, `.incrementing`, `TestClock`).
- **Tell:** `Date()`, `UUID()`, `Task.sleep`, `DispatchQueue.asyncAfter`, `.random(in:)` or `SystemRandomNumberGenerator` in a Core or client-interface module; a test that passes or fails depending on the wall clock. String literals and comments that contain `Date()` don't count.
- **Enforced by:** `det.date-init`, `det.uuid-init`, `det.task-sleep`, `det.async-after`, `det.random` · **Source:** [swift-dependencies Quick start](https://github.com/pointfreeco/swift-dependencies/blob/1.17.1/Sources/Dependencies/Documentation.docc/Articles/QuickStart.md). Incident: none yet.

**D2. Every service is a `FooClient` / `FooClientLive` pair.**
- **Do:** two modules, following swift-dependencies' "Separating interface and implementation".

  | Module | Contains | May import | Imported by |
  |---|---|---|---|
  | `FooClient` | `@DependencyClient struct`, domain models, `TestDependencyKey` conformance (`testValue`, `previewValue`), `DependencyValues` accessor | Foundation, Dependencies, other interfaces | anyone |
  | `FooClientLive` | `extension FooClient: DependencyKey { static let liveValue }`, real IO, vendor SDKs | vendor SDKs, URLSession, other **interfaces** | the app target only |

  A Live module that needs UIKit declares `host_testable = false` in `.swiftgate.toml`.
- **Tell:** a feature, engine, render or library module importing a `*Live` module; a `*Live` module importing a feature; `liveValue` defined in the interface module.
- **Enforced by:** arch · **Source:** [Live, preview and test dependencies](https://github.com/pointfreeco/swift-dependencies/blob/1.17.1/Sources/Dependencies/Documentation.docc/Articles/LivePreviewTest.md). Incident: none yet.

**D3. IO and vendor SDKs live only in `*Live` modules.**
- **Do:** only Live modules touch `URLSession.shared` or import a vendor SDK listed in `[clients] vendor_modules`.
- **Tell:** `URLSession.shared` or `import DatadogRUM` (or any listed vendor) outside a `*Live` module.
- **Enforced by:** `client.urlsession-shared`, `client.vendor-module` · **Source:** [Live, preview and test dependencies](https://github.com/pointfreeco/swift-dependencies/blob/1.17.1/Sources/Dependencies/Documentation.docc/Articles/LivePreviewTest.md). Incident: none yet.

**D4. The test value fails loudly.**
- **Do:** `static let testValue = Self()` from `@DependencyClient`, so any endpoint a test didn't override fails the test. Tests override only the endpoints the behavior uses. The one exception is `LogClient` (see O1).
- **Tell:** a `@DependencyClient` type with no `TestDependencyKey` conformance; a `testValue` that returns canned data, which hides unexpected calls.
- **Enforced by:** arch (conformance present) + review (canned test values) · **Source:** [Designing dependencies](https://github.com/pointfreeco/swift-dependencies/blob/1.17.1/Sources/Dependencies/Documentation.docc/Articles/DesigningDependencies.md). Incident: none yet.

**D5. No singletons.**
- **Do:** reach shared services through `@Dependency`. Override at app launch with `prepareDependencies {}` and in previews with `#Preview(traits: .dependencies {})`.
- **Tell:** `static let shared`, a global `var`, or `.default` / `.standard` on a Foundation or vendor type used directly from Core code.
- **Enforced by:** review (`client.urlsession-shared` covers the most common case) · **Source:** [Overriding dependencies](https://github.com/pointfreeco/swift-dependencies/blob/1.17.1/Sources/Dependencies/Documentation.docc/Articles/OverridingDependencies.md). Incident: none yet.

**D6. Analytics events are typed.**
- **Do:** `AnalyticsClient.track(Event)` where `Event` is an enum with bounded names and payloads. Reducers emit events; `TestStore` tests assert them through a recording double.
- **Tell:** `track("screen_view", ["id": ...])` with a string name or an unbounded payload.
- **Enforced by:** review · **Source:** [harness design §6.1.1](superpowers/specs/2026-09-24-swift-harness-foundation-design.md) (analytics reference shape). Incident: none yet.

### Example: client pair

```swift
// Module: ItemsClient (interface). Imports only Dependencies and DependenciesMacros.
import Dependencies
import DependenciesMacros

public struct Item: Codable, Equatable, Identifiable, Sendable {
  public let id: Int
  public var title: String
  public init(id: Int, title: String) { self.id = id; self.title = title }
}

@DependencyClient
public struct ItemsClient: Sendable {
  public var fetchAll: @Sendable () async throws -> [Item]
  public var save: @Sendable (_ item: Item) async throws -> Void
}

extension ItemsClient: TestDependencyKey {
  public static let testValue = Self()
  public static let previewValue = Self(fetchAll: { [Item(id: 1, title: "Preview tea")] }, save: { _ in })
}

extension DependencyValues {
  public var itemsClient: ItemsClient {
    get { self[ItemsClient.self] }
    set { self[ItemsClient.self] = newValue }
  }
}
```

```swift
// Module: ItemsClientLive. Imported by the app target only.
import Dependencies
import Foundation
import ItemsClient

extension ItemsClient: DependencyKey {
  public static let liveValue: ItemsClient = {
    let store = ItemsFileStore(url: .documentsDirectory.appending(path: "items.json"))
    return ItemsClient(
      fetchAll: { try await store.load() },
      save: { try await store.append($0) }
    )
  }()
}

actor ItemsFileStore {
  let url: URL
  init(url: URL) { self.url = url }
  func load() throws -> [Item] {
    guard FileManager.default.fileExists(atPath: url.path()) else { return [] }
    return try JSONDecoder().decode([Item].self, from: Data(contentsOf: url))
  }
  func append(_ item: Item) throws {
    try JSONEncoder().encode(load() + [item]).write(to: url, options: .atomic)
  }
}
```

```swift
// Bad: live IO in the interface, a singleton, and a test value that never fails.
public struct ItemsClient {
  public static let shared = ItemsClient()                        // singleton
  public func fetchAll() async throws -> [Item] {
    let (data, _) = try await URLSession.shared.data(from: itemsURL)   // IO in the interface
    return try JSONDecoder().decode([Item].self, from: data)
  }
}
extension ItemsClient: TestDependencyKey {
  public static let testValue = ItemsClient()                     // calls the network in tests
}
```

## 4. Errors

**E1. Typed domain errors.**
- **Do:** each client and feature defines an error enum for failures its callers act on (`enum ItemsError: Error, Equatable { case notFound, quotaExceeded }`). Map vendor and transport errors to it in the Live module.
- **Tell:** a reducer matching on `URLError` or a vendor error type; a UI that shows `error.localizedDescription` from a transport layer.
- **Enforced by:** review · **Source:** [Error](https://developer.apple.com/documentation/swift/error). Incident: none yet.

**E2. No `try!`, `as!` or `fatalError` outside true preconditions.**
- **Do:** propagate or handle the error. A crash is acceptable only for a programmer-error invariant that a test proves, and then it carries a same-line reason.
- **Tell:** `try!` or `as!` with no same-line `swiftgate:allow`; `fatalError` on a path that input data can reach.
- **Enforced by:** `safety.try-bang`, `safety.as-bang`, `safety.fatal-error` (also `preconditionFailure`; test files exempt) · **Source:** [Error handling](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/). Incident: none yet.

**E3. `reportIssue` for programmer errors.**
- **Do:** when code reaches a state that means a bug (not bad input), call `reportIssue("…")` from `IssueReporting`. It fails the running test and logs at runtime without crashing users.
- **Tell:** `assertionFailure` or a silent `return` in a branch that should never run.
- **Enforced by:** review · **Source:** [reportIssue](https://github.com/pointfreeco/xctest-dynamic-overlay/blob/1.13.0/Sources/IssueReporting/ReportIssue.swift). Incident: none yet.

## 5. Observability

**O1. Log through `LogClient`, with privacy-tagged attributes.**
- **Do:** log a constant message plus typed attributes, each tagged `.public`, `.private` or `.sensitive`. Each module logs under its own category. `LogClientLive` fans out to OSLog (always) and to remote backends chosen at the composition root; every backend honors the tag (OSLog maps it to privacy annotations; remote backends drop or hash non-public values). Attribute construction is skipped when the level is disabled, and remote fan-out is buffered off the caller's thread. `LogClient.testValue` is a no-op, not unimplemented, because logging is everywhere and an unimplemented default would fail every test. A test that asserts a critical error path logs overrides `emit` with a recorder (example below).
- **Tell:** user data interpolated into the message string; an attribute with no privacy tag; a `String`-taking wrapper around `Logger` (it loses OSLog's compile-time redaction).
- **Enforced by:** review (shape); O3 bans the bypasses · **Source:** [Logger](https://developer.apple.com/documentation/os/logger), [OSLogPrivacy](https://developer.apple.com/documentation/os/oslogprivacy). Incident: none yet.

**O2. Span meaningful operations through `TracingClient`.**
- **Do:** wrap requests, decodes, cache lookups and other operations worth timing in `tracing.withSpan("items.fetch", attributes) { … }`. Span names are `StaticString` so the Live module can map them to `OSSignposter` intervals visible in Instruments. Live modules span their IO.
- **Tell:** a slow operation that shows up in a profile but not as a signpost interval.
- **Enforced by:** review · **Source:** [OSSignposter](https://developer.apple.com/documentation/os/ossignposter). Incident: none yet.

**O3. No direct loggers outside their Live modules.**
- **Do:** only `LogClientLive` and `TracingClientLive` touch `Logger`, `OSSignposter`, `print` or a vendor logging SDK.
- **Tell:** `Logger(subsystem:category:)`, `OSSignposter()`, or `print(` anywhere else.
- **Enforced by:** `obs.direct-logger`, `obs.direct-signposter`, `obs.print`; vendor SDK imports by `client.vendor-module` · **Source:** [Logger](https://developer.apple.com/documentation/os/logger). Incident: none yet.

### Example: structured log call

`LogClient` is a house interface (not a library API); this is its shape.

```swift
// Module: LogClient (interface)
import Dependencies
import DependenciesMacros

public enum LogLevel: Sendable, Equatable { case debug, info, notice, error, fault }

public enum LogPrivacy: Sendable, Equatable { case `public`, `private`, sensitive }

public struct LogAttribute: Sendable, Equatable {
  public let key: String
  public let value: String
  public let privacy: LogPrivacy
  public static func `public`(_ k: String, _ v: some CustomStringConvertible) -> Self { .init(key: k, value: "\(v)", privacy: .public) }
  public static func `private`(_ k: String, _ v: some CustomStringConvertible) -> Self { .init(key: k, value: "\(v)", privacy: .private) }
  public static func sensitive(_ k: String, _ v: some CustomStringConvertible) -> Self { .init(key: k, value: "\(v)", privacy: .sensitive) }
}

public struct LogRecord: Sendable, Equatable {
  public let level: LogLevel
  public let category: String
  public let message: String
  public let attributes: [LogAttribute]
}

@DependencyClient
public struct LogClient: Sendable {
  public var isEnabled: @Sendable (_ level: LogLevel, _ category: String) -> Bool = { _, _ in false }
  public var emit: @Sendable (_ record: LogRecord) -> Void
}

extension LogClient {
  // `message` is a StaticString so user data can only enter through tagged attributes.
  public func log(_ level: LogLevel, _ message: StaticString, category: String,
                  _ attributes: @autoclosure () -> [LogAttribute] = []) {
    guard isEnabled(level, category) else { return }
    emit(LogRecord(level: level, category: category, message: "\(message)", attributes: attributes()))
  }
}

extension LogClient: TestDependencyKey {
  public static let testValue = Self(isEnabled: { _, _ in true }, emit: { _ in })
}

extension DependencyValues {
  public var logClient: LogClient {
    get { self[LogClient.self] }
    set { self[LogClient.self] = newValue }
  }
}
```

```swift
// Good: constant message, every value tagged.
@Dependency(\.logClient) var log
log.log(.error, "checkout failed", category: "Checkout", [
  .public("reason", error.code),
  .private("orderId", order.id),
  .sensitive("email", customer.email),
])

// Bad: print bypasses every backend and writes the email in clear text.
print("checkout failed for \(customer.email) order \(order.id)")
// Bad: direct Logger outside LogClientLive never reaches the remote backends.
Logger(subsystem: "app", category: "Checkout").error("checkout failed")
// Won't compile, by design: the message is a StaticString, so values must be tagged attributes.
log.log(.error, "checkout failed for \(customer.email)", category: "Checkout")
```

A test that asserts a critical path logs overrides `emit` with a recorder ([LockIsolated](https://github.com/pointfreeco/swift-concurrency-extras/blob/1.4.1/Sources/ConcurrencyExtras/LockIsolated.swift)):

```swift
let records = LockIsolated<[LogRecord]>([])
let store = TestStore(initialState: CheckoutFeature.State()) { CheckoutFeature() } withDependencies: {
  $0.logClient.emit = { record in records.withValue { $0.append(record) } }
}
// ... drive the failure ...
#expect(records.value.contains { $0.level == .error && $0.category == "Checkout" })
```

## 6. SwiftUI performance

**U1. Stable identity.**
- **Do:** `ForEach` / `List` over `Identifiable` data with IDs that survive refreshes.
- **Tell:** `ForEach(items.indices, id: \.self)`; `id: \.self` on mutable values; rows losing state on refresh.
- **Enforced by:** review · **Source:** [Demystify SwiftUI (WWDC21)](https://developer.apple.com/videos/play/wwdc2021/10022/). Incident: none yet.

**U2. No `AnyView`.**
- **Do:** use `@ViewBuilder`, `some View`, or an enum-switching view.
- **Tell:** `AnyView(` anywhere in UI code.
- **Enforced by:** review · **Source:** [AnyView](https://developer.apple.com/documentation/swiftui/anyview). Incident: none yet.

**U3. Lazy containers for long content.**
- **Do:** `List`, `LazyVStack`, `LazyHStack`, `LazyVGrid` for content that can grow past a screen.
- **Tell:** `ScrollView { VStack { ForEach(...) } }` over unbounded data.
- **Enforced by:** review · **Source:** [LazyVStack](https://developer.apple.com/documentation/swiftui/lazyvstack). Incident: none yet.

**U4. Granular observation.**
- **Do:** pass child views the scoped store or the values they read, so a change re-renders only what depends on it.
- **Tell:** a leaf row holding the whole parent store; a body that reads many unrelated state fields.
- **Enforced by:** review (profiling arrives in a later harness release) · **Source:** [Demystify SwiftUI performance (WWDC23)](https://developer.apple.com/videos/play/wwdc2023/10160/). Incident: none yet.

## 7. Accessibility

**X1. Interactive elements carry an identifier and a label.**
- **Do:** every `Button`, `Toggle`, text field and tappable row has `.accessibilityIdentifier("screen.element")` and a readable label (visible text, or `.accessibilityLabel` for icon-only controls).
- **Tell:** an icon-only button with no label; a UI test that locates an element by its title text.
- **Enforced by:** review (no `swiftgate lint` rule is assigned yet) · **Source:** [accessibilityIdentifier(_:)](https://developer.apple.com/documentation/swiftui/view/accessibilityidentifier(_:)). Incident: none yet.

## 8. Engine modules

**G1. Engines are pure and replayable.**
- **Do:** `step(state, input, rng:) -> State` with a fixed timestep and an injected, seeded RNG. No clock reads, no globals. Every engine module has a replay test: seed + input log gives an identical final state across runs.
- **Tell:** a `Date()` or `CACurrentMediaTime()` in the step; a `dt` taken from the frame callback; two replays of the same log that disagree.
- **Enforced by:** `det.*` rules + review; the replay test is required by the testing playbook · **Source:** [RandomNumberGenerator](https://developer.apple.com/documentation/swift/randomnumbergenerator). Incident: none yet.

```swift
public struct SplitMix64: RandomNumberGenerator, Sendable {
  private var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

public enum Physics {
  public static let dt = 1.0 / 60.0

  public static func step(_ state: World, _ input: Input, rng: inout some RandomNumberGenerator) -> World {
    var next = state
    next.apply(input)
    next.advance(by: dt)
    if next.needsSpawn { next.spawn(at: .random(in: next.spawnRange, using: &rng)) }
    return next
  }
}
```

```swift
@Test("replaying seed + input log gives identical worlds — catches nondeterminism in step()")
func replayIsDeterministic() throws {
  let log = try InputLog.load(fixture: "level1-run")
  func replay() -> World {
    var rng = SplitMix64(seed: 42)
    return log.inputs.reduce(World.level1) { Physics.step($0, $1, rng: &rng) }
  }
  #expect(replay() == replay())
}

// Bad: wall-clock timestep and unseeded randomness make replays diverge.
next.advance(by: CACurrentMediaTime() - lastFrame)
next.spawn(at: .random(in: next.spawnRange))
```

## 9. Comments

**K1. Delete comments that the code already says.**
- **Do:** keep a comment only when deleting it loses a fact a reader can't get back from the code: a non-obvious *why*, a footgun warning, a suppression justification, or a `///` contract on `public` / `package` API. Always kept: `// MARK:`, `#warning`, `@available(..., message:)`.
- **Tell:** a comment above an `if` / `guard` / `return` / `catch` that restates it; blocks over 3 lines; arrange/act/assert labels inside tests (the `@Test` name carries the meaning); `///` on a trivial private declaration; AI-prose tells ("it's worth noting", "importantly").
- **Enforced by:** `swiftgate comments --staged` warns (never blocks); a judgment pass reviews Claude-authored commits · **Source:** [harness design §7.5](superpowers/specs/2026-09-24-swift-harness-foundation-design.md). Incident: none yet.

**K2. No history, no dead code, no private context.**
- **Do:** history goes in commit messages. Link a `TODO`/`FIXME` to an issue. Use repo-relative references only.
- **Tell:** commented-out code; "previously", "now uses", "switched from", "this PR", "fixed bug where"; line-number references; `TODO` with no issue link; local machine paths or private codenames.
- **Enforced by:** `swiftgate comments --staged`, blocking, on added lines at every commit · **Source:** [harness design §7.5](superpowers/specs/2026-09-24-swift-harness-foundation-design.md). Incident: none yet.

```swift
// Good: a fact the code can't give back.
// The API returns prices in minor units for every currency except JPY.
let amount = currency == .jpy ? raw : raw / 100

// Bad: restates the code, narrates history, dead code.
// Check if the list is empty
// Switched from filter to first(where:) in this PR
// let old = items.filter { $0.isActive }
if items.isEmpty { return }
```

## 10. Checker hygiene

**H1. Every mechanical rule has a seeded violation.**
- **Do:** each `swiftgate` rule ships `bad/` and `good/` fixtures; `swiftgate self-test` proves every rule fires on `bad` and stays quiet on `good`.
- **Tell:** a rule id with no fixture directory; `self-test` passing after a rule's visitor is deleted.
- **Enforced by:** `swiftgate self-test` · **Source:** harness design (a check that can't fail proves nothing). Incident: none yet.

## Rule id index

Every rule id `swiftgate` can report. `P<n>` and `§<n>` in the playbook column cite [testing-playbook.md](testing-playbook.md). A test checks this table against the rule registries, so an id is added here in the same change that adds the rule.

### Code rules (`lint`, `arch`, `comments`, `testlint`)

| Rule id | Section |
|---|---|
| `det.date-init`, `det.uuid-init`, `det.task-sleep`, `det.async-after`, `det.random` | D1, G1 |
| `client.urlsession-shared`, `client.vendor-module` | D3, D5, O3 |
| `obs.direct-logger`, `obs.direct-signposter`, `obs.print` | O3 |
| `safety.try-bang`, `safety.as-bang`, `safety.fatal-error` | E2 |
| `safety.unchecked-sendable`, `safety.nonisolated-unsafe`, `safety.preconcurrency` | C2 |
| `tca.banned-api` | A6 |
| `snap.record-mode` | playbook P4 |
| `arch.undeclared-kind`, `arch.config-module-mismatch` | A1, A3 |
| `arch.ui-framework-in-core` | A2 |
| `arch.core-main-actor-isolation` | C5 |
| `arch.live-dependency`, `arch.live-depends-on-feature`, `arch.vendor-dependency` | D2, D3 |
| `arch.dependency-client-test-value` | D4 |
| `arch.engine-replay-test` | G1, playbook P10 |
| `comments.restates-code`, `comments.long-block`, `comments.test-body`, `comments.trivial-private-doc`, `comments.ai-prose` | K1 |
| `comments.commented-out-code`, `comments.diff-narration`, `comments.line-reference`, `comments.todo-without-link`, `comments.private-reference` | K2 |
| `comments.unjustified-suppression` | [Escape hatches](#escape-hatches), C2, E2 |
| `test.unnamed` | playbook P1 |
| `test.no-assertion`, `test.tautology`, `test.existence-only`, `test.asserts-own-double`, `test.duplicate` | playbook §5.1 |
| `test.non-exhaustive-store` | playbook P5 |
| `test.testclock-serialized` | playbook P6 |
| `test.sleep`, `test.swallowed-error` | playbook P7, D1 |
| `test.misplaced-t2` | playbook §4 |
| `test.xcuitest-unlisted-flow` | playbook P11 |

### Test evidence (`test`, `check`)

| Rule id | Section |
|---|---|
| `t1.test-failed`, `t1.crashed`, `t1.build-failed`, `t1.skip-without-reason`, `t1.no-tests`, `t1.no-evidence`, `t1.runner` | playbook P3 |
| `t2.test-failed`, `t2.crashed`, `t2.build-failed`, `t2.skip-without-reason`, `t2.no-tests`, `t2.no-evidence`, `t2.runner` | playbook P3 |
| `t3.test-failed`, `t3.crashed`, `t3.build-failed`, `t3.skip-without-reason`, `t3.no-tests`, `t3.no-evidence`, `t3.runner` | playbook P3 |
| `t3.unmapped-flow`, `t3.flow-untested`, `t3.max-flows`, `t3.app-container` | playbook P11 |
| `sim.retry-configured` | playbook P3 (a retried test hides a flake) |
| `snapshots.recorded` | playbook P4 (`snapshots record`) |
| `impact.untested-change` | playbook P9 |
| `coverage.diff`, `coverage.uncovered-lines`, `coverage.no-data`, `coverage.no-t1-tests`, `coverage.summary` | playbook §4 |
| `prove.not-proven`, `prove.compile-only`, `prove.crashed`, `prove.fails-at-head`, `prove.no-evidence`, `prove.summary` | playbook P2 |
| `stress.failed`, `stress.crashed`, `stress.no-evidence` | playbook P8 |
| `reach.no-production-lines`, `reach.fails-alone`, `reach.no-data`, `changed-tests.summary` | playbook §5.2 |
| `mutate.survived`, `mutate.killed`, `mutate.unviable`, `mutate.no-evidence`, `mutate.bare-equivalent`, `mutate.summary` | playbook §5.2 |
| `judge.fails-if-broken`, `judge.tier`, `judge.name-specificity`, `judge.asserts-implementation`, `judge.not-run` | playbook §5.4 |
| `judge.loses-fact`, `judge.right-size` | K1 (the commit-comment judge) |

### Harness and environment

| Rule id | Section |
|---|---|
| `format.parse`, and `format.<rule>` for each `swift format lint --strict` rule | [Platform and toolchain](#platform-and-toolchain) |
| `swiftgate.allow-missing-reason` | [Escape hatches](#escape-hatches) |
| `swiftgate.config`, `swiftgate.environment`, `swiftgate.scopes-fallback`, `swiftgate.not-run`, `swiftgate.nothing-selected`, `swiftgate.budget` | the gate's own notes: an invalid `.swiftgate.toml` is RED, a missing tool or input is BLOCKED, the rest never gate |
| `swiftgate.self-test`, `swiftgate.self-test.judge`, `swiftgate.self-test.judge-metrics` | H1 |
| `doctor.xcode-pin`, `doctor.toolchain`, `doctor.simulator-runtime`, `doctor.disk`, `doctor.shim`, `doctor.swiftlint`, `doctor.issue-reporting`, `doctor.upgrade-hazard` | `swiftgate doctor`; [Toolchain hazards](#toolchain-hazards) |
| `guard.raw-xcodebuild`, `guard.simctl-all`, `guard.snapshot-record`, `guard.global-derived-data`, `guard.snapshot-reference`, `guard.package-resolved`, `guard.xcresult`, `guard.plan-state` | [hooks.md](hooks.md) (PreToolUse guards) |
