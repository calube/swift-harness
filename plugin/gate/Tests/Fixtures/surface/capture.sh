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

begin rejected-throw
cat > Sources/App/Surface.swift <<'EOF'
func load() throws -> [Item] {
  throw CancellationError()
}
EOF
record rejected-throw

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

begin rejected-init-assigns
cat > Sources/App/Surface.swift <<'EOF'
struct Draft {
  var name: String

  init(name: String) {
    self.name = name
  }
}
EOF
record rejected-init-assigns

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
