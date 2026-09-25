/// Every rule the gate ships, grouped by the command that runs it.
public enum RuleCatalog {
  /// `swiftgate comments --staged`.
  public static let comments: [any Rule] = CommentRules.all

  /// `swiftgate testlint`.
  public static let testlint: [any Rule] = TestlintRules.all

  /// `swiftgate lint`.
  public static let lint: [any Rule] =
    DeterminismRules.all + BoundaryRules.all + SafetyRules.all + TCARules.all

  public static var all: [any Rule] { comments + testlint + lint }
}
