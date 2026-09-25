import ComposableArchitecture
import FeedCore
import SwiftUI

public struct FeedView: View {
  let store: StoreOf<Feed>
  public var body: some View { List(store.items, id: \.self) { Text($0) } }
}
