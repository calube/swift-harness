import AppCore
import ComposableArchitecture
import SwiftUI

/// Identifiers: `detail.loading`, `detail.error`, `detail.retryLoad` ("Try again"),
/// `detail.note.<uuid>` (each note's text), `detail.status` (delivery label "Sending",
/// "Sent" or "Failed" on notes sent in this detail), `detail.retry` ("Retry" on a failed
/// note), `detail.input` (draft field, placeholder "Note"), `detail.send` ("Send").
public struct DetailView: View {
  @Bindable var store: StoreOf<DetailFeature>

  public init(store: StoreOf<DetailFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack {
      switch store.status {
      case .idle, .loading:
        ProgressView()
          .accessibilityIdentifier("detail.loading")
        Spacer()
      case .failed:
        Text("Couldn't load notes")
          .accessibilityIdentifier("detail.error")
        Button("Try again") { store.send(.retryLoadButtonTapped) }
          .accessibilityIdentifier("detail.retryLoad")
        Spacer()
      case .loaded:
        List(store.notes) { item in
          VStack(alignment: item.note.isMine ? .trailing : .leading) {
            Text(item.note.text)
              .accessibilityIdentifier("detail.note.\(item.id)")
            if let delivery = item.delivery {
              Text(Self.label(delivery))
                .accessibilityIdentifier("detail.status")
              if delivery == .failed {
                Button("Retry") { store.send(.retryButtonTapped(item.id)) }
                  .accessibilityIdentifier("detail.retry")
              }
            }
          }
        }
      }
      HStack {
        TextField("Note", text: $store.draft.sending(\.draftChanged))
          .accessibilityIdentifier("detail.input")
        Button("Send") { store.send(.sendButtonTapped) }
          .accessibilityIdentifier("detail.send")
      }
      .padding()
    }
    .navigationTitle(store.item.title)
    .task { await store.send(.task).finish() }
  }

  static func label(_ delivery: DetailFeature.Delivery) -> String {
    switch delivery {
    case .sending: "Sending"
    case .sent: "Sent"
    case .failed: "Failed"
    }
  }
}
