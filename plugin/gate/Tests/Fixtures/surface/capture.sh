#!/bin/sh
# Rebuilds every fixture under this directory from real commits. Run from the repository root:
#   plugin/gate/Tests/Fixtures/surface/capture.sh
# It commits a base tree, then 1 commit per case on its own branch from that base, and records
# what `surface-check`'s reader consumes: `git diff --name-only --no-renames <parent> <commit>`,
# and `git show <rev>:<path>` of each changed Swift path on each side that holds it. Swift text is
# stored with a `.txt` suffix so no Swift tool lints or builds it.
set -eu

OUT=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap '/bin/rm -rf "$T"' EXIT
cd "$T"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
git init -q -b main
git config user.name Fixture
git config user.email fixture@example.com
git config commit.gpgsign false

mkdir -p Sources/App Tests/AppTests

cat > README.md <<'EOF'
# App
EOF

cat > Sources/App/Existing.swift <<'EOF'
import Foundation

struct Item: Equatable {
  var name: String
}

enum Tab {
  case home
  case settings
}

final class ItemClient {
  var timeout = 30

  func fetchItems() async throws -> [Item] {
    []
  }

  func count() -> Int {
    return 3
  }
}

func existingTotal(_ values: [Int]) -> Int {
  values.reduce(0, +)
}
EOF

cat > Sources/App/Feature.swift <<'EOF'
import ComposableArchitecture
import SwiftUI

@Reducer
struct Feature {
  @ObservableState
  struct State: Equatable {
    var count = 0
  }

  enum Action {
    case increment
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += 1
        return .none
      }
    }
  }
}

struct FeatureView: View {
  let store: StoreOf<Feature>

  var body: some View {
    Text("Count")
  }
}

func describe(_ tab: Tab) -> String {
  switch tab {
  case .home: return "Home"
  case .settings: return "Settings"
  }
}
EOF

cat > Sources/App/Commands.swift <<'EOF'
struct Root {
  static let commands: [Any.Type] = [
    ListCommand.self,
    ShowCommand.self,
  ]

  static var names: [Any.Type] { [ListCommand.self] }
}

struct ListCommand {}

struct ShowCommand {}
EOF

cat > Sources/App/Status.swift <<'EOF'
enum ExitStatus: Equatable {
  case exited(Int32)
  case signalled(Int32)
}

enum LoadState {
  case idle
  case loaded([Item])
}
EOF

cat > Sources/App/Legacy.swift <<'EOF'
func legacy() -> Int {
  1
}
EOF

cat > Tests/AppTests/FeatureTests.swift <<'EOF'
import Testing

@testable import App

@Suite struct FeatureTests {
  @Test func describesHome() {
    #expect(describe(.home) == "Home")
  }
}
EOF

mkdir -p Packages/AppFeature
cat > Packages/AppFeature/Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AppFeature",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .library(name: "AppUI", targets: ["AppUI"]),
  ],
  dependencies: [
    .package(path: "../APIClient"),
    .package(path: "../LogClient"),
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      exact: "1.26.2"
    ),
  ],
  targets: [
    .target(
      name: "AppCore",
      dependencies: [
        .product(name: "APIClient", package: "APIClient"),
        .product(name: "LogClient", package: "LogClient"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      swiftSettings: [.define("APP_CORE")]
    ),
    .target(
      name: "AppUI",
      dependencies: [
        "AppCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(name: "AppUITests", dependencies: ["AppUI"]),
  ],
  swiftLanguageModes: [.v6]
)
EOF

git add -A
git commit -q -m base
BASE=$(git rev-parse HEAD)

/bin/rm -rf "$OUT/parent-tree" "$OUT/cases"
git ls-tree -r --name-only "$BASE" | while read -r path; do
  case "$path" in *.swift) ;; *) continue ;; esac
  mkdir -p "$OUT/parent-tree/$(dirname "$path")"
  git show "$BASE:$path" > "$OUT/parent-tree/$path.txt"
done

begin() {
  git checkout -q -B "$1" "$BASE"
}

record() {
  git add -A
  git commit -q -m "$1"
  dir="$OUT/cases/$1"
  mkdir -p "$dir"
  git diff --name-only --no-renames "$BASE" HEAD > "$dir/changed.txt"
  while read -r path; do
    case "$path" in *.swift) ;; *) continue ;; esac
    for side in parent commit; do
      if [ "$side" = parent ]; then rev=$BASE; else rev=HEAD; fi
      if git cat-file -e "$rev:$path" 2>/dev/null; then
        mkdir -p "$dir/$side/$(dirname "$path")"
        git show "$rev:$path" > "$dir/$side/$path.txt"
      fi
    done
  done < "$dir/changed.txt"
}

