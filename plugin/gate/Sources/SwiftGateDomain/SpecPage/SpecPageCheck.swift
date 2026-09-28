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
    text.split(whereSeparator: \.isWhitespace).count
  }

  /// Whether `quote` appears in `spec` word for word.
  ///
  /// Runs of whitespace compare as 1 space, so a line the spec file wraps still matches. Case,
  /// punctuation and quote marks compare exactly, and the quote may not start or end inside a
  /// word: a quote that drops whole words from either end is still the spec's own text.
  public static func quoteAppears(_ quote: String, in spec: String) -> Bool {
    let quote = collapsed(quote)
    let spec = collapsed(spec)
    guard let first = quote.first, let last = quote.last else { return false }
    var from = spec.startIndex
    while from < spec.endIndex, let match = spec.range(of: quote, range: from..<spec.endIndex) {
      let startsClean =
        !isWordCharacter(first) || match.lowerBound == spec.startIndex
        || !isWordCharacter(spec[spec.index(before: match.lowerBound)])
      let endsClean =
        !isWordCharacter(last) || match.upperBound == spec.endIndex
        || !isWordCharacter(spec[match.upperBound])
      if startsClean, endsClean { return true }
      from = spec.index(after: match.lowerBound)
    }
    return false
  }

  private static func collapsed(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  /// The lowercase hex SHA-256 of the page's bytes.
  public static func pageSha(_ bytes: Data) -> String {
    CaptureDigest.sha256Hex(bytes)
  }

  /// Checks `page` against `spec`. `pagePath` locates the findings.
  public static func check(page: String, pagePath: String, spec: String)
    throws(ReportContractViolation) -> SpecPageReport
  {
    var findings: [Finding] = []
    func add(_ rule: Rule, _ severity: Severity, _ line: Int?, _ message: String)
      throws(ReportContractViolation)
    {
      findings.append(
        try Finding(
          ruleID: rule.rawValue, severity: severity, file: pagePath, line: line,
          message: message, failureScenario: nil))
    }
    let words = wordCount(page)
    let parsed: SpecPage
    switch SpecPage.parse(page) {
    case .malformed(let problems):
      for problem in problems { try add(.format, .major, problem.line, problem.message) }
      if words > maxWords { try add(.tooLong, .major, nil, tooLong(words)) }
      try add(
        .summary, .nit, nil,
        "the page breaks the spec page format in \(problems.count) place(s); no confirm until "
          + "it parses")
      return SpecPageReport(page: nil, confirm: nil, findings: findings)
    case .parsed(let page):
      parsed = page
    }
    if words > maxWords { try add(.tooLong, .major, nil, tooLong(words)) }
    var confirm = Confirm.skippable
    for slice in parsed.slices {
      switch slice.spec {
      case .none:
        confirm = .required
      case .quote(let quote):
        guard !quoteAppears(quote, in: spec) else { continue }
        confirm = .required
        try add(
          .quoteNotInSpec, .major, slice.line,
          "slice \(slice.number) (`\(slice.testName)`) quotes \"\(quote)\", which the spec file "
            + "doesn't hold word for word; quote its own line, or write `Spec: none`")
      }
    }
    let none = parsed.slices.filter { $0.spec == .none }.count
    try add(
      .summary, .nit, nil,
      "\(parsed.slices.count) slice(s), \(none) marked `Spec: none`, \(words) words; confirm: "
        + confirm.rawValue)
    return SpecPageReport(page: parsed, confirm: confirm, findings: findings)
  }

  private static func tooLong(_ words: Int) -> String {
    "the page has \(words) words; a spec page has at most \(maxWords)"
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
    findings.contains { $0.severity.failsGate } ? .red : .green
  }
}
