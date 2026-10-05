import APIClient
import AppCore
import ComposableArchitecture
import SwiftUI

public struct WatchlistView: View {
  @Bindable var store: StoreOf<WatchlistFeature>

  public init(store: StoreOf<WatchlistFeature>) {
    self.store = store
  }

  public var body: some View {
    Group {
      if store.isLoading && store.quotes.isEmpty {
        ProgressView()
          .accessibilityIdentifier(AccessibilityID.Watchlist.loading)
      } else {
        list
      }
    }
    .navigationTitle("Watchlist")
    .navigationDestination(item: $store.scope(state: \.detail, action: \.detail)) { detail in
      AssetDetailView(store: detail)
    }
    .task { await store.send(.task).finish() }
  }

  private var list: some View {
    List {
      ForEach(store.assets) { asset in
        if let quote = store.quotes[asset.id] {
          row(asset, quote)
        }
      }
      if let updated = store.lastUpdated {
        Text("Last updated \(updated.formatted(.dateTime.hour().minute().second()))")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(AccessibilityID.Watchlist.lastUpdated)
      }
    }
    .accessibilityIdentifier(AccessibilityID.Watchlist.list)
    .refreshable { await store.send(.refreshPulled).finish() }
    .safeAreaInset(edge: .top, spacing: 0) {
      if store.loadError != nil {
        VStack(alignment: .leading, spacing: 8) {
          Text("Couldn't load prices")
            .accessibilityIdentifier(AccessibilityID.Watchlist.error)
          Button("Try again") { store.send(.retryButtonTapped) }
            .accessibilityIdentifier(AccessibilityID.Watchlist.retry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.bar)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Color.clear
        .frame(height: 1)
        .accessibilityElement()
        .accessibilityIdentifier(AccessibilityID.Watchlist.bottom)
    }
  }

  private func row(_ asset: Asset, _ quote: Quote) -> some View {
    Button {
      store.send(.assetTapped(asset.id))
    } label: {
      HStack {
        Text(asset.name)
          .accessibilityIdentifier(AccessibilityID.Watchlist.name(asset.id))
        Spacer()
        VStack(alignment: .trailing) {
          Text(WatchlistFormat.priceText(quote.usd))
            .accessibilityIdentifier(AccessibilityID.Watchlist.price(asset.id))
          Text(WatchlistFormat.changeText(quote.change24h))
            .foregroundStyle(WatchlistFormat.isUp(quote.change24h) ? Color.green : Color.red)
            .accessibilityIdentifier(AccessibilityID.Watchlist.change(asset.id))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(AccessibilityID.Watchlist.row(asset.id))
  }
}
