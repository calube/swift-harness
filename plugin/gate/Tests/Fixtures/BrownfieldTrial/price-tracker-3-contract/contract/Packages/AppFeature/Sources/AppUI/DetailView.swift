import AppCore
import ComposableArchitecture
import SwiftUI

public struct DetailView: View {
  let store: StoreOf<DetailFeature>

  public init(store: StoreOf<DetailFeature>) {
    self.store = store
  }

  public var body: some View {
    Text(store.asset.name)
      .accessibilityIdentifier(AccessibilityID.Detail.name)
      .navigationTitle(store.asset.name)
  }
}
