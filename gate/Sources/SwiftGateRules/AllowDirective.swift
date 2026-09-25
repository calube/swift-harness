/// `// swiftgate:allow <rule-id> — <reason>`: waives one rule on the line the comment starts on.
///
/// The separator is an em dash; `--` is accepted as its ASCII spelling. Anything else after the
/// rule id (or nothing) leaves `reason` nil, which the engine reports as a bare allow.
public struct AllowDirective: Sendable, Equatable {
  public static let marker = "swiftgate:allow"

  public let ruleID: String
  public let line: Int
  public let reason: String?

  public init(ruleID: String, line: Int, reason: String?) {
    self.ruleID = ruleID
    self.line = line
    self.reason = reason
  }

  init?(comment: SourceComment) {
    guard comment.kind == .line || comment.kind == .block,
      let parsed = Self.parse(comment.body)
    else { return nil }
    self.init(ruleID: parsed.ruleID, line: comment.startLine, reason: parsed.reason)
  }

  static func parse(_ body: String) -> (ruleID: String, reason: String?)? {
    guard body.hasPrefix(marker) else { return nil }
    let rest = body.dropFirst(marker.count)
    guard rest.first?.isWhitespace == true else { return nil }
    let afterSpace = rest.drop { $0.isWhitespace }
    let ruleID = afterSpace.prefix { !$0.isWhitespace }
    guard !ruleID.isEmpty else { return nil }
    var tail = afterSpace.dropFirst(ruleID.count).drop { $0.isWhitespace }
    if tail.hasPrefix("—") {
      tail = tail.dropFirst()
    } else if tail.hasPrefix("--") {
      tail = tail.dropFirst(2)
    } else {
      return (String(ruleID), nil)
    }
    let reason = tail.trimmed
    return (String(ruleID), reason.isEmpty ? nil : reason)
  }
}

/// A waived finding, kept so reports can count waivers.
public struct Allowance: Sendable, Equatable {
  public let ruleID: String
  public let path: String
  public let line: Int
  public let reason: String

  public init(ruleID: String, path: String, line: Int, reason: String) {
    self.ruleID = ruleID
    self.path = path
    self.line = line
    self.reason = reason
  }
}