# Allowed stubs: each must pass.

begin allowed-empty-body
cat > Sources/App/Surface.swift <<'EOF'
extension ItemClient {
  func reset() {}

  func stop() {
    return
  }
}
EOF
record allowed-empty-body

begin allowed-empty-defaults
cat > Sources/App/Surface.swift <<'EOF'
extension ItemClient {
  func find(id: String) -> Item? {
    return nil
  }

  func all() -> [Item] {
    []
  }

  func byName() -> [String: Item] {
    [:]
  }

  func total() -> Int {
    0
  }

  func hasMore() -> Bool {
    false
  }

  func title() -> String {
    ""
  }

  func blank() -> Item {
    .init()
  }
}
EOF
record allowed-empty-defaults

begin allowed-payload-free-case
cat > Sources/App/Surface.swift <<'EOF'
func initialTab() -> Tab {
  .home
}
EOF
record allowed-payload-free-case

begin allowed-accessors
cat > Sources/App/Surface.swift <<'EOF'
final class Settings {
  var isEmpty: Bool { false }

  var title: String {
    get { "" }
    set {}
  }

  var limit: Int = 0 {
    didSet {}
  }

  subscript(index: Int) -> Item? { nil }
}
EOF
record allowed-accessors

begin allowed-initializers
cat > Sources/App/Surface.swift <<'EOF'
struct Draft {
  var name: String = ""

  init() {}

  init(name: String) {}
}

extension Item {
  init(title: String) {
    self.init(name: title)
  }
}
EOF
record allowed-initializers

begin allowed-throws-async
cat > Sources/App/Surface.swift <<'EOF'
extension ItemClient {
  func load() async throws -> [Item] {
    []
  }

  func save(_ item: Item) async throws {}

  func refresh() async throws -> [Item] {
    try await fetchItems()
  }
}
EOF
record allowed-throws-async

begin allowed-forward
cat > Sources/App/Surface.swift <<'EOF'
func reload(client: ItemClient) async throws -> [Item] {
  try await client.fetchItems()
}

func sum(values: [Int]) -> Int {
  existingTotal(values)
}

func makeItem(name: String) -> Item {
  Item(name: name)
}
EOF
record allowed-forward

begin allowed-reducer-none
cat > Sources/App/Detail.swift <<'EOF'
import ComposableArchitecture

@Reducer
struct Detail {
  struct State: Equatable {}

  enum Action {
    case appeared
    case closed
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        return .none
      case .closed:
        return .none
      }
    }
  }
}

@Reducer
struct Placeholder {
  struct State: Equatable {}

  enum Action {}

  var body: some ReducerOf<Self> {
    Reduce { _, _ in .none }
  }
}
EOF
record allowed-reducer-none

begin allowed-reducer-new-action
sed -i '' 's/    case increment/    case increment\
    case decrement/' Sources/App/Feature.swift
sed -i '' 's/        state.count += 1/        state.count += 1\
        return .none\
      case .decrement:/' Sources/App/Feature.swift
record allowed-reducer-new-action

begin allowed-empty-view
cat > Sources/App/Views.swift <<'EOF'
import SwiftUI

