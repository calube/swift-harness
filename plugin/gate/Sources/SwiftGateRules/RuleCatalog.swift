/// Every rule the gate ships, grouped by the command that runs it.
public enum RuleCatalog {
  /// `swiftgate comments --staged`.
  public static let comments: [any Rule] = CommentRules.all

  /// `swiftgate testlint`.
  public static let testlint: [any Rule] = TestlintRules.all

  /// `swiftgate lint`.
  public static let lint: [any Rule] =
    DeterminismRules.all + BoundaryRules.all + SafetyRules.all + TCARules.all

  /// `swiftgate arch`'s source-level rules; its module-graph rules are `ArchitectureRules`.
  public static let arch: [any Rule] = ArchSourceRules.all

  /// Rules whose fixtures are single files under `Fixtures/rules/`. Arch rules need whole package
  /// trees and have their own fixtures under `Fixtures/arch/`.
  public static var all: [any Rule] { comments + testlint + lint }
}
