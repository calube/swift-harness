import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
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
    file("plugin/agents/design-claim-checker.md", "check claims"),
    file("plugin/agents/design-challenger.md", "challenge"),
    file("plugin/workflows/design-review.js", "steps"),
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
      "plugin/agents/design-claim-checker.md", "plugin/agents/design-challenger.md",
      "plugin/workflows/design-review.js",
    ] {
      try repository.write(path, "prompt")
    }
    let before = try DesignCalibrationHash.discover(root: repository.root)
    #expect(
      before.map(\.path) == [
        "plugin/agents/design-challenger.md", "plugin/agents/design-claim-checker.md",
        "plugin/workflows/design-review.js",
      ])
    for path in [
      "plugin/agents/verifier.md", "plugin/agents/design-notes.txt", "plugin/workflows/review.js",
      "plugin/workflows/design-review.mjs", "docs/agents/design-x.md",
      "plugin/agents/nested/design-x.md",
      "agents/design-x.md",
    ] {
      try repository.write(path, "unrelated")
    }
    let after = try DesignCalibrationHash.discover(root: repository.root)
    #expect(DesignCalibrationHash.hash(after) == DesignCalibrationHash.hash(before))
    try repository.write("plugin/workflows/design-review.js", "export const steps = [1];\n")
    let edited = try DesignCalibrationHash.discover(root: repository.root)
    #expect(DesignCalibrationHash.hash(edited) != DesignCalibrationHash.hash(before))
  }

  @Test(
    "a record with an unknown schemaVersion fails to decode — catches a future record format read as a pass"
  )
  func recordRejectsUnknownSchema() throws {
    let record = CalibrationRecord(
      contentHash: "abc", hashedFiles: [], modelOverride: nil,
      passedAt: Date(timeIntervalSince1970: 1_790_000_000),
      cases: [.init(agent: "design-drafter", caseName: "c", model: "opus", answers: [])])
    let encoded = String(decoding: try record.encoded(), as: UTF8.self)
    #expect(try CalibrationRecord.decode(Data(encoded.utf8)) == record)
    let future = encoded.replacingOccurrences(
      of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : 3")
    #expect(future != encoded)
    #expect(throws: (any Error).self) { try CalibrationRecord.decode(Data(future.utf8)) }
  }

  @Test(
    "a judged answer passes only on the label's option at p >= 0.7, an observed one at p = 1 — catches a coin-flip answer recorded as a pass"
  )
  func passMargin() {
    func result(_ answered: String, _ probability: Double) -> CalibrationRecord.QuestionResult {
      .init(question: "q", expected: "a", answered: answered, probability: probability)
    }
    #expect(!result("a", 0.55).met)
    #expect(!result("a", 0.69).met)
    #expect(result("a", 0.7).met)
    #expect(result("a", 1).met)
    #expect(!result("b", 1).met)
  }

  static func label(version: Int = 2, checks: String) -> Data {
    Data("{\"schemaVersion\": \(version), \"checks\": [\(checks)]}".utf8)
  }

  static let good =
    #"{"id": "v", "kind": "value", "array": "verdicts", "where": [{"path": "id", "oneOf": ["x"]}], "field": "status", "expected": "refuted"}"#

  @Test(
    "a label that no agent could meet, that isn't version 2 or that carries an unknown key is rejected — catches a malformed seed silently scored",
    arguments: [
      ("old version", label(version: 1, checks: good)),
      ("no checks", label(checks: "")),
      ("repeated id", label(checks: good + ", " + good)),
      ("unknown kind", label(checks: #"{"id": "v", "kind": "ask", "array": "a"}"#)),
      ("unknown key", label(checks: #"{"id": "v", "kind": "present", "array": "a", "sort": 1}"#)),
      ("no array", label(checks: #"{"id": "v", "kind": "present"}"#)),
      (
        "condition with both tests",
        label(
          checks:
            #"{"id": "v", "kind": "absent", "array": "a", "where": [{"path": "p", "oneOf": ["x"], "prefix": "y"}]}"#
        )
      ),
      (
        "condition with neither test",
        label(checks: #"{"id": "v", "kind": "absent", "array": "a", "where": [{"path": "p"}]}"#)
      ),
      (
        "value without field",
        label(checks: #"{"id": "v", "kind": "value", "array": "a", "expected": "x"}"#)
      ),
      (
        "judge with one option",
        label(
          checks: #"{"id": "v", "kind": "judge", "text": "t", "options": ["a"], "expected": "a"}"#)
      ),
      (
        "judge expecting no option",
        label(
          checks:
            #"{"id": "v", "kind": "judge", "text": "t", "options": ["a", "b"], "expected": "c"}"#)
      ),
      ("not JSON", Data("nope".utf8)),
    ])
  func rejectsBadLabels(_ name: String, _ data: Data) {
    guard case .failure = CalibrationLabel.decode(data) else {
      Issue.record("\(name) decoded")
      return
    }
    guard case .success = CalibrationLabel.decode(Self.label(checks: Self.good)) else {
      Issue.record("the well-formed control label was rejected")
      return
    }
  }

  @Test(
    "a judge question that names its expected option or asks yes or no is rejected — catches a leading question that hands the reader the label",
    arguments: [
      (
        #"{"id": "v", "kind": "judge", "text": "Does the draft tag it UNVERIFIED?", "options": ["UNVERIFIED", "a claim id"], "expected": "UNVERIFIED"}"#,
        "names its expected option"
      ),
      (
        #"{"id": "v", "kind": "judge", "text": "Is there a blocker about the refuted API?", "options": ["Yes", "no"], "expected": "Yes"}"#,
        "asks yes or no"
      ),
    ])
  func rejectsLeadingJudgeQuestions(_ check: String, _ reason: String) {
    guard case .failure(let error) = CalibrationLabel.decode(Self.label(checks: check)) else {
      Issue.record("a leading question decoded")
      return
    }
    #expect(error.message.contains(reason))
    let neutral =
      #"{"id": "v", "kind": "judge", "text": "What tag does the bullet carry?", "options": ["UNVERIFIED", "a claim id"], "expected": "UNVERIFIED"}"#
    guard case .success = CalibrationLabel.decode(Self.label(checks: neutral)) else {
      Issue.record("the neutral control question was rejected")
      return
    }
  }

  @Test(
    "only direct design-* children of the plugin's agents and workflows are hashed — catches a path outside them, such as a root agents/ left from before the move, forcing a recalibration",
    arguments: [
      ("plugin/agents/design-drafter.md", true), ("plugin/workflows/design-review.js", true),
      ("agents/design-drafter.md", false), ("workflows/design-review.js", false),
      ("docs/plugin/agents/design-drafter.md", false), ("plugin/agents/drafter.md", false),
      ("plugin/agents/sub/design-drafter.md", false), ("plugin/workflows/design-review.md", false),
    ])
  func hashedPaths(path: String, hashed: Bool) {
    #expect(DesignCalibrationHash.isHashed(path) == hashed)
  }

  @Test(
    "calibration freshness hashes every plugin/agents/design-*.md and plugin/workflows/design-*.js in this checkout — catches a freshness check that silently hashes nothing after the plugin moved"
  )
  func hashesThePluginsDesignPrompts() throws {
    let checkout = Fixture.harnessCheckout
    func listed(_ directory: String, suffix: String) throws -> [String] {
      try FileManager.default.contentsOfDirectory(
        atPath: checkout.appending(path: directory).path
      ).filter { $0.hasPrefix("design-") && $0.hasSuffix(suffix) }.map { "\(directory)/\($0)" }
    }
    let agents = try listed("plugin/agents", suffix: ".md")
    let workflows = try listed("plugin/workflows", suffix: ".js")

    let hashed = try DesignCalibrationHash.discover(root: checkout).map(\.path)

    #expect(agents.count >= 10)
    #expect(!workflows.isEmpty)
    #expect(hashed == (agents + workflows).sorted())
  }

}
