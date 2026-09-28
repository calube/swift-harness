import ComposableArchitecture
import CounterCore
import SwiftUI

public struct CounterView: View {
  let store: StoreOf<CounterFeature>

  public init(store: StoreOf<CounterFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: 24) {
      Text("\(store.count)")
        .font(.system(size: 64, weight: .bold, design: .rounded))
        .monospacedDigit()
        .accessibilityIdentifier("counter.value")

      HStack(spacing: 32) {
        Button("Decrement", systemImage: "minus") { store.send(.decrementButtonTapped) }
          .accessibilityIdentifier("counter.decrement")
        Button("Increment", systemImage: "plus") { store.send(.incrementButtonTapped) }
          .accessibilityIdentifier("counter.increment")
      }
      .labelStyle(.iconOnly)
      .font(.title)
      .buttonStyle(.bordered)

      Button("Cat fact") { store.send(.factButtonTapped) }
        .disabled(store.isLoadingFact)
        .accessibilityIdentifier("counter.fact")

      if store.isLoadingFact {
        ProgressView()
      } else if let fact = store.fact {
        Text(fact)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("counter.factText")
      }
    }
    .padding()
  }
}

#Preview {
  CounterView(store: Store(initialState: CounterFeature.State()) { CounterFeature() })
}
