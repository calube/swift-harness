import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Records each check `qa run` asks for and answers with `exit`, so a row's command is read
/// without running a build.
private final class RecordingChecks: QACheckRunning {
  private let requests = Mutex<[QACheckRequest]>([])
  let exit: QACheckExit

  init(exit: QACheckExit = .exited(0)) {
    self.exit = exit
  }

  var recorded: [QACheckRequest] { requests.withLock { $0 } }

  func run(_ request: QACheckRequest) async -> QACheckOutput {
    requests.withLock { $0.append(request) }
    return QACheckOutput(exit: exit, stdout: "** TEST SUCCEEDED **\n")
  }
}

@Suite("qa run test references")
struct QARunTestReferenceTests {
  static let id = "AidokuTests/LargeDownloadConfirmationTests"

  /// The Aidoku trial's acceptance row, in the test form.
  static let row = validationRow(
    "req-check", .acceptance, "test: \(id)", after: ["download-check"])

  @Test(
    "in the Aidoku clone a `test:` acceptance row runs the xcode area's configured test command with -only-testing: the id, from the area root, and saves the command — catches the trial's row that /bin/sh ran as a path and read red on exit 126"
  )
  func xcodeAreaRunsOnlyThatTest() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    let config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
    try Data(config.utf8).write(to: repo.root.appending(path: ".git/swift-harness/config.toml"))
    try repo.plan([Self.row], tasks: ["download-check": .done])
    let checks = RecordingChecks()

    let report = await repo.run(
      QARunRun.Options(), checks: checks, xcresults: FakeXcresultReader(scenario: "one-test"))

    #expect(report.rows.map(\.result) == [.pass], "\(report.rows.map(\.message))")
    let request = try #require(checks.recorded.first)
    #expect(checks.recorded.count == 1)
    let configured = try #require(
      config.split(separator: "\n").first { $0.hasPrefix("test = ") }
        .map { String($0.dropFirst("test = \"".count).dropLast()) })
    // A brownfield checkout keeps its runs under the git common dir.
    let bundle = repo.root.appending(
      path:
        ".git/swift-harness/runs/\(try #require(report.runID))/qa/01-req-check.acceptance.xcresult"
    ).path
    #expect(
      request.program
        == .command("\(configured) -only-testing:'\(Self.id)' -resultBundlePath '\(bundle)'"),
      "\(request.program)")
    #expect(request.workingDirectory == repo.root.path)
    let evidence = try #require(report.rows.first?.evidence.first)
    let saved = try String(
      contentsOf: try RunStore(worktreeRoot: repo.root)
        .runDirectory(for: try #require(report.runID)).appending(path: evidence),
      encoding: .utf8)
    #expect(saved.contains("-only-testing:'\(Self.id)'"), "\(saved)")
    #expect(saved.contains("TEST SUCCEEDED"))
  }

  @Test(
    "a `test:` row with no brownfield area to resolve it reads unverified and runs nothing — catches `test: …` handed to /bin/sh, whose `test` builtin can exit 0 and pass the row"
  )
  func noAreaIsUnverified() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan([Self.row], tasks: ["download-check": .done])
    let checks = RecordingChecks()

    let report = await repo.run(QARunRun.Options(), checks: checks)

    #expect(report.rows.map(\.result) == [.unverified])
    #expect(report.rows.first?.message.contains("area") == true, "\(report.rows)")
    #expect(checks.recorded.isEmpty)
  }
}
