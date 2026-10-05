import Foundation
import SwiftGateDomain
import SwiftGateRules
import Testing

/// The detail test a price-tracker-3 worker wrote, whose `dismissCancelsChart` spins on
/// `while !started.value { await Task.yield() }`: `test-only` and `slice` ran it for about 1700 s.
@Suite("unbounded waits in changed test files")
struct ChangedTestWaitsTests {
  static let path = "Packages/AppFeature/Tests/AppCoreTests/DetailFeatureTests.swift"

  static func fixture(_ name: String) throws -> String {
    try String(
      contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/BrownfieldTrial/\(name)"),
      encoding: .utf8)
  }

  static func file(_ text: String, added: [ClosedRange<Int>]? = nil) -> ChangedTestFile {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    return ChangedTestFile(
      path: path, content: text, added: AddedLines(path: path, ranges: added ?? [1...lines]))
  }

  @Test(
    "the captured spinning test, new in the change, is RED at both of its loops with file and line, and the same file once its author bounded it is clean — catches a gate starting a run the spin holds until its bound"
  )
  func capturedSpinIsFoundAtItsLoops() throws {
    let spin = Self.findings([
      Self.file(try Self.fixture("price-tracker-3-DetailFeatureTests-spin.swift"))
    ])
    #expect(spin.map(\.ruleID) == [ChangedTestWaits.ruleID, ChangedTestWaits.ruleID])
    #expect(spin.map(\.file) == [Self.path, Self.path])
    #expect(spin.map(\.line) == [100, 102])
    #expect(spin.allSatisfy { $0.severity.failsGate })

    let fixed = Self.findings([
      Self.file(try Self.fixture("price-tracker-3-DetailFeatureTests.swift"))
    ])
    #expect(fixed.isEmpty, "\(fixed.map(\.message))")
  }

  @Test(
    "of the 2 spins, only the one on a line the change added gates it — catches a brownfield test file's old loop failing every task that edits the file"
  )
  func onlyAddedLoopsGate() throws {
    let text = try Self.fixture("price-tracker-3-DetailFeatureTests-spin.swift")
    #expect(Self.findings([Self.file(text, added: [15...30, 102...102])]).map(\.line) == [102])
  }

  private static func findings(_ files: [ChangedTestFile]) -> [Finding] {
    ChangedTestWaits.findings(files)
  }
}
