import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Records each check's request and answers every one with exit 1 at once.
private final class RecordingChecks: QACheckRunning {
  private let seen = Mutex<[QACheckRequest]>([])

  var requests: [QACheckRequest] { seen.withLock { $0 } }

  func run(_ request: QACheckRequest) async -> QACheckOutput {
    seen.withLock { $0.append(request) }
    return QACheckOutput(exit: .exited(1))
  }
}

@Suite("qa run inside a time box")
struct QARunDeadlineCommandTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static func plan(_ repo: QARepo) throws {
    try repo.plan(
      [
        validationRow("req-a", .acceptance, "exit 4", after: ["a-ui"]),
        validationRow("req-b", .acceptance, "exit 5", after: ["b-ui"]),
      ], tasks: ["a-ui": .pending, "b-ui": .pending])
  }

  @Test(
    "past the run's cutoff no row starts: each reads unverified naming the cutoff, and no check runs — catches a qa run started at the cutoff running every row past it"
  )
  func pastTheCutoffRunsNothing() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo)
    let checks = RecordingChecks()

    let report = await repo.run(
      QARunRun.Options(atBase: true), checks: checks,
      deadline: QARunDeadline(at: Self.now.addingTimeInterval(-1), name: "the run's cutoff"))

    #expect(checks.requests.isEmpty)
    #expect(report.rows.map(\.result) == [.unverified, .unverified])
    #expect(report.rows.allSatisfy { $0.message.contains("the run's cutoff") })
  }

  @Test(
    "before the cutoff a command row runs with no more than the time left — catches a check holding the run past the cutoff for its full timeout"
  )
  func commandGetsTheTimeLeft() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try Self.plan(repo)
    let checks = RecordingChecks()

    _ = await repo.run(
      QARunRun.Options(atBase: true), checks: checks,
      deadline: QARunDeadline(at: Self.now.addingTimeInterval(30), name: "the run's cutoff"))

    #expect(checks.requests.map(\.timeout) == [.seconds(30), .seconds(30)])
  }
}
