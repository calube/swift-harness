import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("SwiftFormatter")
struct SwiftFormatterTests {
  @Test(
    "strict lint output parses to one violation per line, parse errors included — catches a malformed file passing format lint"
  )
  func parsesRecordedLint() throws {
    let stderr = try Fixture.text("SwiftFormat/lint-strict.stderr")

    let violations = try SwiftFormatOutput.violations(
      in: stderr, repositoryRoot: "\(Fixture.repositoryRoot)/gate/Fixtures/format")

    #expect(violations.count == 6)
    #expect(
      violations.first
        == FormatViolation(
          path: "Unformatted.swift", line: 3, column: 1, rule: "Indentation",
          message: "unindent by 2 spaces"))
    #expect(
      violations.last
        == FormatViolation(
          path: "Broken.swift", line: 1, column: 15, rule: nil,
          message: "expected value and ')' to end tuple"))
    #expect(!violations.contains { $0.path == "Formatted.swift" })
  }

  @Test(
    "unrecognised output is an error, not an empty result — catches a crashed formatter reading as clean"
  )
  func rejectsUnknownOutput() {
    #expect(throws: SwiftFormatError.self) {
      try SwiftFormatOutput.violations(
        in: "error: Unable to read configuration\n", repositoryRoot: "/REPO")
    }
  }

  @Test(
    "the live formatter lints relative paths and rewrites a file in place — catches format drift between hook and gate"
  )
  func liveFormatter() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-format-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Unformatted.swift", "Formatted.swift"] {
      try FileManager.default.copyItem(
        at: Fixture.gateDirectory.appending(path: "Fixtures/format/\(name)"),
        to: root.appending(path: name))
    }
    let formatter = LiveSwiftFormatter(runner: LiveProcessRunner(), repositoryRoot: root.path)

    let before = try await formatter.lint(paths: ["Unformatted.swift", "Formatted.swift"])
    let changed = try await formatter.format(path: "Unformatted.swift")
    let unchanged = try await formatter.format(path: "Formatted.swift")
    let after = try await formatter.lint(paths: ["Unformatted.swift"])

    #expect(Set(before.map(\.path)) == ["Unformatted.swift"])
    #expect(changed)
    #expect(!unchanged)
    #expect(after.isEmpty)
  }
}
