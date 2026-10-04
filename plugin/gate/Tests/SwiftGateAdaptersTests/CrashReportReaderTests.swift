import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("crash report reader")
struct CrashReportReaderTests {
  static let reportName = "SampleApp-2026-10-04-151000.ips"
  /// The captured run's device and start.
  static let udid = "346175A9-071A-41DA-9D2F-519510A282EA"
  static let startedAt = Date(timeIntervalSince1970: 1_791_144_484)

  let root = TestTemporaryDirectory.root.appending(
    path: "crash-reports-\(UUID().uuidString)", directoryHint: .isDirectory)
  var reports: URL { root.appending(path: "DiagnosticReports", directoryHint: .isDirectory) }
  var simDirectory: URL { root.appending(path: "run/sim", directoryHint: .isDirectory) }

  static func session(udid: String = udid, startedAt: Date = startedAt) -> SimSession {
    SimSession(
      agentDeviceVersion: "0.21.18", udid: udid, deviceType: "iPhone 17",
      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", bundleID: "com.example.SampleApp",
      scenario: nil, headCommit: "0123456789abcdef0123456789abcdef01234567",
      startedAt: startedAt)
  }

  /// The macOS reports folder holding the captured report, and `others` beside it.
  func seed(others: [String: Data] = [:]) throws -> Data {
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    let captured = try Fixture.data("AgentDevice/crash/\(Self.reportName)")
    try captured.write(to: reports.appending(path: Self.reportName))
    for (name, data) in others { try data.write(to: reports.appending(path: name)) }
    return captured
  }

  func copied() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(
      atPath: simDirectory.appending(path: SimCrashReport.directoryName).path)) ?? []).sorted()
  }

  @Test(
    "the captured report of the run's app on its device is copied unmodified into sim/crashes — catches a crash sim verify never sees, or a rewritten report"
  )
  func copiesRunReport() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let captured = try seed()

    let collection = CrashReportReader(directory: reports).collect(
      for: Self.session(), into: simDirectory)

    #expect(collection.copied == [SimCrashReport.path(fileName: Self.reportName)])
    #expect(collection.notes.isEmpty)
    #expect(
      try Data(
        contentsOf: simDirectory.appending(path: SimCrashReport.path(fileName: Self.reportName)))
        == captured)
  }

  @Test(
    "a report from another device, or from before the run started, is not copied, and the same folder still gives the run its own — catches one worktree's run taking another's crash"
  )
  func skipsOtherRuns() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed()
    let reader = CrashReportReader(directory: reports)
    for session in [
      Self.session(udid: "00000000-0000-0000-0000-000000000000"),
      Self.session(startedAt: Self.startedAt.addingTimeInterval(3600)),
    ] {
      let collection = reader.collect(for: session, into: simDirectory)
      #expect(collection.copied.isEmpty)
      #expect(collection.notes.isEmpty)
    }
    #expect(copied().isEmpty)
    #expect(reader.collect(for: Self.session(), into: simDirectory).copied.count == 1)
  }

  @Test(
    "a recent .ips that isn't a crash report is a note naming it, and a missing reports folder is a note — catches a silently skipped report"
  )
  func notesUnreadable() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try seed(others: [
      "Broken-2026-10-04-151001.ips": try Fixture.data(
        "AgentDevice/crash/appstate-not-running.stdout"),
      "notes.txt": Data("not a report".utf8),
    ])

    let collection = CrashReportReader(directory: reports).collect(
      for: Self.session(), into: simDirectory)

    #expect(collection.copied == [SimCrashReport.path(fileName: Self.reportName)])
    try #require(collection.notes.count == 1)
    #expect(collection.notes[0].contains("Broken-2026-10-04-151001.ips"))

    let missing = CrashReportReader(directory: root.appending(path: "nowhere")).collect(
      for: Self.session(), into: simDirectory)
    #expect(missing.copied.isEmpty)
    try #require(missing.notes.count == 1)
    #expect(missing.notes[0].contains("nowhere"))
  }
}
