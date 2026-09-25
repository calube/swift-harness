import SwiftGateDomain

/// Runs one rule over its single-file fixtures (`Fixtures/rules/<rule-id>/{bad,good}/`) under the
/// fixture's manifest context. Shared by the test suite and `swiftgate self-test` so both judge
/// fixtures identically.
public enum RuleFixtureCheck {
  public struct FileResult: Sendable, Equatable {
    public let fileName: String
    /// Findings of the rule under test only.
    public let findings: [Finding]
  }

  public static func run(
    rule: any Rule, manifest: RuleFixtureManifest, files: [(name: String, text: String)]
  ) throws -> [FileResult] {
    let context = try manifest.context()
    let engine = RuleEngine(rules: [rule])
    return try files.map { file in
      let input = SourceInput(path: manifest.path(forFileNamed: file.name), text: file.text)
      let result = try engine.run([input], context: context)
      return FileResult(
        fileName: file.name,
        findings: result.findings.filter { $0.ruleID == rule.descriptor.id })
    }
  }
}
