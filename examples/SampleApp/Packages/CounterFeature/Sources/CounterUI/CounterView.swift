import AccessibilityIDs
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
        .accessibilityIdentifier(AccessibilityID.counterValue.rawValue)

      HStack(spacing: 32) {
        Button("Decrement", systemImage: "minus") { store.send(.decrementButtonTapped) }
          .accessibilityIdentifier(AccessibilityID.counterDecrement.rawValue)
        Button("Increment", systemImage: "plus") { store.send(.incrementButtonTapped) }
          .accessibilityIdentifier(AccessibilityID.counterIncrement.rawValue)
      }
      .labelStyle(.iconOnly)
      .font(.title)
      .buttonStyle(.bordered)

      Button("Cat fact") { store.send(.factButtonTapped) }
        .disabled(store.isLoadingFact)
        .accessibilityIdentifier(AccessibilityID.counterFact.rawValue)

      if store.isLoadingFact {
        ProgressView()
      } else if let fact = store.fact {
        Text(fact)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier(AccessibilityID.counterFactText.rawValue)
      }
    }
    .padding()
  }
}

#Preview {
  CounterView(store: Store(initialState: CounterFeature.State()) { CounterFeature() })
}
