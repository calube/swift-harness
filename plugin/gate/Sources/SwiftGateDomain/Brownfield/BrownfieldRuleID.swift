/// Every rule id the brownfield profile reports, so the rule index and the checks share 1 closed
/// list.
public enum BrownfieldRuleID: String, Sendable, CaseIterable {
  /// A changed test passes with the change's source reverted.
  case notProven = "neutral.not-proven"
  /// A changed test with no assertion, or only a tautology.
  case noAssertion = "neutral.no-assertion"
  /// An escape hatch, a lint suppression, or a skipped or focused test on an added line.
  case unsafeShortcut = "neutral.unsafe-shortcut"
  /// The repository's own linter, on added lines only.
  case lint = "neutral.lint"
  /// A new Swift file under a source root that no target compiles.
  case fileNotInTarget = "xcode.file-not-in-target"
  /// An area's test command failed and the baseline doesn't hold the failure.
  case testFailed = "area.test-failed"
  case buildFailed = "area.build-failed"
  case lintFailed = "area.lint-failed"
  /// A step the orchestrator dropped, which the report names.
  case stepDropped = "area.step-dropped"
  /// An area whose tests don't fit the `slice` budget, so `slice` only builds it.
  case buildOnly = "area.build-only"
  /// The failures the baseline absorbed.
  case baselineSummary = "baseline.summary"
  /// A test step `final` would excuse whole: it fails at the head and the merge base with no
  /// test id to tell its failures apart.
  case baselineWholeStep = "baseline.whole-step"
  /// A committed `.swiftgate.toml` and a common-dir `config.toml` in 1 clone.
  case doctorConfigConflict = "doctor.config-conflict"
}
