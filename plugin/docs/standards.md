# Swift standards

The rules every module in a swift-harness app follows. Each rule has the same shape:

- **Do** — what to write.
- **Tell** — how you (or a reviewer) can see the rule was broken.
- **Enforced by** — a `swiftgate` rule id (`swiftgate lint` / `swiftgate arch` / `swiftgate comments`), `arch` (a module-graph check in `swiftgate arch`), or `review` (human or review-agent judgment).
- **Source** — the upstream doc or issue behind the rule, plus the production incident that justifies it. Until a rule has an incident it says "incident: none yet".

The testing rules (tiers, red/green, snapshots, flake stress) live in the testing playbook, not here.

## 0. Baseline

### Platform and toolchain

Swift 6 language mode (complete concurrency checking), iOS 18+, SwiftUI. Xcode 26.2 / Swift 6.2.3, pinned in `.swiftgate.toml` (major.minor: a pin of `26.2` accepts `26.2.x`, never `26.4`). A selected Xcode that doesn't match the pin ends `swiftgate doctor` BLOCKED, and every `test`/`check` tier that builds or runs Swift BLOCKED with `doctor.xcode-pin`. T0's lint-only checks parse source with SwiftSyntax and never touch the toolchain, so they still run. The app is a thin app target plus local Swift packages. Core packages declare `.macOS` so `swift test` runs on the host.

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
- **Enforced by:** arch (package manifest default isolation) + review (`@MainActor` on the UI types) · **Source:** [TCA #3768](https://github.com/pointfreeco/swift-composable-architecture/issues/3768). Incident: none yet.

**C6. Never block a cooperative-pool thread.**
- **Do:** await, or run blocking work on a thread of its own.
- **Tell:** `waitUntilExit()`, a semaphore `wait` or blocking `flock` in async code or tests.
- **Enforced by:** `safety.blocking-in-async` · **Source:** [Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/). Incident: 2026-10-04, starved gate tests.

## 2. Architecture

Every module keeps three invariants: logic lives in a platform-neutral, host-testable Core module and the UI module is thin; every source of nondeterminism is a dependency; Core tests run under `swift test` on the host in seconds.

| Kind | Core shape | Use when |
|---|---|---|
| `feature` (default) | TCA reducer + `TestStore` | Event-driven screens and flows |
| `engine` | Pure `(State, Input) -> State`, seeded RNG, fixed timestep | Real-time loops (above ~30 Hz), hot pipelines |
| `render` | SpriteKit / `Canvas` / Metal reading engine state; no rules | Rendering layers |
| `library` | Plain Swift | Shared utilities |
| `client` | `FooClient` / `FooClientLive` pair (section 3) | Services: networking, images, analytics, persistence, keychain, auth, flags, push, location |
| `test-support` | Test doubles and fixtures (`FooClientTestSupport`); only test targets may depend on it | Helpers shared across test targets; exempt from T1 presence and diff coverage |

**A1. Declare every non-TCA Core.**
- **Do:** a Core that isn't a TCA feature gets a `[[modules]]` entry in `.swiftgate.toml` with a `kind` and a `reason`. Pick a non-`feature` kind when you see per-frame updates, render loops, high-rate sensor/audio/camera streams, thin SDK wrappers where a reducer is pure ceremony, or store overhead in a profile.
- **Tell:** a Core module with no `@Reducer` and no config entry.
- **Enforced by:** arch · **Source:** [TCA Performance](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/Sources/ComposableArchitecture/Documentation.docc/Articles/Performance.md). Incident: none yet.

**A2. Core imports no UI framework.**
- **Do:** Core modules import Foundation, TCA, Dependencies and other Cores/interfaces only.
- **Tell:** `import SwiftUI` or `import UIKit` in a Core module; a Core test that needs a simulator.
- **Enforced by:** arch · **Source:** harness design §6.1 (host-testable Core). Incident: none yet.

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
- **Enforced by:** review · **Source:** harness design §6.1.1 (analytics reference shape). Incident: none yet.

**D7. Live clients perform IO and map to domain models; nothing else.**
- **Do:** a `*Live` module sends the request, decodes the response, and maps it (and its errors, per E1) to the interface's domain models. Business rules and transformations (filtering, truncating, sorting, thresholds, defaults, fallbacks, formatting for display) live in a Core feature or a library module, where host tests cover them without a transport double.
- **Tell:** a `*Live` endpoint that changes the domain value after decoding: `.prefix(n)`, `.filter`, a length or count check, a hard-coded fallback value, a computed display string; a product rule change that means editing a Live module.
- **Enforced by:** review (architecture reviewer) · **Source:** [Live, preview and test dependencies](https://github.com/pointfreeco/swift-dependencies/blob/1.17.1/Sources/Dependencies/Documentation.docc/Articles/LivePreviewTest.md): the live value is the dependency's real-world implementation, so logic in it is replaced wholesale by every test and preview value and never runs under `TestStore`. Incident: none yet.

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

**U5. Views compile on the host.**
- **Do:** keep a UI module's views compiling on the macOS host; wrap only the iOS-only modifiers or types in `#if os(iOS)`.
- **Tell:** a UI file whose every declaration sits inside `#if os(iOS)` or `#if canImport(UIKit)`, with nothing in a `#else`. It builds as an empty module on the host, so only the app build or T3 finds its compile errors.
- **Enforced by:** `arch` `arch.ui-host-compiled`, reported at the `#if`. A file that can't compile on the host at all carries `// swiftgate:allow arch.ui-host-compiled — <reason>` on that `#if` line · **Source:** [Conditional compilation block](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/statements/#Conditional-Compilation-Block): the compiler skips a branch whose condition is false. Incident: none yet.

## 7. Accessibility

**X1. Interactive elements carry an identifier and a label.**
- **Do:** every `Button`, `Toggle`, text field and tappable row has `.accessibilityIdentifier("screen.element")` and a readable label (visible text, or `.accessibilityLabel` for icon-only controls).
- **Tell:** an icon-only button with no label; a UI test that locates an element by its title text.
- **Enforced by:** `sim verify` `sim.a11y-identifier` and `sim.a11y-label`, on each QA step's tree · **Source:** [accessibilityIdentifier(_:)](https://developer.apple.com/documentation/swiftui/view/accessibilityidentifier(_:)). Incident: none yet.

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
- **Enforced by:** `swiftgate comments --staged` warns (never blocks); a judgment pass reviews Claude-authored commits · **Source:** harness design §7.5. Incident: none yet.

**K2. No history, no dead code, no private context.**
- **Do:** history goes in commit messages. Link a `TODO`/`FIXME` to an issue. Use repo-relative references only.
- **Tell:** commented-out code; "previously", "now uses", "switched from", "this PR", "fixed bug where"; line-number references; `TODO` with no issue link; local machine paths or private codenames.
- **Enforced by:** `swiftgate comments --staged`, blocking, on added lines at every commit · **Source:** harness design §7.5. Incident: none yet.

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

Every rule id `swiftgate` can report. `P<n>` and `§<n>` cite [testing-playbook.md](testing-playbook.md). A test checks it against the rule registries, so add each id with its rule.

### Code rules (`lint`, `arch`, `comments`, `testlint`)

| Rule id | Section |
|---|---|
| `det.date-init`, `det.uuid-init`, `det.task-sleep`, `det.async-after`, `det.random` | D1, G1 |
| `client.urlsession-shared`, `client.vendor-module` | D3, D5, O3 |
| `obs.direct-logger`, `obs.direct-signposter`, `obs.print` | O3 |
| `safety.try-bang`, `safety.as-bang`, `safety.fatal-error` | E2 |
| `safety.unchecked-sendable`, `safety.nonisolated-unsafe`, `safety.preconcurrency` | C2 |
| `safety.blocking-in-async` | C6 |
| `tca.banned-api` | A6 |
| `snap.record-mode` | playbook P4 |
| `arch.undeclared-kind`, `arch.config-module-mismatch` | A1, A3 |
| `arch.test-support-dependency` | A1 |
| `arch.ui-framework-in-core` | A2 |
| `arch.ui-host-compiled` | U5 |
| `arch.core-main-actor-isolation` | C5 |
| `arch.live-dependency`, `arch.live-depends-on-feature`, `arch.vendor-dependency` | D2, D3 |
| `arch.dependency-client-test-value` | D4 |
| `arch.engine-replay-test` | G1, playbook P10 |
| `sim.scenario-drift` | simulator QA design §6 (the app's `Scenario` enum mirrors `[[scenarios]]`) |
| `comments.restates-code`, `comments.long-block`, `comments.test-body`, `comments.trivial-private-doc`, `comments.ai-prose` | K1 |
| `comments.commented-out-code`, `comments.diff-narration`, `comments.line-reference`, `comments.todo-without-link`, `comments.private-reference` | K2 |
| `comments.unjustified-suppression` | [Escape hatches](#escape-hatches), C2, E2 |
| `comments.leaked-id` | design plan workflows §5.1 (id policy) |
| `test.unnamed` | playbook P1 |
| `test.no-assertion`, `test.tautology`, `test.existence-only`, `test.asserts-own-double`, `test.duplicate` | playbook §5.1 |
| `test.non-exhaustive-store` | playbook P5 |
| `test.testclock-serialized` | playbook P6 |
| `test.sleep`, `test.swallowed-error` | playbook P7, D1 |
| `test.misplaced-t2` | playbook §4 |
| `test.xcuitest-unlisted-flow` | playbook P11 |
| `test.leaked-id` | design plan workflows §5.1 (id policy) |
| `test.hang-without-deadline` | playbook P12 |
| `test.unbounded-wait` | playbook P12 |

### Test evidence (`test`, `check`)

| Rule id | Section |
|---|---|
| `t1.test-failed`, `t1.crashed`, `t1.build-failed`, `t1.skip-without-reason`, `t1.no-tests`, `t1.no-evidence`, `t1.runner` | playbook P3 |
| `t2.test-failed`, `t2.crashed`, `t2.build-failed`, `t2.skip-without-reason`, `t2.no-tests`, `t2.no-evidence`, `t2.runner` | playbook P3 |
| `t3.test-failed`, `t3.crashed`, `t3.build-failed`, `t3.skip-without-reason`, `t3.no-tests`, `t3.no-evidence`, `t3.runner` | playbook P3 |
| `t3.unmapped-flow`, `t3.flow-untested`, `t3.max-flows`, `t3.app-container` | playbook P11 |
| `app-build.error`, `app-build.blocked`, `app-build.container`, `app-build.summary` | `check --app-build`: a compile error in the app scheme's generic simulator build is RED, a failed build with no readable build results is BLOCKED, more than one root app container is RED |
| `sim.retry-configured` | playbook P3 (a retried test hides a flake) |
| `snapshots.recorded` | playbook P4 (`snapshots record`) |
| `impact.untested-change` | playbook P9 |
| `coverage.diff`, `coverage.uncovered-lines`, `coverage.no-data`, `coverage.no-t1-tests`, `coverage.summary` | playbook §4 |
| `prove.not-proven`, `prove.compile-only`, `prove.crashed`, `prove.hangs-at-base`, `prove.fails-at-head`, `prove.no-evidence`, `prove.summary` | playbook P2 |
| `stress.failed`, `stress.crashed`, `stress.no-evidence` | playbook P8 |
| `reach.no-production-lines`, `reach.fails-alone`, `reach.no-data`, `changed-tests.summary` | playbook §5.2 |
| `mutate.survived`, `mutate.killed`, `mutate.unviable`, `mutate.no-evidence`, `mutate.bare-equivalent`, `mutate.summary` | playbook §5.2 |
| `judge.fails-if-broken`, `judge.tier`, `judge.name-specificity`, `judge.asserts-implementation`, `judge.not-run`, `judge.blocked` | playbook §5.4. At `ready` with `backend = "jev"`, a Jev call that gives no answer (missing key, transport or parse error after 1 retry 750 ms later, refusal) sends the test's blocking questions to Claude, and a minor `judge.not-run` says how many tests it failed for; `judge.blocked` (minor, the step and T1 BLOCKED, exit 2 from `judge tests --ready` and `check --tier ready` alike, with the `judge.not-run` note beside it) names both errors when Claude can't answer either. Below `ready` a Jev failure is only the `judge.not-run` note |
| `judge.loses-fact`, `judge.right-size` | K1 (the commit-comment judge) |
| `judge-events.unwritten` | playbook §5.4: the judge's events couldn't be written; a nit, the verdict stands |

### Harness and environment

| Rule id | Section |
|---|---|
| `format.parse`, and `format.<rule>` for each `swift format lint --strict` rule | [Platform and toolchain](#platform-and-toolchain) |
| `swiftgate.allow-missing-reason` | [Escape hatches](#escape-hatches) |
| `sim.base-ambiguous` | simulator QA amendment §8.3; several devices match the base: a nit naming each UDID, lowest used. `doctor` reports it |
| `swiftgate.config`, `swiftgate.environment`, `swiftgate.scopes-fallback`, `swiftgate.not-run`, `swiftgate.nothing-selected`, `swiftgate.budget` | the gate's own notes: an invalid `.swiftgate.toml` is RED, a missing tool or input is BLOCKED, the rest never gate |
| `gate.reused` | a GREEN brownfield gate reused for identical inputs; never gates |
| `swiftgate.resolved-file-rewritten` | every `swift build`/`swift test`/`xcodebuild` invocation a gate run makes is pinned to the committed `Package.resolved` (`--only-use-versions-from-resolved-file`, `-onlyUsePackageVersionsFromResolvedFile`); as a backstop, `swiftgate check`/`test`/etc. hash every `Package.resolved` in the working tree before and after the run, and a change gates major — the same edit `guard.package-resolved` denies by hand must never happen silently by machine |
| `swiftgate.resolved-file-stale` | that same pin rejects a manifest the committed `Package.resolved` doesn't cover (a dependency added with no committed `Package.resolved` at all, or one the manifest has outrun): major, named apart from `t1.no-evidence`, with the fix in the message (`swift package resolve` in the package directory, then commit `Package.resolved`) |
| `evidence-check.stale-claim`, `evidence-check.status-unknown`, `evidence-check.blocked`, `evidence-check.summary` | design plan workflows §5.4; `check --tier push` re-checks every `approved`/`built` design's claims at `HEAD` through `evidence check`'s own code path. A stale or failing claim gates, as does a status that's neither `proposed`, `approved`, `built` nor `superseded-by: <slug>`, and so does a design `evidence check` couldn't run for at all (missing evidence, an unreadable doc, a bad ref) — never a quiet pass; only the found/checked count is a non-gating note |
| `calibration-freshness.stale`, `calibration-freshness.no-record`, `calibration-freshness.unreadable`, `calibration-freshness.summary` | design plan workflows §6.2, build executor §12; `check --tier push` compares `plugin/gate/Fixtures/calibrate-design/last-pass.json` with the content hash of `plugin/agents/design-*.md` and `plugin/workflows/design-*.js`, and `plugin/gate/Fixtures/calibrate-build/last-pass.json` with that of `plugin/agents/build-worker.md` and `plugin/agents/build-fixer.md`. A prompt changed since its suite's last pass, a missing or undecodable record, or a prompt that can't be read gates until `swiftgate calibrate design` or `calibrate build` passes again; a suite with no agent in the repository is skipped with a non-gating note |
| `calibration-freshness.wrong-model` | design plan workflows §6.2, Jev judge backend §10.8; `check --tier push` gates a calibration record whose case ran on another model than its agent's frontmatter names, an agent with no case, any `--model` override, or a judge other than the shipped `claude/sonnet`, naming both judges. It also gates a record whose requested model served other ids in the pass than a kept reply under `.harness/runs/` from a run started since says it serves now, naming the alias, both ids and the run |
| `plan-lint.write-set-unresolved` | design plan workflows §9.3; `plan-lint` fails (major) a task's write-set entry under a package's `Sources/<Name>/` or `Tests/<Name>/` that no module in the graph holds and the design's Module kinds table doesn't name, naming the task and the entry. The module count and the worker pack's standards would otherwise skip it. A doc or manifest entry is no module entry |
| `plugin-validate.failed`, `plugin-validate.not-run`, `plugin-validate.accepted-warning`, `plugin-validate.summary` | `check --tier ready` in a repository that ships a Claude Code plugin in `plugin/` runs `claude plugin validate --strict --json plugin`. Every error or warning gates, and so does output that isn't a validation report, except one: the manifest's `version` warning in the validator's exact wording ("No version specified. Consider adding a version following semver") while `plugin-version` finds no version pinned, which is a non-gating `accepted-warning` note naming it. A reworded version warning gates. Without `claude` on `PATH`, or when it can't run, the step is a non-gating note, never BLOCKED |
| `plugin-version.pinned`, `plugin-version.malformed`, `plugin-version.summary` | `check --tier push` in a repository that ships a Claude Code plugin in `plugin/` gates a `version` in `plugin/.claude-plugin/plugin.json` or in that plugin's entry in `.claude-plugin/marketplace.json`. Without one, Claude Code versions an install by the marketplace commit, so `claude plugin update` refreshes it on every commit; a pinned version holds installs until someone raises it. A manifest that can't be read or parsed gates as `malformed`. A repository with no plugin manifest is skipped |
| `surface-check.behaviour`, `surface-check.summary` | fast modes §3.2; `swiftgate surface-check <commit>` judges every body the commit adds or changes against its first parent. Each must be empty, return 1 empty default (`nil`, `[]`, `[:]`, `0`, `false`, `""`, `.init()`) or payload-free enum case, build 1 value from an initializer call with only empty defaults and pass-through parameters, or forward to code the parent declares. An initializer may assign its parameters or empty defaults to stored properties, and an existing array literal may gain bare type references or `Type.self`; a reducer returns `.none` for every action, a SwiftUI `body` is `EmptyView()` or a container of it. A trap, a preview with non-empty sample data, a changed existing stored value or an added test is a major `behaviour` finding; a commit or parent that can't be read is BLOCKED, never GREEN |
| `comments.id-source-unreadable` | design plan workflows §5.1 (id policy); a ledger, claims file or doc that exists but doesn't parse — never gates, but a corrupt source is never silent either |
| `evidence-cache.corrupt-line` | design plan workflows §8.6 (reuse cache); a reuse-cache line that doesn't decode is named, never skipped silently |
| `swiftgate.self-test`, `swiftgate.self-test.judge`, `swiftgate.self-test.judge-metrics`, `swiftgate.self-test.judge-stale` | H1 |
| `build-return.branch-missing`, `build-return.no-commits`, `build-return.commit-missing`, `build-return.commit-off-branch`, `build-return.gate-missing`, `build-return.gate-run-missing`, `build-return.gate-verdict-mismatch`, `build-return.gate-tier-mismatch`, `build-return.gate-not-green`, `build-return.gate-below-task-gate`, `build-return.gate-red-outcome-is-green`, `build-return.review-missing`, `build-return.design-conflict-outcome`, `build-return.design-conflict-unrecorded`, `build-return.design-conflict-unreturned`, `build-return.design-conflict-mismatch`, `build-return.outside-write-set`, `build-return.gate-missing-proof`, `build-return.surface-commit-off-branch`, `build-return.surface-commit-not-proof-base`, `build-return.outside-write-set-unexplained`, `build-return.gate-missing-step` | build executor §5.3; `swiftgate build check-return` checks a task return against git and the run store and exits 1 on any of these. `build-return.gate-missing-step` names each step a worker's green gate run never ran, read from the run's tier and recorded steps: `impact`, `coverage` and `app-build` at an owned task gate, and at a `slice`, `merge` or `final` task gate only the steps that tier runs itself; a fixer's merge gate is exempt |
| `sprint.out-of-order`, `sprint.invalid-slug`, `sprint.invalid-spec-page`, `sprint.invalid-commit`, `sprint.invalid-gate-run`, `sprint.invalid-slice-count`, `sprint.spec-page-missing`, `sprint.main-not-green`, `sprint.branch-exists`, `sprint.wrong-branch`, `sprint.surface-off-branch`, `sprint.surface-behaviour`, `sprint.surface-unreadable`, `sprint.gate-unknown`, `sprint.gate-tier`, `sprint.gate-not-ready`, `sprint.gate-red`, `sprint.gate-blocked`, `sprint.gate-stale`, `sprint.gate-proof-base`, `sprint.main-moved`, `sprint.not-fast-forward`, `sprint.main-checked-out`, `sprint.history-unreadable`, `sprint.state-malformed`, `sprint.state-locked`, `sprint.state-io`, `sprint.common-directory`, `sprint.git` | fast modes §4.2; each `swiftgate sprint` command checks its step before sprint.json records it, and a refusal names what to do. `start` needs a GREEN push gate at `main`'s HEAD, an existing spec page and a new `sprint/<slug>`; `surface` needs the first commit on the branch, with no `surface-check` finding but its summary; `slice` and `finish` read the gate run from this checkout's run history by id and need it GREEN at the branch HEAD, `push` or above for a slice, and `ready` proved at the sprint's surface to finish; `finish` fast-forwards `main` only from the sprint's base and only when no worktree has it checked out. Every command acts only from a checkout on its sprint's branch. A refusal exits 1; `surface-unreadable`, `history-unreadable`, `state-*`, `common-directory` and `git` exit 2, since the state, history or git couldn't be read |
| `sprint.gate-base` | fast modes §4.1-4.2; `sprint slice` needs its gate run's history line to record `base`, the sha `check --base` resolved to, as the sprint's surface, so a slice's diff coverage counts only lines changed since the surface and not the stubs a later slice fills. A line with no `base`, or another one, is refused; `finish` still reads a `ready` run at `--base main`, so every line the sprint changed is covered once. Exits 1 |
| `sprint.target-outside-surface` | fast modes §4.2; `sprint slice` reads every `Package.swift` that differs between the sprint's surface and the branch HEAD, and refuses when HEAD declares a target or product the surface doesn't, or adds a package: at the surface that target has no sources, so SwiftPM refuses the package and every test in it or a dependent is `prove.compile-only` at the `ready` gate. Test targets are exempt, since `prove` keeps tests. A manifest it can't read at either commit (a syntax error, a `targets:` or `products:` that isn't an array of `.factory(name: "…")` calls, or a list changed after `Package(…)`) is refused too, named. The message names each package, target and product, and the fix: amend the surface with a stub for each and rebuild the slices on it. Exits 1 |
| `build-return.target-outside-surface` | fast modes §5.1, §3.3; for a plan whose plan.json records a `surfaceCommit`, `swiftgate build check-return` reads every `Package.swift` the task branch changed, at the plan surface and at the branch tip, and fails when the tip declares a non-test target or product the surface doesn't, adds a package the surface lacks, or holds a manifest it can't read at either commit (the same reader as `sprint.target-outside-surface`). At the surface a new target has no sources, so the final gate's `prove` can build no test in its package or a dependent. 1 finding per manifest, naming the package and each target and product, and the fix: a design conflict, since the surface needs a stub target. A plan with no surface, or a missing plan.json (named in `warnings`), is not checked. Exits 1 |
| `build-return.test-needs-stub` | fast modes §5.1, §3.3 (the user's choice of 2026-09-29: new API a task's tests call, under `task_proof = "final"`); for a plan whose plan.json records a `surfaceCommit`, `swiftgate build check-return` builds the host tests the task branch adds or changes in a scratch tree of the branch tip, with the production source it changed since the plan surface reverted to each proof base in turn: the plan surface, each merged task's stub that is an ancestor of the tip (as `build proof-bases` lists them), then the return's own `surfaceCommit`. A test file that compiles at none of them is 1 finding naming the file, its first compiler error and the fix: commit the API it calls as a stub, check it with `swiftgate surface-check <sha>`, prove at it and return it as `surfaceCommit`. The final gate's `prove` would judge it compile-only. A plan with no surface, a return that changes no host test or no production source, or a missing plan.json is not built; a build that says nothing about the tests (it fails outside them, or leaves no report), or a module graph it can't load, is a named warning. A task worktree not at its branch tip, or a plan surface that isn't an ancestor of the branch, exits 2. Exits 1 |
| `build-return.stale-gate` | brownfield trial memos-5 finding 2; `swiftgate build check-return` fails a `ready-to-merge` or `review-blocked` return whose cited gate run, as the task worktree's run history records it, started at another commit than the return's last commit, or on a tree with uncommitted changes outside the harness's own state, or whose history line records neither (a line written before the run history kept `dirty`). A gate run there measured some other tree than the one `build merge` merges. 1 finding per cause, naming the run, its head and the return's last commit. Exits 1 |
| `build-return.tests-not-run` | brownfield trial price-tracker-1 finding 2; `swiftgate build check-return` fails a `ready-to-merge` or `review-blocked` return whose task branch adds or changes a test file, still declaring a test at its tip, in an area whose `test_files` narrows a run to the changed tests, when the cited gate run, as the task worktree's run history records it, ran no `area-test` step for that area (or its history line doesn't record which areas it tested). `slice` runs such an area's changed tests even when its whole suite is over the budget. 1 finding per area. A test in an area that can't narrow its run is a warning: it first runs at `merge`. Exits 1 |
| `spec-page.format`, `spec-page.too-long`, `spec-page.quote-not-in-spec`, `spec-page.summary` | fast modes §5.2; `swiftgate spec-page check <page> --spec <spec-file> [--json]` reads a spec page in the format `skills/sprint/references/spec-page.md` sets out. `format` (major) is a title, `Spec:` line or section missing, repeated or out of order, a modules row whose kind standards.md doesn't list, a slice numbered out of sequence, without exactly 1 `Test:`, with a test name another slice uses, with a `Tier:` other than `T2` or `T3`, or without a closing `Spec: "<quote>"` or `Spec: none`; `too-long` (major) is a page over 400 words as `wc -w` counts them; `quote-not-in-spec` (major) is a quote the spec file doesn't hold word for word, with runs of whitespace compared as 1 space, case, punctuation and quote marks exact, and no word cut at either end. It prints `confirm: required` when a slice says `none` or its quote isn't in the spec, else `skippable`; each slice id, `slice-<n>-<kebab test name>`; and `pageSha`. `summary` is a nit. Exits 1 on a major finding, 2 when the page or spec file can't be read |
| `plan-confirm.page-red`, `plan-confirm.needs-user` | fast modes §5.1 step 1, §7 (confirming the spec page); `swiftgate plan confirm <slug> --by user|spec-quotes|delegate --spec <spec-file> --session <id> [--json]`, run by the plan's lock holder, runs `spec-page check` on the plan's spec page and records `{pageSha, by, at}` as the plan file's `approval`, the sha of the bytes it checked, then sets the plan's index entry to `approved`. `page-red` refuses a page the check fails, under every `--by`; `needs-user` refuses `--by spec-quotes` when the check prints `confirm: required`, so only the user, or `--by delegate` for a session answering on the user's behalf, confirms a page with a `Spec: none` slice or a quote the spec file doesn't hold. Both exit 1 and write nothing; so does a session without the plan's lock. A design plan, an unknown `--by`, or a page, spec file or plan file it can't read exits 2 |
| `plan-lint.spec-page-moved` | fast modes §9 (plan-lint coverage), §5.2; `swiftgate plan-lint <slug>` on a spec-page plan reads the plan's spec page in place of a design. It fails (major) a page whose bytes no longer hash to the `pageSha` its confirmation recorded, naming both shas; confirm the page again with `swiftgate plan confirm`, or replan. The rest of the lint reads the page as it stands: each slice id `slice-<n>-<kebab test name>` is a coverage item (`plan-lint.uncovered-requirement`), a `tests` id must be a slice id (`plan-lint.unknown-test`), a task's gate must reach the tier of every slice it covers or tests, T1 unless the slice says `Tier: T2` or `Tier: T3` (`plan-lint.gate-too-weak`), a task covering more slices than `max_tests_per_task` is `plan-lint.too-many-tests`, the page's Modules table places the modules a plan creates, and each worker pack is the one `context-pack --spec-page` builds. A plan whose page isn't confirmed yet, or a page it can't read or parse, exits 2 |
| `plan-lint.new-module-untested` | fast modes §5.1 step 3 (the user's choice of 2026-09-29: test targets for the modules a surface creates); `swiftgate plan-lint <slug>` on a spec-page plan fails (major) each module the page's Modules table names that `coverage.no-t1-tests` would fail in the module graph (a core, client or Live module with no `<Module>Tests` host test target, unless `host_testable = false`) when no task's write set holds its package's `Tests/<Module>Tests/`, as that directory, a file in it or a directory above it. The finding names the module and the directory; add the directory to the write set of the task that builds on the module, with a host test that depends on it. A surface can't add a test target (an empty one fails `t1.no-tests`), so without this the final gate fails for a module no task owns. A module the graph doesn't have isn't judged, and a design plan is unchanged |
| `plan-surface.not-confirmed`, `plan-surface.not-on-main`, `plan-surface.behaviour`, `plan-surface.gate-unknown`, `plan-surface.gate-red`, `plan-surface.gate-stale`, `plan-surface.gate-tier`, `plan-surface.main-checked-out`, `plan-surface.already-recorded` | fast modes §5.1 step 2, §6 (the surface lands on `main` on a `fast` gate, as sprint's does: a stub has no test, so push-tier impact and coverage can't pass on a new module, and the build's first merge gate judges `main` at the preset's tier); `swiftgate plan surface <slug> <sha> --gate <run id> --session <id> [--json]`, run by the lock holder of a spec-page plan in the checkout whose run history holds the gate run, fast-forwards `main` to the surface and records it as the plan file's `surfaceCommit`. `not-confirmed` refuses a page with no confirmation or whose bytes no longer hash to the confirmed `pageSha`; `not-on-main` a surface whose parent isn't `main`'s HEAD; `behaviour` any `surface-check.behaviour` finding in it; `gate-unknown` a run id this checkout's history doesn't hold; `gate-red` a RED or BLOCKED run; `gate-tier` a run below `fast` (a `test`, `coverage` or other non-`check` run); `gate-stale` a run whose `headCommit` isn't the surface; `main-checked-out` any worktree with `main` checked out; `already-recorded` a plan that records a surface. Each exits 1 and moves and writes nothing; so does a session without the plan's lock. `main` already at the surface with nothing recorded is recorded, so a run that stopped after the move can finish. A missing or invalid flag, an unknown commit, a design plan, or state, history or git it can't read exits 2 |
| `doctor.xcode-pin`, `doctor.toolchain`, `doctor.simulator-runtime`, `doctor.disk`, `doctor.shim`, `doctor.swiftlint`, `doctor.mmdc`, `doctor.issue-reporting`, `doctor.upgrade-hazard`, `doctor.profile`, `doctor.judge-key`, `doctor.config-conflict` | `swiftgate doctor`; [Toolchain hazards](#toolchain-hazards). `doctor.config-conflict` (major) fails a clone holding both a committed `.swiftgate.toml` and a brownfield config under its git common dir (`swift-harness/config.toml`), naming both paths (brownfield profile §4). `doctor.profile` (major) fails a `[harness] profile` that names no `[build.presets.<name>]` table. `doctor.judge-key` (major) fails a `[judge] backend` whose key variable (`TYPESAFE_API_KEY` for `jev`) is unset or empty in doctor's environment, and says how a Claude Code session gets it; it names the variable, never a value. `doctor.xcode-pin` also BLOCKS `test --tier t1\|t2\|t3` and every `check` tier's T1 and simulator tiers (never T0) when the selected Xcode doesn't match the pin, is unreadable, or isn't selected at all; a repository with no pin configured is never blocked on it |
| `doctor.agent-device` | simulator QA §4, §9; `swiftgate doctor` runs `agent-device --version` and compares it with the adapter's pin (`AgentDevicePin.version`). When any build preset sets `sim_qa = "changed"` or `[[scenarios]]` is non-empty, a missing CLI or another version is BLOCKED, naming both versions and the exact `npm i -g agent-device@<pin>` line; otherwise it is a nit with the same line |
| `doctor.plugin-changed`, `doctor.session-record` | speed research coverage §4; `swiftgate doctor [--session <id>]` compares the session's SessionStart record (that session's with `--session`, else the newest) with the plugin tree at the record's `pluginRoot`. A running session keeps the prompts it loaded at start, so a different tree hash, or a `pluginRoot` that is gone or can't be hashed, is `plugin-changed` (major): start a fresh session. No record is a `session-record` nit; a record that can't be read is a major `session-record` |
| `guard.raw-xcodebuild`, `guard.simctl-all`, `guard.snapshot-record`, `guard.global-derived-data`, `guard.snapshot-reference`, `guard.package-resolved`, `guard.xcresult`, `guard.plan-state`, `guard.subagent-outside-checkouts`, `guard.build-agent-main-checkout`, `guard.subagent-protected-path`, `guard.dirty-file`, `guard.validation-flow-by-hand`, `guard.bare-stdin-reader`, `guard.process-match-wait`, `guard.fixer-gate-cap`, `guard.build-agent-foreground`, `guard.gate-output-outside-run` | [hooks.md](hooks.md) (PreToolUse guards) |
| `guard.reviewer-bash` | [hooks.md](hooks.md#subagents-never-prompt); PreToolUse denies an `architecture`, `test-quality` or `verifier` agent's Bash call unless it is exactly 1 `swiftgate events span start\|end` (program `"$SG"` or an absolute `…/bin/swiftgate` with no `.`/`..` component; bare `swiftgate` is denied, since `PATH` may hold another install than the plugin under test) with only that subcommand's options, each once: `start` `--phase`, `--build-run`, `--task`, `--role`, `--parent`; `end` the span id and `--outcome`. Every word is plain characters (`A-Za-z0-9_./:=@%+,-`), single-quoted text or double-quoted plain text, so no `;`, `&&`, `\|`, `&`, redirection, `$(…)`, backticks, other variables, globs, `~`, comments or second line passes. Other agents and the main session are untouched. The limit is the agent's, so it applies outside a `.swiftgate.toml` project too |

### Brownfield profile (`check --tier slice|merge|final`, `test-only`, `discover`, `xcode`)

| Rule id | Section |
|---|---|
| `neutral.not-proven` | brownfield profile §6, §9; a changed test passes with the task's source change reverted in a scratch tree. It replaces `prove.not-proven` in this profile; `prove.compile-only`, `prove.crashed` and `prove.no-evidence` keep their meaning |
| `neutral.no-assertion` | brownfield profile §6; a changed test with no entry of its language's assertion table, or only a tautology. An empty body or a body of tautologies is a finding outright; a body that runs code with no assertion goes to the judge cascade, since a helper it calls may assert. An `[[allow]]` entry or an inline `swiftgate:allow` with a reason on the test's declaration line waives it |
| `neutral.unsafe-shortcut` | brownfield profile §6; an escape hatch, a lint suppression, or a skipped or focused test on an added line, outside strings and comments. An `[[allow]]` entry or an inline `swiftgate:allow` with a reason waives it |
| `neutral.lint` | brownfield profile §6; the area's own `lint` command on the changed files, findings on added lines only |
| `xcode.file-not-in-target` | brownfield profile §8; a new Swift file under a source root that no target of the area's Xcode project compiles |
| `area.test-failed`, `area.build-failed`, `area.lint-failed` | brownfield profile §7; an area's own command failed, and the baseline doesn't hold the failure (major); `test-only` reads no baseline |
| `area.step-dropped`, `area.build-only` | brownfield profile §5.3, §9; a step the orchestrator dropped or whose tool isn't installed, and an area whose tests don't fit the `slice` budget and whose `test_files` can't narrow a run to the changed tests, so `slice` only builds it and `merge` runs and proves them. Report lines that never gate |
| `baseline.summary` | brownfield profile §10; the failures found at both the head and the merge base, which never gate. A failure is absorbed only when the merge base fails the same step, command and selection with the same test id, or fails the whole step when the head does too. Test ids come from the report discover asks each runner for: `--junitxml` for pytest, the JUnit reporter for vitest, jest-junit for jest when the repository has it, `rspec_junit_formatter` for RSpec when bundled, `--parallel --xunit-output` for `swift test` (with Swift Testing's report beside it), Gradle's and Maven's per-class reports collected into a `{junit}` directory (Gradle with `--continue`), the events Go writes under `-json`, and libtest's own result lines for cargo, run with `--no-fail-fast`. Any other command, jest without jest-junit, RSpec without the formatter, and yarn or bun scripts fail as the whole step. A failure the report can't hold also fails the whole step: a compile or load failure, a Gradle task or Maven goal that failed for anything but failing tests, RSpec's errors outside examples, a Go package or a cargo target that failed with no failing test of its own. The same nit names a baseline file that doesn't decode (it is rerun and replaced, never read as empty) and a merge-base rerun that couldn't run, whose failures then gate |
| `baseline.whole-step` | brownfield profile §10; `final`: a test step failing whole at both, no test ids (major) |

### Simulator QA validation ([`qa run`](simulator-qa.md#qa-run), [flows](simulator-qa-flows.md), [`qa adopt`](simulator-qa.md#qa-adopt))

| Rule id | Section |
|---|---|
| `qa.check-failed` | simulator QA amendment §6, §6.2; a row whose check ran and failed (major). Its message names the row, the requirement, the layer and why: the exit status, the signal or the timeout, and its first failure line |
| `qa.check-unverified` | simulator QA amendment §6.2, §9.1; a row whose check didn't run, a nit until the build ends (then major, abandoned and waiting rows too): the flow runner isn't built, a red layer stopped the run, a flow row for its requirement didn't pass, no port could be had, the process couldn't start, or its report shows no test ran |
| `qa.no-verifiable-row` | a table with no row a check runs, only reasons: a nit until the build ends, then major |
| `qa.check-passes-at-base` | simulator QA amendment §5.2, decision 7; `qa run --at-base` found a row passing at the merge base, so its check can't tell the change from its absence (major) |
| `qa.video-unverified` | simulator QA amendment §7, §8.3, decisions 6 and 14; a `qa run --final` flow left no video, a nit that never gates: the Mac's recorder stayed busy past 5 minutes, the `sim-record` slot stayed held, or `record start` or `stop` failed, or a kept T3 flow kept none. A missing contact sheet is the same nit |
| `qa.evidence-unsaved` | simulator QA amendment §8.1, decision 3; a `qa run --final` flow's app log, network dump, trace, unified log or data container, or a kept flow's activities, wasn't saved, a nit that never gates, naming the call |
| `qa.repair-cap`, `qa.repair-outside-row`, `qa.repair-weakens-check`, `qa.repair-unchanged`, `qa.repair-not-red`, `qa.repair-wrong-red`, `qa.repair-red-runs` | [`qa adopt --repair`](simulator-qa-flow-repair.md); a repaired flow row refused, nothing copied (major): a second repair in 1 build run, a file outside its row, a dropped or shortened `wait` or `is` step, no change, no red run at the base of the repaired check, a red there that fails no adopted assertion, or red runs that don't read the row red |

### Simulator QA flows ([`qa lint`](simulator-qa.md#qa-lint))

| Rule id | Section |
|---|---|
| `qa.flow-unparsed` | simulator QA amendment §6.1; the file isn't a JSON list of objects that each hold a string `command` and an object `input` (major). The message names the first step that isn't, and the file earns no other finding |
| `qa.flow-ref-target` | simulator QA amendment §6.1; a step targets an `@e` snapshot ref (a `kind: ref` target, a `ref` key, or an `@e<n>` string) or a coordinate (a `kind: point` target, or an object with numeric `x` and `y`, except a gesture's `delta`), not a selector (major). Refs change with every snapshot and points with every screen |
| `qa.flow-no-assert` | simulator QA amendment §6.1, decision 4; no step is an `is` or a `wait` that looks for something: `kind` `text`, `ref`, `selector` or `absent`, or with no `kind` a `text`, `ref`, `selector` or `absent` key (major). `get` reads without a predicate, and a `duration` or `stable` wait only pauses, so neither counts |
| `qa.flow-schema` | simulator QA amendment §6.1, §11.1; a step breaks the pinned tool's schema (major): the step's own keys or a command a batch can't run, checked against the item schema of `batch`'s `steps`, then its `input` against that command's `inputSchema`. Each message names the step number, the command, the key path and the rule broken, and a misspelt key names the closest key the schema allows |
| `qa.flow-unknown-id` | simulator QA amendment §6.1, decision 17; an `id="…"` (or bare `id=…`) selector names an identifier the configured `AccessibilityID` enum doesn't declare (major). A case with no raw value declares its name; cases inside `#if` count in every branch |
| `qa.flow-ids-unknown` | simulator QA amendment §6.1; a nit that never gates: no `.swiftgate.toml`, or no `[qa] accessibility_ids` key, so no identifier was checked. Once per run, naming the key to set; never in a brownfield clone, which has no such key |

### Design, docs and prose (`design-lint`, `design-diff`, `docs-lint`, `prose`)

| Rule id | Section |
|---|---|
| `design-lint.status-unknown` | design plan workflows §5.4 (status frontmatter) |
| `design-lint.section-missing`, `design-lint.section-order`, `design-lint.problem-empty`, `design-lint.options-count`, `design-lint.module-kind-unknown`, `design-lint.test-tier-invalid` | design plan workflows §5.3 (design doc template) |
| `design-lint.requirement-id-form`, `design-lint.test-id-form`, `design-lint.requirement-id-duplicate`, `design-lint.test-id-duplicate` | design plan workflows §5.1 (id policy) |
| `design-lint.claims-file-missing`, `design-lint.claims-file-unreadable-lines`, `design-lint.unknown-tier`, `design-lint.untagged-bullet`, `design-lint.unverified-in-decision`, `design-lint.unknown-claim`, `design-lint.citation-not-supported`, `design-lint.claim-id-duplicate`, `design-lint.unverified-uncovered`, `design-lint.perf-missing-dimension` | design plan workflows §5.2 (claim record), §6.2 (`design-lint` tagging rules) |
| `design-lint.architecture-diagram-unknown-type`, `design-lint.architecture-diagram-count`, `design-lint.mmdc-unavailable`, `design-lint.mermaid-syntax` | design plan workflows §5.3 (diagrams over prose); without `mmdc` the syntax check is a non-gating note |
| `design-lint.section-word-budget`, `design-lint.document-word-budget` | design plan workflows §5.3 (word budgets) |
| `design-diff.discontinuous`, `design-diff.unknown-from-sha`, `design-diff.unknown-to-sha`, `design-diff.no-change`, `design-diff.amend` | design plan workflows §5.5 (amendment record), §6.2; the broken link `design-diff --chain` reports, and the answer its `self-test` seeds give |
| `docs-lint.managed-file-missing`, `docs-lint.managed-file-unlisted`, `docs-lint.anchor-vacuous`, `docs-lint.banned-phrase` | design plan workflows §6.2 (`docs-lint`), §5.4 |
| `docs-lint.agents-md-line-budget`, `docs-lint.router-word-budget`, `docs-lint.topic-word-budget` | design plan workflows §6.2 (`docs-lint` budgets) |
| `docs-lint.dangling-id`, `docs-lint.bare-adr-reference`, `docs-lint.requirement-uncited`, `docs-lint.broken-relative-link`, `docs-lint.unreachable-doc` | design plan workflows §6.2 (reference integrity and router reachability), §4 |
| `docs-lint.local-path` | design plan workflows §6.2 (`docs-lint` local-paths family, decision D25) |
| `docs-lint.no-docs-section`, `docs-lint.no-docs-directory` | design plan workflows §6.2; a repository with no `[docs]` table or no `docs/` directory still runs, with a non-gating note |
| `prose.adverb`, `prose.em-dash`, `prose.number-word`, `prose.passive-voice`, `prose.filler`, `prose.jargon`, `prose.sentence-length` | design plan workflows §6.2, §7.3 (`swiftgate prose`) |
| `docs-lint.blocked`, `prose.blocked`, `prose.summary` | design plan workflows §6.2; `check --tier push` runs `docs-lint` and `prose` over the added lines, and anything that stops either from running gates |

### Plans, builds and calibration (`plan-lint`, `build`, `ledger set`, `calibrate`)

| Rule id | Section |
|---|---|
| `plan-lint.dag-cycle`, `plan-lint.missing-dependency`, `plan-lint.waves-mismatch`, `plan-lint.duplicate-task-id`, `plan-lint.design-moved` | design plan workflows §9.2 (`plan-lint`), §5.6 (the plan file) |
| `plan-lint.write-set-overlap`, `plan-lint.hot-file`, `plan-lint.single-dependent-chain` | design plan workflows §9.2 (write sets and hot files) |
| `plan-lint.uncovered-requirement`, `plan-lint.gate-too-weak`, `plan-lint.unknown-test` | design plan workflows §9.2 (test plan coverage) |
| `plan-lint.missing-model` | build executor §5.2 (ledger task field `model`) |
| `plan-lint.est-lines-high`, `plan-lint.est-lines-low`, `plan-lint.too-many-modules`, `plan-lint.too-many-tests` | design plan workflows §9.3 (task sizing) |
| `plan-lint.pack-missing`, `plan-lint.pack-unknown-task`, `plan-lint.pack-over-budget` | design plan workflows §5.10 (context packs) |
| `plan-lint.validation-uncovered`, `plan-lint.validation-unknown-task`, `plan-lint.validation-state-without-flow`, `plan-lint.validation-flow-without-ios` | simulator QA amendment §4.1, §4.3 (the validation table). `plan-lint` checks the validation table a design plan keeps beside its ledger, and `plan import` checks a brownfield `PLAN.md`'s `## Validation` table, failing the import. Each fails (major): a requirement with no row and no unit-only reason; a `Runs after` or `Writer` id that names no ledger task; a `state` row with no `flow` row for the same requirement and `Runs after` ids (an `acceptance` row stands in where the repository has no Xcode area); a `flow` row in a repository with no Xcode area. A brownfield plan without the section imports with a non-gating note |
| `plan-lint.validation-check-source-file` | an acceptance `Check` naming a test source file; use `test: <id>` |
| `plan-lint.validation-screen-without-flow` | a requirement whose task writes an `xcode` area's screen or feature, with no `flow` row and no `Reason` naming an obstacle kind |
| `plan-lint.validation-app-without-flow` | an `xcode` area whose screens a task writes, with no `flow` row |
| `plan-lint.validation-obstacle-fakeable` | a screen requirement excused only by `network:` while its `xcode` area holds a `…Client` module a launch-selected fake can serve |
| `plan-lint.check-missing-dependency` | a task's row or acceptance exercising another task's work without depending on it |
| `plan-import.contract-write-unlanded`, `plan-import.scenario-seam-missing` | why `plan import --contract` kept a GREEN contract pending: a literal file its `Writes` names that the contract commit left as at its gate's base, or flows launched with `-harness-scenario` while no Swift source outside a `…Tests` folder in an `xcode` area reads that argument outside a comment |
| `build-next.unmerged-dependency`, `build-next.missing-model`, `build-next.write-set-overlap`, `build-next.not-started` | build executor §8.1 (scheduling); why `build next` left a pending task unstarted, as its `self-test` seeds answer |
| `ledger-set.refused-transition`, `ledger-set.written-despite-refusal` | build executor §6.2 (`ledger set`); a refused transition, and a refusal that still wrote the ledger |
| `build-merge.main-moved`, `build-merge.dirty-checkout`, `build-merge.not-on-main`, `build-merge.not-held`, `build-merge.conflicted`, `build-merge.undo-refused`, `build-merge.branch-missing`, `build-merge.already-merged`, `build-merge.return-unchecked`, `build-merge.return-not-green`, `build-merge.return-stale` | build executor §6.2, §8.2 (merge); why `build merge` refused, as its report's `reason`. The last 3 come from the build run's newest `return-check` event for the task (or, with `--fix`, its fixer): none recorded, a verdict other than GREEN (the refusal names the check's id, the one its build.return-checked telemetry event carries, and its rules), or a GREEN check of another commit than the branch tip being merged |
| `build-merge.review-blocked-unanswered` | `build merge` refused a `review-blocked` return no halt of the task answered `merge` since its check |
| `build-merge.flows-unchecked`, `build-merge.flows-red` | why `build merge` refused a task some validation row runs after, with every other task that row waits on merged: no GREEN or conflicted `qa run --after <task> --before-merge` of the branch at its tip on `main`'s commit, or a RED one, for which it cuts the fix worktree as for a conflict |
| `calibrate-design.usage`, `calibrate-design.passed`, `calibrate-design.seed-defect`, `calibrate-design.label-missed`, `calibrate-design.no-seeds`, `calibrate-design.missing-label`, `calibrate-design.missing-input`, `calibrate-design.missing-entry`, `calibrate-design.invalid-label`, `calibrate-design.unknown-agent`, `calibrate-design.uncalibrated-agent` | design plan workflows §6.2 (`calibrate design`) |
| `calibrate-build.usage`, `calibrate-build.passed`, `calibrate-build.seed-defect`, `calibrate-build.label-missed`, `calibrate-build.no-seeds`, `calibrate-build.missing-label`, `calibrate-build.missing-input`, `calibrate-build.missing-entry`, `calibrate-build.invalid-label`, `calibrate-build.unknown-agent`, `calibrate-build.uncalibrated-agent` | build executor §12 (`calibrate build`) |

### Simulator QA commands (`sim up`, `snap`, [`down`](simulator-qa-sim.md#sim-down))

| Rule id | Section |
|---|---|
| `sim.agent-device-pin` | simulator QA §4, §9; `swiftgate sim up [--scenario <name>] [--json]` first runs `agent-device --version`. A missing CLI or any version but the pin is BLOCKED (exit 2) with the exact `npm i -g agent-device@<pin>` line, before a slot is taken |
| `sim.scenario-unknown` | simulator QA §6; a `--scenario` that names no `[[scenarios]]` entry is RED (exit 1), naming the declared names, before any hold or build. Without `--scenario` the app launches with live dependencies |
| `sim.no-slot` | simulator QA §7.2, §9; `sim up` starts a detached `swiftgate sim hold --run <runID>` in the worktree root and waits for its lease. A holder that exits without a lease (no slot of the shared `sim` lock in time, or no device), or that gives the device back before `sim up` finishes, is BLOCKED (exit 2), naming the live PIDs holding `sim` slots and the run's `sim/agent-device.log` |
| `sim.app-build-failed` | simulator QA §4, §9; `xcodebuild build` of `app_scheme` for the iOS Simulator, with this worktree's DerivedData under `derived-data/sim-up`, `-skipMacroValidation` and `-skipPackagePluginValidation`, exited non-zero (RED, exit 1, naming `sim/build.log`), or the repository root has no single `.xcworkspace` or `.xcodeproj` (RED, checked before the hold) |
| `sim.app-install-failed` | simulator QA §4; the build's `Debug-iphonesimulator` products hold no `.app`, more than one, or one without a `CFBundleIdentifier`, or `simctl install` refused it. BLOCKED (exit 2) |
| `sim.driver-failed` | simulator QA §9; `agent-device open <bundle id> --udid <udid> --session <session> --launch-args -harness-scenario --launch-args <name> --json` failed, such as `DEVICE_IN_USE` or an unknown device. BLOCKED (exit 2), with the failure appended to `sim/agent-device.log`. After any failure once the holder has started, `sim up` removes the run's lease, so the holder frees the device and the slot. In `sim snap`, any `snapshot` or `screenshot` failure but an unknown device is this rule too, and writes no step |
| `sim.not-owner` | simulator QA §4, §7.5; `swiftgate sim snap <label> [--assert "<text>"] [<runID>] [--json]` names a run whose lease belongs to another worktree. RED (exit 1), naming that worktree, before any device call or write. Without `<runID>`, `snap` takes this worktree's newest lease whose holder is alive |
| `sim.session-gone` | simulator QA §4, §5.1; `sim snap` found no lease for the run (or, without `<runID>`, no live lease of this worktree), a holder that has exited, a lease with no session yet, or `agent-device` reported the device unknown (`DEVICE_NOT_FOUND`). RED (exit 1). It writes no step line and leaves no PNG or tree behind. A snap that passes appends 1 line to `sim/steps.ndjson` (`n`, `label`, `assert` only when given, `screenshot`, `tree`, `settled` only when both snapshots parse, `elapsedMs`, `appState`) and writes `steps/<NNN>.png` and the `snapshot --json` bytes unmodified as `steps/<NNN>.tree.json` |

### Simulator QA evidence ([`sim verify`](simulator-qa-sim.md#sim-verify))

| Rule id | Section |
|---|---|
| `sim.no-steps` | simulator QA §5.2; the run's step log holds no step (major) |
| `sim.evidence-missing` | simulator QA §5.2; a step names a screenshot or tree that isn't on disk, is empty, can't be read, lies outside the run's `sim/` folder, or a tree that doesn't parse or holds a role the pin can't name (major). The message names the step, the file and why |
| `sim.assert-absent` | simulator QA §5.2; no element's label or value in the step's tree equals its `--assert` text (major) |
| `sim.stale-head` | simulator QA §5.2; the checkout's HEAD isn't the commit `sim up` recorded (major), naming both |
| `sim.a11y-identifier` | simulator QA §5.2, standards §7; a button, switch, text field or cell in a step's tree has no accessibility identifier (major), naming the step, the element's role and its label |
| `sim.a11y-label` | simulator QA §5.2, standards §7; a button, switch, text field or cell in a step's tree has no readable label: none, only whitespace, or the same text as its identifier (major), naming the step, the element's role and its identifier |
| `sim.a11y-untargeted` | simulator QA §5.2, standards §7; in a brownfield clone `sim.a11y-identifier` and `sim.a11y-label` judge only the controls a flow step's `id=` selectors match, and this 1 nit counts the findings left out, those on controls the flow only navigates through apart. A `sim verify` with no flow judges none, and says why |
| `sim.app-exited` | simulator QA §5.2, §9; a step's `appState` is `notRunning` after a step where the app ran, or `sim/crashes/` holds a crash report of the run's app on its device since `startedAt` that no such step claimed (major). Each step finding names the next crash report in time order. `sim snap` records `appState` from `agent-device appstate` on every step; finding the app not running, it records the step with no tree and exits RED (exit 1) with this id. `sim down` copies the run's `.ips` reports into `sim/crashes/` |
