import ComposableArchitecture
import SwiftUI

@Reducer
struct Parent {
  var body: some ReducerOf<Self> {
    Scope(state: \.child, action: \.child) { Child() } // swiftgate:allow tca.banned-api — fixture for the waiver path; see ParentTests
    Scope(\.child, action: \.child) { Child() }
    Reduce { state, action in
      .run { send in
        try await clock.sleep(for: .seconds(1))
        await send(.loaded)
      }
      .cancellable(id: LoadID.self)
    }
  }
}

struct ParentView: View {
  @Bindable var store: StoreOf<Parent>
  var body: some View {
    ChildView(store: store.scope(\.child, action: \.child))
      .sheet(item: $store.scope(\.destination, action: \.destination).edit) { EditView(store: $0) }
      .animation(.default, value: store.count)
      .transaction { $0.animation = nil }
      .onAppear { withAnimation { _ = store.send(.appeared) } }
      .onReceive(NotificationCenter.default.publisher(for: .changed)) { _ in }
  }
  let note = "WithViewStore and TaskResult are banned"
  func titles(_ items: [Item]) -> [String] { items.map(\.title) }
  func search(_ text: Published<String>.Publisher) {
    _ = text.debounce(for: 0.3, scheduler: DispatchQueue.main)
  }
}
