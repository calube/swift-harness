import Foundation
import SwiftGateAdapters
import Testing

/// The calibration content hash and pass record: what the push check will compare, so their
/// stability is tested apart from any agent run.
@Suite("design calibration hash and record")
struct DesignCalibrationTests {
  struct TempRoot {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(
          path: "swiftgate-calibration-hash-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
  }

  static func file(_ path: String, _ text: String) -> DesignCalibrationHash.File {
    DesignCalibrationHash.File(path: path, contents: Data(text.utf8))
  }

  static let hashedFiles = [
    file("agents/design-claim-checker.md", "check claims"),
    file("agents/design-challenger.md", "challenge"),
    file("workflows/design-review.js", "steps"),
  ]

  @Test(
    "editing any hashed agent or workflow changes the hash — catches a prompt edit shipping on a stale calibration"
  )
  func editChangesHash() {
    let base = DesignCalibrationHash.hash(Self.hashedFiles)
    for index in Self.hashedFiles.indices {
      var edited = Self.hashedFiles
      edited[index] = Self.file(edited[index].path, "edited")
      #expect(DesignCalibrationHash.hash(edited) != base, "\(edited[index].path)")
    }
  }

  @Test(
    "renaming a hashed file changes the hash — catches a rename swapping which agent a prompt belongs to"
  )
  func renameChangesHash() {
    var renamed = Self.hashedFiles
    renamed[0] = Self.file("agents/design-claim-auditor.md", "check claims")
    #expect(DesignCalibrationHash.hash(renamed) != DesignCalibrationHash.hash(Self.hashedFiles))
  }

  @Test(
    "the hash ignores discovery order — catches a file system listing order flipping the push check"
  )
  func orderIndependent() {
    let base = DesignCalibrationHash.hash(Self.hashedFiles)
    let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    for order in permutations {
      #expect(DesignCalibrationHash.hash(order.map { Self.hashedFiles[$0] }) == base)
    }
  }

  @Test(
    "discovery hashes only agents/design-*.md and workflows/design-*.js — catches an unrelated file forcing a recalibration"
  )
  func discoveryMatchesOnlyDesignFiles() throws {
    let repository = try TempRoot()
    for path in [
      "agents/design-claim-checker.md", "agents/design-challenger.md",
      "workflows/design-review.js",
    ] {
      try repository.write(path, "prompt")
    }
    let before = try DesignCalibrationHash.discover(root: repository.root)
    #expect(
      before.map(\.path) == [
        "agents/design-challenger.md", "agents/design-claim-checker.md",
        "workflows/design-review.js",
      ])
    for path in [
      "agents/verifier.md", "agents/design-notes.txt", "workflows/review.js",
      "workflows/design-review.mjs", "docs/agents/design-x.md", "agents/nested/design-x.md",
    ] {
      try repository.write(path, "unrelated")
    }
    let after = try DesignCalibrationHash.discover(root: repository.root)
    #expect(DesignCalibrationHash.hash(after) == DesignCalibrationHash.hash(before))
    try repository.write("workflows/design-review.js", "export const steps = [1];\n")
    let edited = try DesignCalibrationHash.discover(root: repository.root)
    #expect(DesignCalibrationHash.hash(edited) != DesignCalibrationHash.hash(before))
  }

  @Test(
    "a record with an unknown schemaVersion fails to decode — catches a future record format read as a pass"
  )
  func recordRejectsUnknownSchema() throws {
    let record = CalibrationRecord(
      contentHash: "abc", hashedFiles: [], model: "sonnet",
      passedAt: Date(timeIntervalSince1970: 1_790_000_000), cases: [])
    let encoded = String(decoding: try record.encoded(), as: UTF8.self)
    #expect(try CalibrationRecord.decode(Data(encoded.utf8)) == record)
    let future = encoded.replacingOccurrences(
      of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
    #expect(future != encoded)
    #expect(throws: (any Error).self) { try CalibrationRecord.decode(Data(future.utf8)) }
  }

  static func label(version: Int = 1, questions: String) -> Data {
    Data("{\"schemaVersion\": \(version), \"questions\": [\(questions)]}".utf8)
  }

  static let good = #"{"id": "v", "text": "t", "options": ["a", "b"], "expected": "a"}"#

  @Test(
    "a label that no agent could meet or that isn't version 1 is rejected — catches a malformed seed silently scored",
    arguments: [
      ("unknown version", label(version: 2, questions: good)),
      ("no questions", label(questions: "")),
      ("repeated id", label(questions: good + ", " + good)),
      (
        "one option",
        label(questions: #"{"id": "v", "text": "t", "options": ["a"], "expected": "a"}"#)
      ),
      (
        "duplicate options",
        label(questions: #"{"id": "v", "text": "t", "options": ["a", "a"], "expected": "a"}"#)
      ),
      (
        "expected not an option",
        label(questions: #"{"id": "v", "text": "t", "options": ["a", "b"], "expected": "c"}"#)
      ),
      ("not JSON", Data("nope".utf8)),
    ])
  func rejectsBadLabels(_ name: String, _ data: Data) {
    guard case .failure = CalibrationLabel.decode(data) else {
      Issue.record("\(name) decoded")
      return
    }
    guard case .success = CalibrationLabel.decode(Self.label(questions: Self.good)) else {
      Issue.record("the well-formed control label was rejected")
      return
    }
  }
}
