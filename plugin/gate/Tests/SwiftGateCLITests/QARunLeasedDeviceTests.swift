import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Answers each `xcodebuild test` in turn with 1 captured run: `busy` replays the run the shared
/// simulator refused to launch the test runner for (exit 65, its saved output), `one-test` a run
/// that passed 1 test. The last scenario answers every later call.
private final class ReplayedRuns: QACheckRunning, XcresultReader {
  private let requests = Mutex<[QACheckRequest]>([])
  private let reads = Mutex(0)
  let scenarios: [String]

  init(_ scenarios: [String]) {
    self.scenarios = scenarios
  }

  var recorded: [QACheckRequest] { requests.withLock { $0 } }

  private func scenario(_ index: Int) -> String { scenarios[min(index, scenarios.count - 1)] }

  func run(_ request: QACheckRequest) async -> QACheckOutput {
    let index = requests.withLock {
      $0.append(request)
      return $0.count - 1
    }
    do {
      guard scenario(index) == "busy" else {
        let status = try Fixture.text("Xcresult/\(scenario(index)).status")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return QACheckOutput(exit: .exited(Int32(status) ?? -1))
      }
      let text = try Fixture.text("QA/runner-launch/busy-1.tail.txt")
      let split = try #require(text.range(of: "--- stderr ---\n"))
      return QACheckOutput(
        exit: .exited(65), stdout: String(text[..<split.lowerBound]),
        stderr: String(text[split.upperBound...]))
    } catch {
      return QACheckOutput(exit: .launchFailed("replaying \(scenario(index)): \(error)"))
    }
  }

  func read(bundlePath: String) async throws(XcresultReadError) -> XcresultContents {
    let index = reads.withLock {
      $0 += 1
      return $0 - 1
    }
    let name = scenario(index) == "busy" ? "runner-busy" : scenario(index)
    return try await FakeXcresultReader(scenario: name).read(bundlePath: bundlePath)
  }

  func readBuildResults(bundlePath: String) async throws(XcresultReadError) -> Data {
    throw .failed(status: .exited(64), stderr: "not read by qa run")
  }

  func activities(bundlePath: String, testID: String) async throws(XcresultReadError) -> Data {
    throw .failed(status: .exited(64), stderr: "not read by qa run")
  }

  func exportAttachments(bundlePath: String, testID: String, to directory: String)
    async throws(XcresultReadError) -> Data
  {
    throw .failed(status: .exited(64), stderr: "not read by qa run")
  }
}

@Suite("qa run runs a test: row's xcodebuild once, on a leased clone")
struct QARunLeasedDeviceTests {
  static let check = "test: \(QARunXcodeTestCountTests.id)"

  static func repo(rows: Int) async throws -> QARepo {
    let repo = try await QARunTestCountTests.featureRepo(
      ["req-board", "req-status", "req-reset"].prefix(rows).map {
        validationRow($0, .acceptance, check, after: ["f"])
      })
    try Data(QARunXcodeTestCountTests.config.utf8)
      .write(to: repo.root.appending(path: ".git/swift-harness/config.toml"))
    return repo
  }

