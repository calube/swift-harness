import AppCore
import ComposableArchitecture
import SwiftUI

public struct WatchlistView: View {
  @Bindable var store: StoreOf<WatchlistFeature>

  public init(store: StoreOf<WatchlistFeature>) {
    self.store = store
  }

  public var body: some View {
    ProgressView()
      .accessibilityIdentifier(AccessibilityID.Watchlist.loading)
      .navigationTitle("Prices")
  }
}
