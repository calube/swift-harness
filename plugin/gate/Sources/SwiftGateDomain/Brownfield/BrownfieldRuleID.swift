/// Every rule id the brownfield profile reports, so the rule index and the checks share 1 closed
/// list.
public enum BrownfieldRuleID: String, Sendable, CaseIterable {
  /// A committed `.swiftgate.toml` and a common-dir `config.toml` in 1 clone.
  case doctorConfigConflict = "doctor.config-conflict"
}
