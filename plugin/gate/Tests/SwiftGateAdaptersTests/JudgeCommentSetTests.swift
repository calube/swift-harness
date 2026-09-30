import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The comment judge's labelled set under `gate/Fixtures/judge-comments/` (spec §10.2): comments
/// commits added to this repository's Swift, each with the 6 lines after it, and a blind sheet
/// whose `Source:` lines are the only record of the commit and path each came from.
@Suite("judge comment set: cases traced to history, loaded through the dataset loader")
struct JudgeCommentSetTests {
  static let setDirectory = Fixture.gateDirectory.appending(
    path: "Fixtures/judge-comments", directoryHint: .isDirectory)

  static func dataset() throws -> JudgeDataset {
    try JudgeDatasetLoader.directory(setDirectory, id: "comments")
  }

  /// The sheet's key for a case: the labelling tool salts the id so keys say nothing of the split.
  static func sheetKey(_ id: String) -> String {
    SHA256.hash(data: Data("labelling-sheet:\(id)".utf8))
      .map { String(format: "%02x", $0) }.joined().prefix(8).description
  }

  /// Each sheet key's `Source:` line, as (commit, path).
  static func sources() throws -> [String: (commit: String, path: String)] {
    let sheet = try String(
      contentsOf: setDirectory.appending(path: "labelling-sheet.md"), encoding: .utf8)
    var sources: [String: (commit: String, path: String)] = [:]
    var key: String?
    for line in sheet.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("## Case "), let range = line.range(of: " · key ") {
        key = String(line[range.upperBound...])
      } else if line.hasPrefix("Source: "), let key {
        let parts = line.dropFirst("Source: ".count).split(separator: " ")
        if parts.count == 2 { sources[key] = (String(parts[0]), String(parts[1])) }
      }
    }
    return sources
  }

  static func show(_ commit: String, _ path: String) async throws -> ProcessOutput {
    try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "git", arguments: ["show", "\(commit):\(path)"],
        workingDirectory: Fixture.harnessCheckout.path, timeout: .seconds(30)))
  }

  @Test(
    "every case's comment and the 6 lines after it appear in its named commit — catches an edited or made-up comment"
  )
  func casesAppearInTheirCommits() async throws {
    let dataset = try Self.dataset()
    #expect(dataset.questionSet == .builtIn(.comments))
    #expect(dataset.cases.count >= 60 && dataset.cases.count <= 80)
    let sources = try Self.sources()
    #expect(sources.count == dataset.cases.count, "the sheet and the case directories disagree")
    for item in dataset.cases {
      guard let source = sources[Self.sheetKey(item.id)] else {
        Issue.record("\(item.id) has no Source: line on the sheet")
        continue
      }
      let output = try await Self.show(source.commit, source.path)
      guard output.status.isSuccess else {
        Issue.record("\(item.id): git show \(source.commit):\(source.path) failed")
        continue
      }
      let lines = output.stdout.text.split(separator: "\n", omittingEmptySubsequences: false)
      let found = lines.indices.contains { index in
        lines[index].drop(while: \.isWhitespace) == item.source
          && lines[(index + 1)...].prefix(6).joined(separator: "\n") == item.context
      }
      #expect(
        found, "\(item.id): its comment and context aren't in \(source.commit):\(source.path)")
    }
  }

  @Test(
    "every case name is a neutral number — catches a directory name that tells the labeller the answer"
  )
  func caseNamesAreNeutral() throws {
    let names = try Self.dataset().cases.map(\.id)
    #expect(!names.isEmpty)
    for name in names {
      #expect(name.wholeMatch(of: /case-[0-9a-f]{6}/) != nil, "\(name) isn't case-<6 hex digits>")
    }
  }
}
