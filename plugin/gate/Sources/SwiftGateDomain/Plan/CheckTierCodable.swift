/// `CheckTier`'s `Codable` conformance, declared here rather than in `Check.swift` (a file other
/// tasks still edit) so `LedgerTask.gate` can use the tier type directly instead of its raw
/// string. `CheckTier` is a `String`-backed `RawRepresentable` enum, so the compiler synthesizes
/// the single-value-container implementation: encoding writes the raw value, and decoding an
/// unrecognized string fails with a `DecodingError` instead of silently accepting it.
extension CheckTier: Codable {}
