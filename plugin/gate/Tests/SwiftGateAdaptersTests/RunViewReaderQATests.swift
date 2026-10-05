import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Seeds the captured build run's plan state with the captured `qa run` sequence of the same
/// plan, as `qa run` left it in the checkout.
@Suite("run view reader, validation")
struct RunViewReaderQATests {
  typealias Repository = RunViewReaderTests.Repository

  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/qa-checks", directoryHint: .isDirectory)
  static let full = "20261004T185048Z-f46593bf"
  static let qaRuns: Set<String> = [
    "20261004T185047Z-94101f2a", full, "20261004T185049Z-a14503a3",
  ]

  static func lines() throws -> [String] {
    try String(contentsOf: captured.appending(path: "events/qa.jsonl"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  /// A checkout holding the captured qa stream, with each run's `qa/` folder unless `without`
  /// names it.
  static func repository(lines: [String]? = nil, without: Set<String> = []) throws -> Repository {
    let repository = try Repository()
    try repository.write(
      try lines ?? Self.lines(), to: repository.events.appending(path: "qa.jsonl"))
    for id in qaRuns.subtracting(without) {
      let target = repository.checkout.appending(
        path: ".harness/runs/\(id)", directoryHint: .isDirectory)
      try Repository.make(target)
      try FileManager.default.copyItem(
        at: captured.appending(path: "runs/\(id)/qa"), to: target.appending(path: "qa"))
    }
    return repository
  }

  /// `line` with its envelope's `runID` and its payload's `plan`, `result` and `evidence` replaced
  /// where given.
  static func rewritten(
    _ line: String, runID: String? = nil, plan: String? = nil, result: QAResult? = nil,
    evidence: [String]? = nil
  ) throws -> String {
    var object = try #require(
      try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    var payload = try #require(object["payload"] as? [String: Any])
    if let runID { object["runID"] = runID }
    if let plan { payload["plan"] = plan }
    if let result { payload["result"] = result.rawValue }
    if let evidence { payload["evidence"] = evidence }
    object["payload"] = payload
    object["eventID"] = UUID().uuidString
    return String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
  }

  @Test(
    "the plan's qa.check events after the build run's start read with each qa run's report and its red rows' saved output — catches a Validation tab the reader never fills"
  )
  func readsChecksReportsAndOutput() throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    let input = try repository.read()
    let kept = input.events.filter { $0.kind == .qaCheck }
    #expect(kept.count == (try Self.lines()).count)
    #expect(Set(input.qaRuns.keys) == Self.qaRuns)
    #expect(input.qaRuns.values.allSatisfy { $0.report != nil })
    let path = "qa/02-slice-1-reset-after-increments-shows-zero.acceptance.txt"
    let saved = try String(
      contentsOf: Self.captured.appending(path: "runs/\(Self.full)/\(path)"), encoding: .utf8)
    #expect(input.qaRuns[Self.full]?.outputs[path] == saved)
    #expect(
      input.qaRuns[Self.full]?.outputs.keys.sorted() == [path],
      "only a red row's output is read")
    #expect(input.damage.isEmpty, "\(input.damage)")

    let validation = try #require(RunViewBuilder.build(input).validation)
    #expect(
      validation.counts == RunViewValidation.Counts(pass: 1, red: 1, unverified: 2, waiting: 1))
    #expect(validation.rows[1].output.contains("expected 0 after reset, got 1"))
  }

  @Test(
    "a qa.check of another plan, of a qa run older than the build run, or of one after the plan's next build run stays out — catches another plan's or another build run's rows in the tab"
  )
  func keepsOnlyThePlansWindow() throws {
    let lines = try Self.lines()
    let first = try #require(lines.first)
    let extra = [
      try Self.rewritten(first, plan: "another-plan"),
      try Self.rewritten(first, runID: "20261004T040000Z-0000aaaa"),
      try Self.rewritten(first, runID: "20261005T010000Z-0000bbbb"),
    ]
    let repository = try Self.repository(lines: lines + extra)
    defer { repository.remove() }
    let next = repository.planDirectory.appending(
      path: "build/20261005T000000Z-0000cccc", directoryHint: .isDirectory)
    try Repository.make(next)

    let kept = Set(try repository.read().events.filter { $0.kind == .qaCheck }.map(\.eventID))
    #expect(kept == Set(try lines.map(RunViewReaderTests.eventID)))
  }

