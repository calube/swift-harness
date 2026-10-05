import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// The second tic-tac-toe trial's clone: its plan state, every `qa run`'s report, and the whole
/// evidence of row 1 of its final run, under the clone's common state root.
struct EvidenceClone {
  static let buildRun = "20261005T014044Z-0066dd3b"
  static let plan = "spec"
  static let finalRun = "20261005T020215Z-2bdf5cdb"
  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/tic-tac-toe-2-evidence", directoryHint: .isDirectory)

  let parent: URL
  let root: URL
  let common: URL

  var runs: URL { common.appending(path: "swift-harness/runs", directoryHint: .isDirectory) }
  var folder: URL {
    common.appending(path: "swift-harness/reports/\(Self.buildRun)", directoryHint: .isDirectory)
  }

  init() throws {
    let files = FileManager.default
    parent = TestTemporaryDirectory.root.appending(
      path: "report-evidence-\(UUID().uuidString)", directoryHint: .isDirectory
    ).resolvingSymlinksInPath()
    root = parent.appending(path: "repo", directoryHint: .isDirectory)
    common = root.appending(path: ".git", directoryHint: .isDirectory)
    let harness = common.appending(path: "swift-harness", directoryHint: .isDirectory)
    let planDirectory = harness.appending(path: "plans/\(Self.plan)", directoryHint: .isDirectory)
    let run = planDirectory.appending(path: "build/\(Self.buildRun)", directoryHint: .isDirectory)
    try files.createDirectory(at: run, withIntermediateDirectories: true)
    try Data().write(to: harness.appending(path: "config.toml"))
    let copies: [(String, URL)] = [
      ("ledger.json", planDirectory.appending(path: "ledger.json")),
      ("plan.json", planDirectory.appending(path: "plan.json")),
      ("clock.json", planDirectory.appending(path: "clock.json")),
      ("run.json", run.appending(path: "run.json")),
      ("ledger-events.jsonl", run.appending(path: "events.jsonl")),
      ("returns", run.appending(path: "returns")),
      ("runs", harness.appending(path: "runs")),
      ("events", harness.appending(path: "events")),
    ]
    for (name, target) in copies {
      try files.copyItem(at: Self.captured.appending(path: name), to: target)
    }
  }

  func report() -> ReportRun.Outcome {
    ReportRun.run(
      buildRun: Self.buildRun, format: .html, out: nil, root: root, commonDirectory: common,
      pluginRoot: Fixture.checkoutRoot, now: Date(timeIntervalSince1970: 1_791_000_000))
  }

  func view() throws -> RunView {
    let reader = RunViewReader(
      commonDirectory: common, stateRoot: StateRootResolver.resolve(worktree: root),
      profile: StateRootResolver.profile(worktree: root))
    return RunViewBuilder.build(try reader.read(buildRun: Self.buildRun))
  }

  func remove() { try? FileManager.default.removeItem(at: parent) }
}

@Suite("swiftgate report carries every evidence file its page links")
struct ReportEvidenceTests {
  static func json(_ url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  static func rows(_ view: [String: Any]) throws -> [[String: Any]] {
    try #require((view["validation"] as? [String: Any])?["rows"] as? [[String: Any]])
  }

  @Test(
    "the final report carries every evidence path the captured run's row lists, its logs and app container included, and a damage row names each path it couldn't carry — catches evidence links that break once the report leaves the repository"
  )
  func carriesEveryEvidencePath() throws {
    let clone = try EvidenceClone()
    defer { clone.remove() }

    guard case .wrote = clone.report() else {
      Issue.record("report --html wrote no page")
      return
    }
    let view = try Self.json(clone.folder.appending(path: RunReportFolder.viewName))
    let carried = Set(try #require(view["evidenceFiles"] as? [String]))
    let rows = try Self.rows(view)
    let first = try #require(rows.first { $0["row"] as? Int == 1 })
    let evidence = try #require(first["evidence"] as? [String])
    #expect(evidence.count == 12)
    for path in evidence {
      let relative = "\(EvidenceClone.finalRun)/\(path)"
      #expect(carried.contains(relative), "\(relative)")
      #expect(
        FileManager.default.fileExists(
          atPath: clone.folder.appending(path: RunReportFolder.evidenceBase + relative).path),
        "\(relative)")
    }
    let container = clone.folder.appending(
      path: "runs/\(EvidenceClone.finalRun)/qa/logs/01-req-launch-empty-board/container")
    #expect(ReportWholeTests.files(under: container).contains { $0.hasSuffix(".ktx") })

    let damaged = Set(
      try #require(view["damage"] as? [[String: Any]]).compactMap { $0["source"] as? String })
    let second = try #require(rows.first { $0["row"] as? Int == 2 })
    let left = try #require(second["evidence"] as? [String])
    #expect(!left.isEmpty)
    for path in left {
      let relative = "\(EvidenceClone.finalRun)/\(path)"
      #expect(!carried.contains(relative), "\(relative)")
      #expect(damaged.contains(RunReportFolder.evidenceBase + relative), "\(relative)")
    }
    let earlier = try #require(first["history"] as? [[String: Any]]).filter {
      $0["qaRun"] as? String != EvidenceClone.finalRun
    }.flatMap { attempt in
      ((attempt["evidence"] as? [String]) ?? []).map { "\(attempt["qaRun"] ?? "")/\($0)" }
    }
    #expect(!earlier.isEmpty, "row 1 lists no earlier run's evidence")
    for relative in earlier {
      #expect(damaged.contains(RunReportFolder.evidenceBase + relative), "\(relative)")
    }
    for relative in carried {
      #expect(
        FileManager.default.fileExists(
          atPath: clone.folder.appending(path: RunReportFolder.evidenceBase + relative).path),
        "\(relative)")
    }
  }

