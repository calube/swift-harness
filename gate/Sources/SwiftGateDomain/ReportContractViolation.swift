/// A report value that breaks the schema's invariants. Thrown both when constructing values in
/// code and when decoding JSON written by another process.
public enum ReportContractViolation: Error, Sendable, Equatable {
  case empty(field: String)
  case outOfRange(field: String, value: Int)
  case duplicateTier(Tier)
  case greenWithFailedTests(Tier, failed: Int)
  case unsupportedSchemaVersion(Int)
  case verdictMismatch(stored: Verdict, derived: Verdict)
}

func requireNonEmpty(_ value: String, field: String) throws(ReportContractViolation) {
  if value.isEmpty { throw .empty(field: field) }
}

func requireNonNegative(_ value: Int, field: String) throws(ReportContractViolation) {
  if value < 0 { throw .outOfRange(field: field, value: value) }
}