struct DetailView: View {
  var body: some View {
    EmptyView()
  }
}

struct ListScreen: View {
  var body: some View {
    NavigationStack {
      VStack {
        EmptyView()
      }
    }
  }
}
EOF
record allowed-empty-view

begin allowed-preview
cat > Sources/App/Views.swift <<'EOF'
import SwiftUI

struct DetailView: View {
  var body: some View {
    EmptyView()
  }
}

#Preview {
  DetailView()
}

#Preview("Empty list") {
  DetailView()
}

extension Item {
  static let preview = Item(name: "")
}
EOF
record allowed-preview

begin allowed-closure-property
cat > Sources/App/Surface.swift <<'EOF'
struct Callbacks {
  var onTap: () -> Void = {}
  var loader: () async -> [Item] = { [] }
}
EOF
record allowed-closure-property

begin allowed-new-enum-case
sed -i '' 's/  case settings/  case settings\
  case profile/' Sources/App/Existing.swift
sed -i '' 's/^func describe(_ tab: Tab) -> String {/func describe(_ tab: Tab, short: Bool = false) -> String {/' \
  Sources/App/Feature.swift
sed -i '' 's/  case .settings: return "Settings"/  case .settings: return "Settings"\
  case .profile: return ""/' Sources/App/Feature.swift
record allowed-new-enum-case

begin allowed-no-new-bodies
git rm -q Sources/App/Legacy.swift
printf '# App\n\nA sample.\n' > README.md
sed -i '' 's/    return 3/    \/\/ The fixed page size.\
    return    3/' Sources/App/Existing.swift
record allowed-no-new-bodies

begin allowed-init-assigns-parameters
cat > Sources/App/Surface.swift <<'EOF'
struct Draft {
  var name: String
  var tags: [String]

  init(name: String) {
    self.name = name
    self.tags = []
  }
}
EOF
record allowed-init-assigns-parameters

begin allowed-empty-value
cat > Sources/App/Surface.swift <<'EOF'
struct Page {
  var items: [Item]
  var title: String
  var cursor: String?

  static var empty: Page { Page(items: [], title: "", cursor: nil) }
}

func firstPage(title: String) -> Page {
  return Page(items: [], title: title, cursor: nil)
}

struct Pager {
  var makePage: (String) -> Page = { title in .init(items: [], title: title, cursor: nil) }
}
EOF
record allowed-empty-value

begin allowed-registration
cat > Sources/App/Commands.swift <<'EOF'
struct Root {
  static let commands: [Any.Type] = [
    ListCommand.self,
    ShowCommand.self,
    AddCommand.self,
  ]

  static var names: [Any.Type] { [ListCommand.self, AddCommand] }
}

struct ListCommand {}

struct ShowCommand {}

struct AddCommand {}
EOF
record allowed-registration

begin allowed-throw-only
cat > Sources/App/Surface.swift <<'EOF'
enum LoadError: Error {
  case notImplemented
  case failed(String)
}

extension ItemClient {
  func load() throws -> [Item] {
    throw CancellationError()
  }

  func save(_ item: Item) throws {
    throw LoadError.notImplemented
  }

  func reset() throws(LoadError) {
    throw .notImplemented
  }

  func retry(reason: String) throws(LoadError) {
    throw .failed(reason)
  }
}
EOF
record allowed-throw-only

begin allowed-empty-payload-case
cat > Sources/App/Surface.swift <<'EOF'
enum Phase {
  case waiting(String)
}

extension ItemClient {
  func run() -> ExitStatus {
    .exited(0)
  }

  func stopped() -> ExitStatus {
    ExitStatus.signalled(0)
  }

  func state() -> LoadState {
    return .loaded([])
  }

  func state(items: [Item]) -> LoadState {
    .loaded(items)
  }

  func phase(named name: String) -> Phase {
    .waiting(name)
  }
}