  @Test(
    "past the byte budget a report carries the flows' videos and sheets first and leaves the rest behind with a reason — catches a report folder that grows without bound"
  )
  func budgetCarriesFlowFilesFirst() throws {
    let clone = try EvidenceClone()
    defer { clone.remove() }
    let validation = try #require(try clone.view().validation)
    let flow = validation.flowFiles.filter { $0.hasPrefix(EvidenceClone.finalRun + "/qa/01-") }
    #expect(flow.count == 2)
    let budget = try flow.reduce(0) { total, relative in
      total
        + (try #require(
          try clone.runs.appending(path: relative).resourceValues(forKeys: [.fileSizeKey])
            .fileSize))
    }

    let carriage = RunReportFolder.carriage(
      validation.linkedFiles, first: validation.flowFiles, under: [clone.runs], budget: budget)

    #expect(flow.isSubset(of: Set(carriage.carried)))
    let batch = "\(EvidenceClone.finalRun)/qa/01-req-launch-empty-board.flow/batch.json"
    #expect(!carriage.carried.contains(batch))
    let reason = try #require(carriage.left.first { $0.relative == batch }?.reason)
    #expect(reason.contains("budget"), "\(reason)")
  }

  @Test(
    "a result bundle is never copied: its test summary stands in for it when the row lists one, and a damage reason names it when not — catches a report copying whole xcresult bundles"
  )
  func resultBundleLeftForItsSummary() throws {
    let runs = TestTemporaryDirectory.root.appending(
      path: "report-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: runs) }
    let qa = runs.appending(path: "run/qa", directoryHint: .isDirectory)
    for name in ["01-req.acceptance.xcresult", "02-req.acceptance.xcresult"] {
      let bundle = qa.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
      try Data("bundle".utf8).write(to: bundle.appending(path: "Info.plist"))
    }
    try Data("{}".utf8).write(to: qa.appending(path: "01-req.acceptance.tests.json"))
    let linked: Set<String> = [
      "run/qa/01-req.acceptance.xcresult", "run/qa/01-req.acceptance.tests.json",
      "run/qa/02-req.acceptance.xcresult",
    ]

    let carriage = RunReportFolder.carriage(linked, first: [], under: [runs])

    #expect(carriage.carried == ["run/qa/01-req.acceptance.tests.json"])
    #expect(
      carriage.left.first { $0.relative == "run/qa/01-req.acceptance.xcresult" }
        == .init(relative: "run/qa/01-req.acceptance.xcresult", reason: nil))
    let reason = try #require(
      carriage.left.first { $0.relative == "run/qa/02-req.acceptance.xcresult" }?.reason)
    #expect(reason.contains("result bundle"), "\(reason)")
  }
}

@Suite("swiftgate report and the files a qa run never wrote")
struct ReportUnwrittenEvidenceTests {
  static let run = "20261005T042614Z-10957c21"
  static let runs = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/send-money-3-at-base/runs", directoryHint: .isDirectory)

  /// Every evidence path the captured at-base run's rows list, as the report links them.
  static func linked() throws -> Set<String> {
    let report = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: runs.appending(path: "\(run)/qa/report.json"))) as? [String: Any])
    let rows = try #require(report["rows"] as? [[String: Any]])
    return Set(rows.flatMap { ($0["evidence"] as? [String]) ?? [] }.map { "\(run)/\($0)" })
  }

  @Test(
    "the send-money-3 at-base run, whose 10 flow rows stopped before any snap so their sim/steps.ndjson was never written, carries every file its rows left and names no damage, while a row whose run folder is gone is still damage — catches the trial's report listing 10 damage rows for files that never existed"
  )
  func neverWrittenIsNoDamage() throws {
    let linked = try Self.linked()
    #expect(linked.count == 50)

    let carriage = RunReportFolder.carriage(linked, first: [], under: [Self.runs])

    let damaged = carriage.left.filter { $0.reason != nil }
    #expect(damaged.isEmpty, "\(damaged.map(\.relative))")
    #expect(carriage.carried.count == 40)
    #expect(carriage.carried.allSatisfy { !$0.hasSuffix("/sim/steps.ndjson") })

    let gone = "20261005T042614Z-00000000/qa/01-req-account-fake.flow/sim/report.json"
    let lost = RunReportFolder.carriage([gone], first: [], under: [Self.runs])
    #expect(lost.left.first?.reason != nil, "\(lost.left)")
  }
}
