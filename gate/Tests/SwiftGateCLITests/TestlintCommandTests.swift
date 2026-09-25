import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate testlint")
struct TestlintCommandTests {
  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    [[flows]]
    name = "checkout"
    reason = "revenue-critical"

    """

  private func makeRepository(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-testlint-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    for (path, content) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    return root
  }

  private static let noAssertionTest = """
    import Testing
    @Test("adds — catches a stale total")
    func add() { _ = 1 }

    """

  @Test(
    "lints test files under the given paths and skips production code — catches helpers linted as tests"
  )
  func lintsTestFiles() throws {
    let root = try makeRepository([
      ".swiftgate.toml": Self.config,
      "Packages/Cart/Tests/CartCoreTests/CartTests.swift": Self.noAssertionTest,
      "Packages/Cart/Sources/CartCore/Helpers.swift": "func testHelper() { _ = try? run() }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let outcome = TestlintCheck.run(root: root, paths: ["Packages"])
    guard case .checked(let result) = outcome else {
      Issue.record("expected checked, got \(outcome)")
      return
    }
    #expect(
      result.findings.map { "\($0.file):\($0.line ?? 0):\($0.ruleID)" } == [
        "Packages/Cart/Tests/CartCoreTests/CartTests.swift:3:test.no-assertion"
      ])
  }

  @Test("XCUITest flows come from .swiftgate.toml — catches the closed T3 list not being enforced")
  func flowsFromConfig() throws {
    let uiTest = """
      import XCTest
      final class SettingsUITests: XCTestCase {
        func testTheme() { XCTAssertTrue(XCUIApplication().exists) }
      }
      final class CheckoutUITests: XCTestCase {
        func testPay() { XCTAssertTrue(XCUIApplication().buttons["Pay"].exists) }
      }

      """
    let root = try makeRepository([
      ".swiftgate.toml": Self.config, "App/AppUITests/Flows.swift": uiTest,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    guard case .checked(let result) = TestlintCheck.run(root: root, paths: []) else {
      Issue.record("expected checked")
      return
    }
    #expect(result.findings.map(\.ruleID) == ["test.xcuitest-unlisted-flow"])
    #expect(result.findings.map(\.line) == [3])
  }

  @Test(
    "an invalid config is RED and a missing path is BLOCKED — catches a broken setup reported GREEN"
  )
  func setupFailures() throws {
    let root = try makeRepository([".swiftgate.toml": "schema = 1\nbogus = 2\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1, outcome: TestlintCheck.run(root: root, paths: []))
    #expect(invalid.verdict == .red)
    #expect(invalid.findings.map(\.ruleID) == [StaticCheckReport.configRuleID])

    try FileManager.default.removeItem(at: root.appending(path: ".swiftgate.toml"))
    let missing = try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1, outcome: TestlintCheck.run(root: root, paths: ["Nope"]))
    #expect(missing.verdict == .blocked)
  }

  @Test("paths default to the repository root — catches `swiftgate testlint` checking nothing")
  func parsesPaths() throws {
    #expect(try TestlintCommand.parseAsRoot([]) is TestlintCommand)
    let command = try #require(
      try TestlintCommand.parseAsRoot(["A", "B", "--json"]) as? TestlintCommand)
    #expect(command.paths == ["A", "B"])
  }
}
