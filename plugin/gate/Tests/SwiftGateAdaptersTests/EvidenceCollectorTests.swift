import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// The logs a final pass saves around 1 flow, answered with the calls
/// `Fixtures/AgentDevice/record/` captured.
@Suite("final pass evidence")
struct EvidenceCollectorTests {
  static let device = QAEvidenceDevice(
    target: AgentDeviceTarget(udid: "LEASED-UDID", session: "swiftgate-run-row1"),
    bundleID: "com.example.SampleApp", since: Date(timeIntervalSince1970: 1_800_000_000))
  static let relative = "qa/logs/01-req-count"

  /// The calls made before the flow ran.
  final class Before: Sendable {
    private let keys = Mutex<[String]>([])
    var value: [String] { keys.withLock { $0 } }
    func set(_ new: [String]) { keys.withLock { $0 = new } }
  }

  static func collect(_ root: URL, runner: FakeProcessRunner, log: Before) async -> (
    outcome: String, collection: QAEvidenceCollection
  ) {
    await EvidenceCollector(agentDevice: LiveAgentDevice(runner: runner), runner: runner).collect(
      on: device, directory: root.appending(path: relative, directoryHint: .isDirectory),
      relativeDirectory: relative
    ) {
      log.set(runner.invocations.map(CapturedFinalPass.key))
      return "flow ran"
    }
  }

  @Test(
    "the app log stream and the trace start before the flow and stop after it, and the app log, the network dump, the trace, the unified log for the app's subsystem and the data container land under qa/logs with run-relative paths — catches a final pass that keeps no logs, or logs that miss the flow"
  )
  func savesEveryKind() async throws {
    let root = try TestTemporaryDirectory.make("final-pass-evidence")
    defer { TestTemporaryDirectory.remove(root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let runner = try CapturedFinalPass.runner(batch: "record/recorded-pass", home: home)
    let before = Before()

    let (outcome, collection) = await Self.collect(root, runner: runner, log: before)

    #expect(outcome == "flow ran")
    #expect(before.value == ["logs start", "trace start"])
    #expect(collection.gaps.isEmpty, "\(collection.gaps)")
    #expect(
      collection.files
        == [
          EvidenceCollector.appLogFileName, EvidenceCollector.networkFileName,
          EvidenceCollector.traceFileName, EvidenceCollector.osLogFileName,
          EvidenceCollector.containerDirectory,
        ].map { "\(Self.relative)/\($0)" })
    let logs = root.appending(path: Self.relative, directoryHint: .isDirectory)
    let appLog = try String(
      contentsOf: logs.appending(path: EvidenceCollector.appLogFileName), encoding: .utf8)
    #expect(appLog == "app log line\n")
    let dump = try JSONSerialization.jsonObject(
      with: Data(contentsOf: logs.appending(path: EvidenceCollector.networkFileName)))
    #expect(((dump as? [String: Any])?["data"] as? [String: Any])?["entries"] != nil)
    #expect(
      FileManager.default.fileExists(
        atPath: logs.appending(path: EvidenceCollector.traceFileName).path))
    let osLogText = try String(
      contentsOf: logs.appending(path: EvidenceCollector.osLogFileName), encoding: .utf8)
    #expect(osLogText.hasPrefix("Timestamp"))
    #expect(
      FileManager.default.fileExists(
        atPath: logs.appending(path: EvidenceCollector.containerDirectory)
          .appending(path: CapturedFinalPass.containerFile).path))

    let calls = runner.invocations
    #expect(
      calls.map(CapturedFinalPass.key) == [
        "logs start", "trace start", "trace stop", "logs stop", "logs path", "network dump",
        "simctl spawn", "simctl get_app_container",
      ])
    for call in calls where call.executable == LiveAgentDevice.executable {
      #expect(call.arguments.contains("LEASED-UDID") && call.arguments.contains("--session"))
    }
    let osLog = try #require(calls.first { CapturedFinalPass.key(of: $0) == "simctl spawn" })
    #expect(osLog.executable == "xcrun")
    #expect(Array(osLog.arguments.prefix(5)) == ["simctl", "spawn", "LEASED-UDID", "log", "show"])
    #expect(osLog.arguments.contains("subsystem == \"com.example.SampleApp\""))
    #expect(osLog.arguments.contains("--start"))
    let container = try #require(
      calls.first { CapturedFinalPass.key(of: $0) == "simctl get_app_container" })
    #expect(
      container.arguments == [
        "simctl", "get_app_container", "LEASED-UDID", "com.example.SampleApp", "data",
      ])
  }

  @Test(
    "a network dump that breaks leaves a network gap naming the call, and every other kind is still saved and the flow's outcome kept — catches a lost log that nobody hears about, or 1 broken call that drops the rest"
  )
  func brokenCallIsAGap() async throws {
    let root = try TestTemporaryDirectory.make("final-pass-evidence")
    defer { TestTemporaryDirectory.remove(root) }
    let runner = try CapturedFinalPass.runner(
      batch: "record/recorded-pass", home: root.appending(path: "home"),
      failing: ["network dump"])

    let (outcome, collection) = await Self.collect(root, runner: runner, log: Before())

    #expect(outcome == "flow ran")
    #expect([QAEvidenceKind](collection.gaps.keys) == [.network])
    #expect(collection.gaps[.network]?.contains("network dump") == true)
    let saved: [String] = collection.files.map { String($0.dropFirst(Self.relative.count + 1)) }
    let expected: [String] = [
      EvidenceCollector.appLogFileName, EvidenceCollector.traceFileName,
      EvidenceCollector.osLogFileName, EvidenceCollector.containerDirectory,
    ]
    #expect(saved == expected)
  }
}
