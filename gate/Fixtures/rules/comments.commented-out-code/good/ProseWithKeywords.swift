// MARK: - Loading

func load(_ cache: [String: Int], key: String) -> Int? {
  // return early if the cache is warm, because the disk read costs 40ms
  // The server may send nil for deleted rows.
  // Done
  // swiftlint:disable:next force_unwrapping — key presence checked by the caller
  #warning("TODO: replace with the batch endpoint")
  return cache[key]
}

/// Usage:
/// ```swift
/// let value = load(cache, key: "a")
/// ```
func documented() {}

let example = "// print(value)"
// https://example.com/docs/caching
// Note: the invariant is count > 0
// Keep retries <= 3 and attempts >= 1; count != 0 after a tap.
