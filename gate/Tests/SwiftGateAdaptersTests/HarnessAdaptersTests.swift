import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("xcodebuild and harness files")
struct HarnessAdaptersTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-files-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test(
    "xcodebuild runs through xcrun with the request's argv, environment and directory, and its output lands in the log — catches recording env dropped on the way to the runner"
  )
  func liveXcodebuild() async throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(65), stdout: "** TEST FAILED **", stderr: "warning")
    }
    let request = XcodebuildTestRequest(
      container: .package(directory: "/w/P"), scheme: "P-Package", destinationUDID: "U",
      derivedDataPath: "/d", resultBundlePath: "/r")
    let log = directory.appending(path: "p.log").path

    let run = try await LiveXcodebuild(runner: runner).test(request, logPath: log)

    let invocation = try #require(runner.invocations.first)
    #expect(invocation.executable == "/usr/bin/xcrun")
    #expect(invocation.arguments == ["xcodebuild"] + request.arguments)
    #expect(invocation.environmentOverlay["TEST_RUNNER_SNAPSHOT_TESTING_RECORD"] == "never")
    #expect(invocation.workingDirectory == "/w/P")
    #expect(run.status == .exited(65))
    #expect(try String(contentsOfFile: log, encoding: .utf8).contains("** TEST FAILED **"))
  }

  @Test(
    "the shim is current only when it resolves to this harness's bin/swiftgate — catches hooks silently running another checkout's gate"
  )
  func shim() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = directory.appending(path: "harness").path
    let other = directory.appending(path: "other").path
    for root in [harness, other] {
      try FileManager.default.createDirectory(
        atPath: "\(root)/bin", withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: "\(root)/bin/swiftgate", contents: Data())
    }
    let link = directory.appending(path: "swiftgate").path

    #expect(HarnessFiles.shimStatus(linkPath: link, harnessRoot: harness) == .missing(path: link))
    try FileManager.default.createSymbolicLink(
      atPath: link, withDestinationPath: "\(harness)/bin/swiftgate")
    #expect(HarnessFiles.shimStatus(linkPath: link, harnessRoot: harness) == .current)
    guard case .elsewhere = HarnessFiles.shimStatus(linkPath: link, harnessRoot: other) else {
      Issue.record("a link to another checkout must not count as current")
      return
    }
    try FileManager.default.removeItem(atPath: "\(harness)/bin/swiftgate")
    #expect(
      HarnessFiles.shimStatus(linkPath: link, harnessRoot: harness)
        == .dangling(path: link, target: "\(harness)/bin/swiftgate"))
  }

  @Test(
    "aged entries take the newest child's time and skip history.jsonl — catches gc deleting a DerivedData directory a build is writing into, or the run history"
  )
  func agedEntries() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FileManager.default
    let old = Date(timeIntervalSince1970: 1_000)
    for path in [".harness/derived-data/stale/Logs", ".harness/derived-data/busy/Logs"] {
      try manager.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
    }
    try manager.createDirectory(
      at: root.appending(path: ".harness/runs/r1"), withIntermediateDirectories: true)
    manager.createFile(
      atPath: root.appending(path: ".harness/runs/history.jsonl").path, contents: Data())
    for path in [
      ".harness/derived-data/stale", ".harness/derived-data/stale/Logs",
      ".harness/derived-data/busy",
    ] {
      try manager.setAttributes(
        [.modificationDate: old], ofItemAtPath: root.appending(path: path).path)
    }

    let derived = HarnessFiles.agedEntries(root: root, directory: ".harness/derived-data")
    let runs = HarnessFiles.agedEntries(
      root: root, directory: ".harness/runs", excluding: ["history.jsonl"])

    #expect(
      HarnessGC.expired(derived, now: Date(), maxAgeDays: 7) == [".harness/derived-data/stale"])
    #expect(runs.map(\.path) == [".harness/runs/r1"])
  }

  @Test(
    "snapshot references are read only from __Snapshots__ directories — catches record listing test sources as changed references"
  )
  func references() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FileManager.default
    try manager.createDirectory(
      at: root.appending(path: "T/__Snapshots__/Suite"), withIntermediateDirectories: true)
    manager.createFile(
      atPath: root.appending(path: "T/__Snapshots__/Suite/a.1.png").path, contents: Data([1]))
    manager.createFile(atPath: root.appending(path: "T/SuiteTests.swift").path, contents: Data([2]))

    #expect(
      HarnessFiles.snapshotReferences(root: root, directories: ["T"])
        == ["T/__Snapshots__/Suite/a.1.png": Data([1])])
  }
}
