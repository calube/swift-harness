/// Every rule `design-lint` reports (spec §5.3, §6.2). A finding's rule id is the raw value, and
/// the rule id index is checked against `allCases`, so a rule added here without an index row
/// fails the build's tests.
public enum DesignLintRule: String, Sendable, CaseIterable {
  case statusUnknown = "design-lint.status-unknown"
  case claimsFileMissing = "design-lint.claims-file-missing"
  case claimsFileUnreadableLines = "design-lint.claims-file-unreadable-lines"
  case sectionMissing = "design-lint.section-missing"
  case sectionOrder = "design-lint.section-order"
  case problemEmpty = "design-lint.problem-empty"
  case requirementIDForm = "design-lint.requirement-id-form"
  case testIDForm = "design-lint.test-id-form"
  case requirementIDDuplicate = "design-lint.requirement-id-duplicate"
  case testIDDuplicate = "design-lint.test-id-duplicate"
  case testTierInvalid = "design-lint.test-tier-invalid"
  case optionsCount = "design-lint.options-count"
  case moduleKindUnknown = "design-lint.module-kind-unknown"
  case unknownTier = "design-lint.unknown-tier"
  case untaggedBullet = "design-lint.untagged-bullet"
  case unverifiedInDecision = "design-lint.unverified-in-decision"
  case unknownClaim = "design-lint.unknown-claim"
  case citationNotSupported = "design-lint.citation-not-supported"
  case claimIDDuplicate = "design-lint.claim-id-duplicate"
  case unverifiedUncovered = "design-lint.unverified-uncovered"
  case perfMissingDimension = "design-lint.perf-missing-dimension"
  case architectureDiagramUnknownType = "design-lint.architecture-diagram-unknown-type"
  case architectureDiagramCount = "design-lint.architecture-diagram-count"
  case mmdcUnavailable = "design-lint.mmdc-unavailable"
  case mermaidSyntax = "design-lint.mermaid-syntax"
  case sectionWordBudget = "design-lint.section-word-budget"
  case documentWordBudget = "design-lint.document-word-budget"

  public static var allCases: [DesignLintRule] { [] }
}
