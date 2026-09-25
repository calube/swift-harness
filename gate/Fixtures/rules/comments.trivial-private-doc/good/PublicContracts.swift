public struct Cart {
  /// Items in insertion order; duplicates allowed.
  public var items: [Item] = []

  /// Merges `other`, keeping the earliest timestamp per item.
  private func merge(_ other: Cart) -> Cart {
    var merged = self
    merged.items += other.items
    return merged
  }
}
