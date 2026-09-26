/// Deterministic sampling beyond `[mutation] max_mutants`: the seed comes from the diff, so a
/// rerun on the same change judges the same mutants.
public enum MutantSampling {
  /// 64-bit FNV-1a of the UTF-8 bytes. `Hasher` is seeded per process, so it cannot be used.
  public static func seed(diff: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in diff.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01b3
    }
    return hash
  }

  /// Up to `limit` mutants, in source order.
  public static func sample(_ mutants: [Mutant], limit: Int, seed: UInt64) -> [Mutant] {
    var ordered = mutants.sorted(by: Mutant.sourceOrder)
    guard ordered.count > limit else { return ordered }
    var state = seed
    // Fisher–Yates over SplitMix64: fixed algorithm, unlike the standard library's shuffle.
    for index in stride(from: ordered.count - 1, to: 0, by: -1) {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      z ^= z >> 31
      ordered.swapAt(index, Int(z % UInt64(index + 1)))
    }
    return Array(ordered.prefix(max(0, limit))).sorted(by: Mutant.sourceOrder)
  }
}
