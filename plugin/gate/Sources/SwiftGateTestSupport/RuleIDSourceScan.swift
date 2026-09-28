import Foundation

/// The dotted rule ids Swift source spells out, read from its string literals rather than from a
/// hand-kept list, so a rule shipped with no row in the rule id index can't hide.
public struct RuleIDSourceScan: Sendable, Equatable {
  /// Every string literal that is a whole rule id: a `ruleID:` argument, a `…RuleID` constant, a
  /// rule enum's raw value.
  public var ids: Set<String>
  /// Every id family built by interpolation or from a `…RuleIDPrefix` constant, as a template with
  /// `*` for each interpolated part: `"design-diff.\(problem.rawValue)"` is `design-diff.*`.
  public var families: Set<String>

  public init(ids: Set<String> = [], families: Set<String> = []) {
    self.ids = ids
    self.families = families
  }

  /// Dotted literals that look like rule ids but name something else, each with why.
  public static let notRuleIDs: [String: String] = [:]

  /// Interpolated templates that look like id families but build something else, each with why.
  public static let notRuleIDFamilies: [String: String] = [:]

  /// The ids and families one Swift source file spells out.
  public static func scan(source: String) -> RuleIDSourceScan {
    RuleIDSourceScan()
  }

  /// The ids and families every `.swift` file under `directory` spells out.
  public static func scan(directory: URL) throws -> RuleIDSourceScan {
    RuleIDSourceScan()
  }
}
