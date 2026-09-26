nonisolated(unsafe) let formatter = makeFormatter() // swiftgate:allow safety.nonisolated-unsafe — immutable after init; never mutated
actor Store {
  nonisolated func describe() -> String { "store" }
}