struct Loader {
  var makeState: ([Item]) -> LoadState = { items in .loaded(items) }
}
EOF
record allowed-empty-payload-case

begin allowed-returns-unchanged
cat > Sources/App/Surface.swift <<'EOF'
struct Limits {
  var runsImpact: Bool
  var steps: [Int]

  func runsImpact(with steps: Set<Int>) -> Bool {
    runsImpact
  }

  var extraSteps: [Int] {
    return self.steps
  }

  func echo(_ value: Int) -> Int {
    return value
  }
}
EOF
record allowed-returns-unchanged

# Rejected shapes: each looks like a stub but carries behaviour, and must fail.

begin rejected-array-of-init
cat > Sources/App/Surface.swift <<'EOF'
func all() -> [Item] {
  [.init()]
}
EOF
record rejected-array-of-init

begin rejected-return-one
cat > Sources/App/Surface.swift <<'EOF'
func total() -> Int {
  return 1
}
EOF
record rejected-return-one

begin rejected-return-true
cat > Sources/App/Surface.swift <<'EOF'
func hasMore() -> Bool {
  true
}
EOF
record rejected-return-true

begin rejected-sample-data
cat > Sources/App/Surface.swift <<'EOF'
func all() -> [Item] {
  [Item(name: "Milk")]
}
EOF
record rejected-sample-data

begin rejected-string-content
cat > Sources/App/Surface.swift <<'EOF'
func title() -> String {
  "TODO"
}
EOF
record rejected-string-content

begin rejected-payload-case
cat > Sources/App/Surface.swift <<'EOF'
func state() -> Result<[Item], Error> {
  .success([])
}
EOF
record rejected-payload-case

begin rejected-computed-logic
cat > Sources/App/Surface.swift <<'EOF'
extension ItemClient {
  var isIdle: Bool { timeout == 0 }
}
EOF
record rejected-computed-logic

begin rejected-two-statements
cat > Sources/App/Surface.swift <<'EOF'
func total() -> Int {
  let base = 0
  return base
}
EOF
record rejected-two-statements

begin rejected-fatal-error
cat > Sources/App/Surface.swift <<'EOF'
func load() -> [Item] {
  fatalError("not built")
}
EOF
record rejected-fatal-error

begin rejected-precondition-failure
cat > Sources/App/Surface.swift <<'EOF'
func save(_ item: Item) {
  preconditionFailure()
}
EOF
record rejected-precondition-failure

begin rejected-throw-near-miss
cat > Sources/App/Surface.swift <<'EOF'
enum LoadError: Error {
  case notImplemented
  case failed(String)
}

func load() throws -> [Item] {
  _ = 0
  throw LoadError.notImplemented
}

func save() throws {
  throw LoadError.failed("the disk is full and the retry budget is spent, so the load stops here now")
}

func saveLong() throws {
  throw LoadError.failed("the disk is full and the retry budget is spent, so the load stops here now!")
}

func reset() throws {
  throw makeError()
}

func makeError() -> LoadError {
  .notImplemented
}

func stop() throws {
  throw LoadError.notImplemented
}
EOF
record rejected-throw-near-miss

begin rejected-payload-case-near-miss
cat > Sources/App/Surface.swift <<'EOF'
extension LoadState {
  static func make(_ items: [Item]) -> LoadState {
    .idle
  }
}

func failed() -> ExitStatus {
  .exited(1)
}

func reloaded(items: [Item]) -> LoadState {
  .loaded(items.reversed())
}

func fresh() -> LoadState {
  .make([])
}

func done() -> ExitStatus {
  .exited(0)
}
EOF
record rejected-payload-case-near-miss

begin rejected-returns-near-miss
cat > Sources/App/Surface.swift <<'EOF'
struct Inner {
  var b: Int
}

struct Flags {
  var runsImpact: Bool
  var x: Bool
  var a: Inner

  func both() -> Bool {
    return runsImpact && x
  }

  func nested() -> Int {
    return self.a.b
  }

