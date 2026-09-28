import AppCore
import ComposableArchitecture
import SwiftUI

public struct AppView: View {
  let store: StoreOf<AppFeature>

  public init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        switch store.status {
        case .idle, .loading:
          ProgressView()
        case .loaded(let postCount):
          Text("\(postCount) posts available")
            .accessibilityIdentifier("app.status")
        case .failed:
          Text("Couldn't load posts")
            .accessibilityIdentifier("app.status")
          Button("Try again") { store.send(.retryButtonTapped) }
            .accessibilityIdentifier("app.retry")
        }
      }
      .padding()
      .navigationTitle("Posts")
    }
    .task { await store.send(.task).finish() }
  }
}

#Preview {
  AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
