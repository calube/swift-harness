import ComposableArchitecture
import SwiftUI

@Reducer
struct Parent {
  var body: some ReducerOf<Self> {
    Scope(state: \.child, action: \.child) { Child() }
  }
}

struct ParentView: View {
  @Bindable var store: StoreOf<Parent>
  var body: some View {
    ChildView(store: store.scope(state: \.child, action: \.child))
      .sheet(item: $store.scope(state: \.destination?.edit, action: \.destination.edit)) {
        EditView(store: $0)
      }
      .onAppear { store.send(.appeared, animation: .default) }
  }
}

func effect() -> Effect<Parent.Action> {
  .run { send in await send(.loaded, animation: .spring) }
}