  func member() -> Int {
    a.b
  }

  func only() -> Bool {
    runsImpact
  }
}
EOF
record rejected-returns-near-miss

begin rejected-setter-stores
cat > Sources/App/Surface.swift <<'EOF'
final class Settings {
  private var storage = ""

  var title: String {
    get { storage }
    set { storage = newValue }
  }
}
EOF
record rejected-setter-stores

begin rejected-init-assigns-computed
cat > Sources/App/Surface.swift <<'EOF'
struct Counter {
  var count: Int
  var label: String

  init(count: Int) {
    self.count = count + 1
    self.label = ""
  }

  init(label: String) {
    self.count = 0
    self.label = "Count"
  }
}
EOF
record rejected-init-assigns-computed

begin rejected-empty-value-near-miss
cat > Sources/App/Surface.swift <<'EOF'
struct Page {
  var items: [Int]
  var title: String
}

func firstPage(title: String) -> Page {
  Page(items: [1], title: title)
}

func namedPage(title: String) -> Page {
  Page(items: [], title: title.uppercased())
}

func markedPage(title: String) -> Page {
  Page(items: [], title: title + "!")
}
EOF
record rejected-empty-value-near-miss

begin rejected-registration-call
cat > Sources/App/Commands.swift <<'EOF'
struct Root {
  static let commands: [Any.Type] = [
    ListCommand.self,
    ShowCommand.self,
    makeCommand(),
  ]

  static var names: [Any.Type] { [ListCommand.self, Registry.lookup("add")] }
}

struct ListCommand {}

struct ShowCommand {}
EOF
record rejected-registration-call

begin rejected-forward-new-code
cat > Sources/App/Surface.swift <<'EOF'
func sum() -> Int {
  helper()
}

func helper() -> Int {
  0
}
EOF
record rejected-forward-new-code

begin rejected-forward-computed-argument
cat > Sources/App/Surface.swift <<'EOF'
func sum(values: [Int]) -> Int {
  existingTotal(values + [1])
}
EOF
record rejected-forward-computed-argument

begin rejected-changed-existing-body
sed -i '' 's/    return 3/    return 4/' Sources/App/Existing.swift
record rejected-changed-existing-body

begin rejected-changed-existing-case
sed -i '' 's/  case .home: return "Home"/  case .home: return "Start"/' Sources/App/Feature.swift
record rejected-changed-existing-case

begin rejected-changed-stored-value
sed -i '' 's/  var timeout = 30/  var timeout = 60/' Sources/App/Existing.swift
record rejected-changed-stored-value

begin rejected-reducer-mutates
sed -i '' 's/    case increment/    case increment\
    case decrement/' Sources/App/Feature.swift
sed -i '' 's/        state.count += 1/        state.count += 1\
        return .none\
      case .decrement:\
        state.count -= 1/' Sources/App/Feature.swift
record rejected-reducer-mutates

begin rejected-reducer-effect
sed -i '' 's/    case increment/    case increment\
    case refresh/' Sources/App/Feature.swift
sed -i '' 's/        return .none/        return .none\
      case .refresh:\
        return .run { _ in }/' Sources/App/Feature.swift
record rejected-reducer-effect

begin rejected-view-content
cat > Sources/App/Views.swift <<'EOF'
import SwiftUI

struct DetailView: View {
  var body: some View {
    Text("Hello")
  }
}
EOF
record rejected-view-content

begin rejected-view-shapes
cat > Sources/App/Views.swift <<'EOF'
import SwiftUI

struct PaddedView: View {
  var body: some View {
    EmptyView().padding()
  }
}

struct SpacedView: View {
  var body: some View {
    VStack(spacing: 8) {
      EmptyView()
    }
  }
}
EOF
record rejected-view-shapes

begin rejected-preview-sample
cat > Sources/App/Views.swift <<'EOF'
import ComposableArchitecture
import SwiftUI

