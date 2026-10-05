import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Runs each check through the real runner and records which ran.
final class CountingChecks: QACheckRunning {
  private let inner: QACommandRunner
  private let ran = Mutex<[String]>([])

  init(runner: any ProcessRunner) { inner = QACommandRunner(runner: runner) }

  var programs: [String] { ran.withLock { $0 } }

  func run(_ request: QACheckRequest) async -> QACheckOutput {
    let name: String
    switch request.program {
    case .script(let path): name = URL(filePath: path).lastPathComponent
    case .command(let command): name = command
    }
    ran.withLock { $0.append(name) }
    return await inner.run(request)
  }
}

/// The orchestrator's `qa run --at-base` after `qa adopt`, taking the rows a validation worker's
/// `--prepared-by` run already proved instead of running them a second time.
@Suite("qa run --at-base reuses a prepared run")
struct QARunReusesPreparedTests {
  static func prepared(_ repo: QARepo) -> URL {
    repo.root.appending(path: ".harness/qa/\(QARepo.slug)", directoryHint: .isDirectory)
  }

  static func adopt(_ repo: QARepo) async -> QAAdoptReport {
    await QAAdoptRun.run(
      worktree: repo.root.path, root: repo.root,
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path), runner: repo.runner)
  }

  static func checkEvents(_ log: MemoryEventLog) -> [QACheckEvent] {
    log.events.compactMap {
      guard case .qaCheck(let check) = $0.payload else { return nil }
      return check
    }
  }

  @Test(
    "after qa adopt, --at-base takes each row the worker's prepared run proved with a byte-identical check, names that run on the row, its qa.check event and a note, and runs only the rest; an edited check runs again — catches every at-base row run twice"
  )
  func reusesUnchangedRows() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-save", .state, "qa/save.state.sh", after: ["save-ui"]),
        ValidationRow(
          requirement: "req-load", layer: .acceptance, check: "exit 4", runsAfter: ["load-ui"],
          writer: "load-ui"),
        validationRow("req-total", .acceptance, "qa/total.sh", after: ["total-ui"]),
      ], tasks: ["save-ui": .pending, "load-ui": .pending, "total-ui": .pending])
    let prepared = Self.prepared(repo)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("exit 3\n".utf8).write(to: prepared.appending(path: "save.state.sh"))
    try Data("exit 5\n".utf8).write(to: prepared.appending(path: "total.sh"))

    let worker = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation"), suffix: 1)
    let record = try QAAtBaseRunJSON.decode(
      try Data(contentsOf: prepared.appending(path: QAAtBaseRun.fileName)))
    let adopted = await Self.adopt(repo)
    let checks = CountingChecks(runner: repo.runner)
    let events = MemoryEventLog()
    let orchestrator = await repo.run(
      QARunRun.Options(atBase: true), events: events, suffix: 2, checks: checks)

    #expect(worker.rows.map(\.result) == [.red, .red], "\(worker.rows.map(\.message))")
    #expect(record.runID == worker.runID)
    #expect(record.preparedBy == "validation")
    #expect(adopted.verdict == .green, "\(adopted.message)")
    #expect(checks.programs == ["exit 4"], "\(checks.programs)")
    #expect(orchestrator.verdict == .green, "\(orchestrator.message)")
    let rows = Dictionary(uniqueKeysWithValues: orchestrator.rows.map { ($0.row, $0) })
    #expect(rows[1]?.reusedFrom == worker.runID)
    #expect(rows[1]?.exitStatus == 3)
    #expect(rows[3]?.reusedFrom == worker.runID)
    #expect(rows[3]?.result == .red)
    #expect(rows[2]?.reusedFrom == nil)
    #expect(rows[2]?.exitStatus == 4)
    #expect(
      Self.checkEvents(events).filter { $0.reusedFrom == worker.runID }.map(\.row).sorted()
        == [1, 3])
    #expect(
      orchestrator.notes.contains { $0.contains(worker.runID ?? "-") && $0.contains("2 rows") },
      "\(orchestrator.notes)")

    try repo.qaFile("total.sh", "exit 6\n")
    let edited = CountingChecks(runner: repo.runner)
    let again = await repo.run(QARunRun.Options(atBase: true), suffix: 3, checks: edited)

    #expect(edited.programs.sorted() == ["exit 4", "total.sh"], "\(edited.programs)")
    #expect(again.rows.first { $0.row == 3 }?.exitStatus == 6)
    #expect(again.rows.first { $0.row == 1 }?.reusedFrom == worker.runID)
    #expect(
      again.notes.contains { $0.contains("row 3") && $0.contains("changed") }, "\(again.notes)")
  }

  @Test(
    "a prepared run names the absolute path of the at-base-run.json it wrote in its JSON and text output, and a run that writes none names no path — catches a worker searching the disk for its own record"
  )
  func namesItsRecord() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [validationRow("req-total", .acceptance, "qa/total.sh", after: ["total-ui"])],
      tasks: ["total-ui": .pending])
    let prepared = Self.prepared(repo)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("exit 5\n".utf8).write(to: prepared.appending(path: "total.sh"))

    let worker = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation"), suffix: 1)
    let orchestrator = await repo.run(QARunRun.Options(atBase: true), suffix: 2)

    let expected = prepared.appending(path: QAAtBaseRun.fileName).path
    let path = try #require(worker.atBaseRecord, "\(worker.notes)")
    #expect(path == expected)
    #expect(path.hasPrefix("/"))
    #expect(FileManager.default.fileExists(atPath: path))
    let json = try QAReportJSON.decode(Data(QARunRun.render(worker, json: true).utf8))
    #expect(json.atBaseRecord == expected)
    #expect(
      QARunRun.render(worker, json: false).split(separator: "\n").contains(
        "  at-base record: \(expected)"), "\(QARunRun.render(worker, json: false))")
    #expect(orchestrator.atBaseRecord == nil)
    #expect(!QARunRun.render(orchestrator, json: false).contains("at-base record"))
  }

  @Test(
    "a flow and its state row the worker's prepared run drove on a device are reused after qa adopt with no device brought up, and a check passing at base is still a finding — catches the flow rows' device time spent twice"
  )
  func reusesFlowWithoutDevice() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QARunFlowTests.plan(repo)
    let prepared = Self.prepared(repo)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    for name in ["count.flow.json", "count.state.sh"] {
      try FileManager.default.moveItem(
        at: repo.planDirectory.appending(path: "qa/\(name)"), to: prepared.appending(path: name))
    }
    let workerDevice = try await QARunFlowTests.simulator(repo, batch: "pass")
    let worker = await Self.run(repo, workerDevice, preparedBy: "validation", suffix: 1)
    let adopted = await Self.adopt(repo)
    let device = try await QARunFlowTests.simulator(repo, batch: "pass")

    let report = await Self.run(repo, device, preparedBy: nil, suffix: 2)

    #expect(worker.rows.map(\.result) == [.pass, .pass], "\(worker.rows.map(\.message))")
    #expect(adopted.verdict == .green, "\(adopted.message)")
    #expect(device.calls.isEmpty, "\(device.calls)")
    #expect(report.rows.map(\.reusedFrom) == [worker.runID, worker.runID], "\(report.rows)")
    #expect(
      report.findings.map(\.ruleID)
        == [QAReport.checkPassesAtBaseRuleID, QAReport.checkPassesAtBaseRuleID])
  }

  static func run(
    _ repo: QARepo, _ simulator: FakeFlowSimulator, preparedBy: String?, suffix: UInt32
  ) async -> QAReport {
    await QARunRun.run(
      root: repo.root, options: QARunRun.Options(atBase: true, preparedBy: preparedBy),
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path),
      dependencies: QARunRun.Dependencies(
        checks: QACommandRunner(runner: repo.runner), ports: LiveQAPorts(),
        scratch: LiveScratchWorktrees(runner: repo.runner, repositoryRoot: repo.root.path),
        events: MemoryEventLog(), now: { Date(timeIntervalSince1970: 1_800_000_000) },
        runIDSuffix: { suffix }, newEventID: { UUID().uuidString }, timeout: .seconds(120),
        flows: simulator, pluginRoot: Fixture.checkoutRoot))
  }
}