  @Test(
    "a qa run whose report is missing or doesn't decode, and a red row's evidence path that leaves its run directory, are damage rows, and nothing outside the run directory is read — catches a silent gap or a path escape"
  )
  func missingReportAndEscapingEvidenceAreDamage() throws {
    let lines = try Self.lines()
    let first = try #require(lines.first)
    let escaping = try Self.rewritten(
      first, runID: "20261004T185050Z-0000dddd", result: .red, evidence: ["qa/../../../secret.txt"])
    let repository = try Self.repository(lines: lines + [escaping], without: [Self.full])
    defer { repository.remove() }
    try Data("outside".utf8).write(to: repository.checkout.appending(path: ".harness/secret.txt"))
    let broken = repository.checkout.appending(
      path: ".harness/runs/20261004T185050Z-0000dddd/qa/report.json")
    try Repository.make(broken.deletingLastPathComponent())
    try Data("{\"schemaVersion\":".utf8).write(to: broken)

    let input = try repository.read()
    #expect(input.qaRuns[Self.full]?.report == nil)
    #expect(input.qaRuns["20261004T185050Z-0000dddd"]?.outputs.isEmpty == true)
    let sources = input.damage.map(\.source)
    #expect(sources.contains(".harness/runs/\(Self.full)/qa/report.json"))
    #expect(sources.contains(".harness/runs/20261004T185050Z-0000dddd/qa/report.json"))
    #expect(
      input.damage.contains {
        $0.source == "qa run 20261004T185050Z-0000dddd"
          && $0.reason.contains("qa/../../../secret.txt")
      }, "\(input.damage)")
    #expect(input.damage.allSatisfy { !$0.reason.contains(repository.parent.path) })
  }

  @Test(
    "a qa report written after its events moves the live snapshot — catches a live page left showing a missing report after qa run finished"
  )
  func reportMovesTheSnapshot() throws {
    let repository = try Self.repository(without: [Self.full])
    defer { repository.remove() }
    let reader = RunViewReader(
      commonDirectory: repository.common, stateRoot: .tree(repository.checkout))
    let before = reader.snapshot(buildRun: RunViewReaderTests.buildRun).cursor
    let target = repository.checkout.appending(
      path: ".harness/runs/\(Self.full)", directoryHint: .isDirectory)
    try Repository.make(target)
    try FileManager.default.copyItem(
      at: Self.captured.appending(path: "runs/\(Self.full)/qa"), to: target.appending(path: "qa"))
    #expect(reader.snapshot(buildRun: RunViewReaderTests.buildRun).cursor != before)
  }

  @Test(
    "the plan's validation.json reads into the input as it stands now, and a plan with none reads as nil without damage — catches a Validation tab that can't tell which rows the plan still has"
  )
  func readsThePlansValidationTable() throws {
    let repository = try Self.repository()
    defer { repository.remove() }
    #expect(try repository.read().validation == nil)

    let captured = Fixture.gateDirectory.appending(
      path: "Tests/Fixtures/RunView/price-tracker-4/validation.json")
    try FileManager.default.copyItem(
      at: captured,
      to: repository.planDirectory.appending(path: ValidationTable.fileName))
    let input = try repository.read()
    #expect(input.validation == (try ValidationTableJSON.decode(try Data(contentsOf: captured))))
    #expect(input.validation?.unitOnly.count == 4)
    #expect(input.damage.isEmpty, "\(input.damage)")
  }
}