#Preview {
  FeatureView(store: Store(initialState: Feature.State(count: 3)) { Feature() })
}
EOF
record rejected-preview-sample

begin rejected-preview-fixture
cat > Sources/App/Surface.swift <<'EOF'
extension Item {
  static let preview = Item(name: "Milk")
}
EOF
record rejected-preview-fixture

begin rejected-closure-property
cat > Sources/App/Surface.swift <<'EOF'
struct Formatters {
  var format: (Int) -> String = { "\($0)" }
}
EOF
record rejected-closure-property

begin rejected-test-file
cat > Tests/AppTests/DetailTests.swift <<'EOF'
import Testing

@testable import App

@Suite struct DetailTests {
  @Test func appears() {}
}
EOF
record rejected-test-file

begin rejected-test-in-existing-file
sed -i '' 's/^}$/\
  @Test func describesSettings() {}\
}/' Tests/AppTests/FeatureTests.swift
record rejected-test-in-existing-file

# Package manifests: an existing manifest may only gain dependencies, products and targets.

begin allowed-manifest-local-package
mkdir -p Packages/ProfileClient
cat > Packages/ProfileClient/Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ProfileClient",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "ProfileClient", targets: ["ProfileClient"])
  ],
  targets: [
    .target(name: "ProfileClient")
  ]
)
EOF
sed -i '' 's|    .package(path: "../LogClient"),|    .package(path: "../LogClient"),\
    .package(path: "../ProfileClient"),|' Packages/AppFeature/Package.swift
sed -i '' 's|        .product(name: "LogClient", package: "LogClient"),|        .product(name: "LogClient", package: "LogClient"),\
        .product(name: "ProfileClient", package: "ProfileClient"),|' Packages/AppFeature/Package.swift
sed -i '' 's|    .testTarget(name: "AppUITests", dependencies: \["AppUI"\]),|    .testTarget(name: "AppUITests", dependencies: ["AppUI"]),\
    .target(\
      name: "ProfileFeature",\
      dependencies: [.product(name: "ProfileClient", package: "ProfileClient")]\
    ),|' Packages/AppFeature/Package.swift
record allowed-manifest-local-package

begin allowed-manifest-products-and-targets
sed -i '' 's|    .library(name: "AppUI", targets: \["AppUI"\]),|    .library(name: "AppUI", targets: ["AppUI"]),\
    .library(name: "Settings", targets: ["Settings"]),|' Packages/AppFeature/Package.swift
sed -i '' 's|      exact: "1.26.2"|      exact: "1.26.2"\
    ),\
    .package(\
      url: "https://github.com/pointfreeco/swift-dependencies",\
      exact: "1.9.2"|' Packages/AppFeature/Package.swift
sed -i '' 's|    .testTarget(name: "AppUITests", dependencies: \["AppUI"\]),|    .testTarget(name: "AppUITests", dependencies: ["AppUI", "Settings"]),\
    .target(name: "Settings", dependencies: ["AppCore"]),\
    .testTarget(name: "SettingsTests", dependencies: ["Settings"]),|' Packages/AppFeature/Package.swift
record allowed-manifest-products-and-targets

begin rejected-manifest-removed-dependency
sed -i '' '/    .package(path: "..\/APIClient"),/d' Packages/AppFeature/Package.swift
record rejected-manifest-removed-dependency

begin rejected-manifest-changed-element
sed -i '' 's|      exact: "1.26.2"|      exact: "1.27.0"|' Packages/AppFeature/Package.swift
record rejected-manifest-changed-element

begin rejected-manifest-swift-settings
sed -i '' 's|      swiftSettings: \[.define("APP_CORE")\]|      swiftSettings: [.define("APP_CORE"), .unsafeFlags(["-Onone"])]|' \
  Packages/AppFeature/Package.swift
record rejected-manifest-swift-settings

begin rejected-manifest-platform
sed -i '' 's|  platforms: \[.iOS(.v18), .macOS(.v15)\],|  platforms: [.iOS(.v17), .macOS(.v15)],|' \
  Packages/AppFeature/Package.swift
