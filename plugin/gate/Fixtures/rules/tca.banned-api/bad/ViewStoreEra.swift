import ComposableArchitecture
import SwiftUI

struct LegacyView: View {
  let store: StoreOf<Feature>
  let viewStore: ViewStoreOf<Feature>
  var body: some View {
    WithViewStore(store, observe: { $0 }) { viewStore in Text("\(viewStore.count)") }
  }
  func peek() -> Int { store.withState(\.count) }
  func stream() { _ = store.publisher.count }
}

struct State {
  @BindingState var text = ""
}
struct Bindings: Equatable {
  let view: BindingViewState<State>
  let path: AnyCasePath<Action, Int>
}
