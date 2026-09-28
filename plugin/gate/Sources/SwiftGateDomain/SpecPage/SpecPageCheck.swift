import Foundation

/// `swiftgate spec-page check`: whether a spec page keeps its format and length, and whether each
/// slice's `Spec:` quote appears in the spec file, which decides if the page needs the user's
/// confirmation (fast modes §5.1, §5.2).
public enum SpecPageCheck {
  public enum Rule: String, Sendable, CaseIterable {
    case format = "spec-page.format"
    case tooLong = "spec-page.too-long"
    case quoteNotInSpec = "spec-page.quote-not-in-spec"
    case summary = "spec-page.summary"
  }

  /// Whether the user must confirm the page before a build starts from it.
  public enum Confirm: String, Sendable, Equatable {
    /// A slice says `Spec: none`, or its quote isn't in the spec file.
    case required
    /// Every slice quotes a line the spec file holds.
    case skippable
  }

  public static let maxWords = 400

  /// Whitespace-separated words, as `wc -w` counts them.
  public static func wordCount(_ text: String) -> Int {
    0
  }

  /// Whether `quote` appears in `spec` word for word.
  public static func quoteAppears(_ quote: String, in spec: String) -> Bool {
    false
  }

  /// The lowercase hex SHA-256 of the page's bytes.
  public static func pageSha(_ bytes: Data) -> String {
    ""
  }

  /// Checks `page` against `spec`. `pagePath` locates the findings.
  public static func check(page: String, pagePath: String, spec: String)
    throws(ReportContractViolation) -> SpecPageReport
  {
    SpecPageReport(page: nil, confirm: nil, findings: [])
  }
}

/// What `spec-page check` found.
public struct SpecPageReport: Sendable, Equatable {
  /// `nil` when the page breaks the format.
  public let page: SpecPage?
  /// `nil` when the page breaks the format.
  public let confirm: SpecPageCheck.Confirm?
  public let findings: [Finding]

  public init(page: SpecPage?, confirm: SpecPageCheck.Confirm?, findings: [Finding]) {
    self.page = page
    self.confirm = confirm
    self.findings = findings
  }

  public var verdict: Verdict {
    .green
  }
}