  fileprivate static func run(
    _ repo: QARepo, _ runs: ReplayedRuns, leases: FakeTestDeviceLeases?
  ) async -> QAReport {
    var dependencies = QARunRun.Dependencies(
      checks: runs, ports: LiveQAPorts(),
      scratch: LiveScratchWorktrees(runner: repo.runner, repositoryRoot: repo.root.path),
      events: MemoryEventLog(), now: { Date(timeIntervalSince1970: 1_800_000_000) },
      runIDSuffix: { 0xabc }, newEventID: { UUID().uuidString }, timeout: .seconds(120))
    dependencies.xcresults = runs
    dependencies.testDevices = leases
    return await QARunRun.run(
      root: repo.root, options: QARunRun.Options(),
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path),
      dependencies: dependencies)
  }

  private static func command(_ request: QACheckRequest?) -> String {
    guard case .command(let line)? = request?.program else { return "" }
    return line
  }

  @Test(
    "a `test:` row's xcodebuild runs with `-destination 'id=<clone>'` on 1 leased clone of the named iPhone 17, given back by the run's end — catches a row run on the shared simulator every session launches on"
  )
  func runsOnALeasedClone() async throws {
    let repo = try await Self.repo(rows: 1)
    defer { repo.remove() }
    let runs = ReplayedRuns(["one-test"])
    let leases = FakeTestDeviceLeases()

    let report = await Self.run(repo, runs, leases: leases)

    #expect(report.rows.map(\.result) == [.pass], "\(report.rows.map(\.message))")
    #expect(leases.destinations == [XcodeTestDestination(device: "iPhone 17", os: nil)])
    #expect((leases.entered, leases.left) == (1, 1))
    let line = Self.command(runs.recorded.first)
    #expect(line.contains("-destination 'id=\(FakeDevices.device.udid)'"), "\(line)")
    #expect(!line.contains("name=iPhone 17"), "\(line)")
  }

  @Test(
    "with no clone to be had, the row runs its command as written and says so — catches a row left unrun because the machine's simulator slots were full"
  )
  func leaseFailureRunsAsWritten() async throws {
    let repo = try await Self.repo(rows: 1)
    defer { repo.remove() }
    let runs = ReplayedRuns(["one-test"])

    let report = await Self.run(
      repo, runs, leases: FakeTestDeviceLeases(failure: TestDeviceLeaseError(reason: "no slot")))

    #expect(report.rows.map(\.result) == [.pass])
    #expect(Self.command(runs.recorded.first).contains("name=iPhone 17"))
    #expect(report.rows.first?.message.contains("no slot") == true, "\(report.rows.map(\.message))")
  }

  @Test(
    "3 rows naming 1 `test:` check run its xcodebuild once and all 3 pass, each linking the run's output and bundle — catches 1 UI test class run once per row"
  )
  func sharedCheckRunsOnce() async throws {
    let repo = try await Self.repo(rows: 3)
    defer { repo.remove() }
    let runs = ReplayedRuns(["one-test"])

    let report = await Self.run(repo, runs, leases: FakeTestDeviceLeases())

    #expect(runs.recorded.count == 1)
    #expect(report.rows.map(\.result) == [.pass, .pass, .pass], "\(report.rows.map(\.message))")
    for row in report.rows {
      #expect(
        row.evidence
          == [
            "qa/01-req-board.acceptance.txt", "qa/01-req-board.acceptance.xcresult",
            "qa/01-req-board.acceptance.tests.json",
          ],
        "row \(row.row)")
    }
  }

  @Test(
    "the captured busy-simulator run then a passing run reads pass after 1 retry — catches a launch failure the next attempt would have cleared, left as the row's result"
  )
  func launchFailureIsRetriedOnce() async throws {
    let repo = try await Self.repo(rows: 1)
    defer { repo.remove() }
    let runs = ReplayedRuns(["busy", "one-test"])

    let report = await Self.run(repo, runs, leases: FakeTestDeviceLeases())

    #expect(runs.recorded.count == 2)
    #expect(report.rows.map(\.result) == [.pass], "\(report.rows.map(\.message))")
  }

  @Test(
    "the captured busy-simulator run twice reads unverified naming the launch failure, never red, and the run isn't RED — catches the machine's failure reported as the code's"
  )
  func launchFailureTwiceIsUnverified() async throws {
    let repo = try await Self.repo(rows: 1)
    defer { repo.remove() }
    let runs = ReplayedRuns(["busy"])

    let report = await Self.run(repo, runs, leases: FakeTestDeviceLeases())

    #expect(runs.recorded.count == 2)
    #expect(report.rows.map(\.result) == [.unverified], "\(report.rows.map(\.message))")
    #expect(report.rows.first?.message.contains("test runner") == true)
    #expect(report.verdict != .red)
  }
}
