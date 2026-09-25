import Foundation
import SwiftGateDomain
import SwiftGateRules
import Testing

/// Checker hygiene: every rule has `bad/` and `good/` fixtures, fires on every `bad` file and stays
/// quiet on every `good` file.
@Suite("Rule fixtures")
struct RuleFixtureTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/rules", directoryHint: .isDirectory)

  static let ruleIDs = RuleCatalog.all.map(\.descriptor.id)

  private static func swiftFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func manifest(for ruleID: String) throws -> RuleFixtureManifest {
    let file = fixturesRoot.appending(path: "\(ruleID)/fixture.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return RuleFixtureManifest() }
    return try JSONDecoder().decode(RuleFixtureManifest.self, from: Data(contentsOf: file))
  }

  private static func findings(ruleID: String, variant: String) throws -> [(String, [Finding])] {
    let rule = try #require(RuleCatalog.all.first { $0.descriptor.id == ruleID })
    let files = try swiftFiles(in: fixturesRoot.appending(path: "\(ruleID)/\(variant)"))
    #expect(!files.isEmpty, "\(ruleID)/\(variant) has no fixtures")
    return try RuleFixtureCheck.run(
      rule: rule, manifest: manifest(for: ruleID),
      files: files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    ).map { ($0.fileName, $0.findings) }
  }

  @Test(
    "every catalogued rule has a fixture directory and no fixture directory is orphaned — catches a rule shipping without a seeded violation"
  )
  func fixtureDirectoriesMatchCatalog() throws {
    let directories = try FileManager.default.contentsOfDirectory(
      at: Self.fixturesRoot, includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).filter { !$0.hasPrefix(".") }
    #expect(Set(directories) == Set(Self.ruleIDs))
  }

  @Test(
    "each rule fires on every bad fixture — catches a rule whose visitor silently stopped matching",
    arguments: ruleIDs)
  func badFixturesFire(ruleID: String) throws {
    for (file, findings) in try Self.findings(ruleID: ruleID, variant: "bad") {
      #expect(!findings.isEmpty, "\(ruleID) did not fire on bad/\(file)")
    }
  }

  @Test(
    "each rule is quiet on every good fixture — catches false positives on legitimate code",
    arguments: ruleIDs)
  func goodFixturesQuiet(ruleID: String) throws {
    for (file, findings) in try Self.findings(ruleID: ruleID, variant: "good") {
      #expect(
        findings.isEmpty,
        "\(ruleID) fired on good/\(file): \(findings.map { "\($0.line ?? 0): \($0.message)" })")
    }
  }
}