record rejected-manifest-platform

begin rejected-manifest-tools-version
sed -i '' 's|^// swift-tools-version: 6.2$|// swift-tools-version: 6.1|' Packages/AppFeature/Package.swift
record rejected-manifest-tools-version

begin rejected-manifest-new-statement
printf '\npackage.targets.append(.target(name: "Extra"))\n' >> Packages/AppFeature/Package.swift
record rejected-manifest-new-statement

# Dependency accessors: a new `DependencyValues` accessor may stub as `.init()` and a no-op setter,
# or be wired to its key's slot for a key type the commit or the base declares.

# The client file of a real surface commit, byte for byte, with its accessor stubbed.
write_list_client() {
  mkdir -p Packages/ShoppingListClient/Sources/ShoppingListClient
  cat > Packages/ShoppingListClient/Sources/ShoppingListClient/ShoppingListClient.swift <<'EOF'
import Dependencies
import DependenciesMacros
import Foundation

public struct ShoppingItem: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var quantity: Int
  public var isBought: Bool

  public init(id: UUID, name: String, quantity: Int = 1, isBought: Bool = false) {
    self.id = id
    self.name = name
    self.quantity = quantity
    self.isBought = isBought
  }
}

@DependencyClient
public struct ShoppingListClient: Sendable {
  public var load: @Sendable () throws -> [ShoppingItem]
  public var save: @Sendable (_ items: [ShoppingItem]) throws -> Void
}

extension ShoppingListClient: TestDependencyKey {
  public static let testValue = ShoppingListClient()
  public static let previewValue = ShoppingListClient()
}

extension DependencyValues {
  public var shoppingListClient: ShoppingListClient {
    get { .init() }
    set {}
  }
}
EOF
}

begin allowed-dependency-accessor-stub
write_list_client
record allowed-dependency-accessor-stub

begin allowed-dependency-accessor-wired
write_list_client
sed -i '' -e 's/    get { .init() }/    get { self[ShoppingListClient.self] }/' \
  -e 's/    set {}/    set { self[ShoppingListClient.self] = newValue }/' \
  Packages/ShoppingListClient/Sources/ShoppingListClient/ShoppingListClient.swift
record allowed-dependency-accessor-wired

begin allowed-dependency-accessor-keys
cat > Sources/App/ProfileClient.swift <<'EOF'
struct ProfileClient: Sendable {
  var load: @Sendable () async throws -> String
}
EOF
cat > Sources/App/Dependencies.swift <<'EOF'
import Dependencies

extension DependencyValues {
  var itemClient: ItemClient {
    get { self[ItemClient.self] }
    set { self[ItemClient.self] = newValue }
  }

  var profileClient: ProfileClient {
    get { return self[ProfileClient.self] }
    set { self[ProfileClient.self] = newValue }
  }
}
EOF
record allowed-dependency-accessor-keys

begin rejected-dependency-accessor-near-miss
cat > Sources/App/Dependencies.swift <<'EOF'
import Dependencies

extension DependencyValues {
  var mappedClient: ItemClient {
    get { self[ItemClient.self].configured() }
    set { self[ItemClient.self] = newValue }
  }

  var fixedTimeout: Int {
    get { 30 }
    set {}
  }

  var resetClient: ItemClient {
    get { self[ItemClient.self] }
    set { self[ItemClient.self] = .init() }
  }

  var renamedClient: ItemClient {
    get { self[ItemClient.self] }
    set(client) { self[ItemClient.self] = client }
  }

  var unknownClient: UnknownClient {
    get { self[UnknownClient.self] }
    set { self[UnknownClient.self] = newValue }
  }
}

struct Store {
  var client: ItemClient {
    get { self[ItemClient.self] }
    set { self[ItemClient.self] = newValue }
  }
}
EOF
record rejected-dependency-accessor-near-miss
