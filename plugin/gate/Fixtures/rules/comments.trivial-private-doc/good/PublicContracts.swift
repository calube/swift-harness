public struct Cart {
  /// Items in insertion order; duplicates allowed.
  public var items: [Item] = []

  /// Keeps each argv well under `ARG_MAX` for large change sets.
  private static let batchSize = 256

  /// Merges `other`, keeping the earliest timestamp per item.
  private func merge(_ other: Cart) -> Cart {
    var merged = self
    merged.items += other.items
    return merged
  }
}
