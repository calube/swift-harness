import AppCore
import ComposableArchitecture
import SwiftUI

public struct WatchlistView: View {
  @Bindable var store: StoreOf<WatchlistFeature>

  public init(store: StoreOf<WatchlistFeature>) {
    self.store = store
  }

  public var body: some View {
    Text("Watchlist")
      .accessibilityIdentifier(AccessibilityID.Watchlist.list)
  }
}
