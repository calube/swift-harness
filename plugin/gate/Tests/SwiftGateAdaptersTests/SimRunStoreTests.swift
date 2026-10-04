import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("SimRunStore")
struct SimRunStoreTests {
  let simDirectory = TestTemporaryDirectory.root.appending(
    path: "sim-run-\(UUID().uuidString)/sim", directoryHint: .isDirectory)

  static func step(_ n: Int) -> SimStep {
    SimStep(
      n: n, label: "step \(n)", assert: nil, screenshot: SimStep.screenshotPath(n: n),
      tree: SimStep.treePath(n: n), settled: true, elapsedMs: 10)
  }

  func staged(_ store: SimRunStore, bytes: Data) throws -> SimStepStaging {
    let staging = try store.stage()
    try bytes.write(to: staging.screenshot)
    return staging
  }

  func entries(_ directory: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(
      atPath: simDirectory.appending(path: directory).path)) ?? []).sorted()
  }

  @Test(
    "two commits number 001 and 002, keep the tree bytes unmodified, move the screenshot into place and append both lines — catches rewritten evidence or a reused step number"
  )
  func twoCommits() throws {
    defer { try? FileManager.default.removeItem(at: simDirectory.deletingLastPathComponent()) }
    let store = SimRunStore(simDirectory: simDirectory)
    let tree = try Fixture.data("AgentDevice/snapshot.stdout")

    let first = try store.commit(
      try staged(store, bytes: Data("one".utf8)), treeJSON: tree, makeStep: Self.step)
    let second = try store.commit(
      try staged(store, bytes: Data("two".utf8)), treeJSON: tree, makeStep: Self.step)

    #expect(first.n == 1 && second.n == 2)
    #expect(entries("steps") == ["001.png", "001.tree.json", "002.png", "002.tree.json"])
    #expect(try Data(contentsOf: simDirectory.appending(path: "steps/001.tree.json")) == tree)
    #expect(try Data(contentsOf: simDirectory.appending(path: "steps/002.png")) == Data("two".utf8))
    #expect(try store.steps() == [Self.step(1), Self.step(2)])
  }

  @Test(
    "8 concurrent commits take 8 distinct numbers with no line lost — catches two snaps racing to one step number"
  )
  func concurrentCommits() async throws {
    defer { try? FileManager.default.removeItem(at: simDirectory.deletingLastPathComponent()) }
    let store = SimRunStore(simDirectory: simDirectory)
    let tree = try Fixture.data("AgentDevice/snapshot.stdout")
    let stagings = try (0..<8).map { try staged(store, bytes: Data("png \($0)".utf8)) }

    let numbers = try await withThrowingTaskGroup(of: Int.self) { group in
      for staging in stagings {
        group.addTask {
          try store.commit(staging, treeJSON: tree, makeStep: Self.step).n
        }
      }
      return try await group.reduce(into: [Int]()) { $0.append($1) }
    }

    #expect(numbers.sorted() == Array(1...8))
    #expect(try store.steps().map(\.n) == Array(1...8))
    #expect(entries("steps").count == 16)
  }

  @Test(
    "a commit onto a step log that doesn't decode throws naming the log and leaves no step file behind — catches a step appended after corrupt evidence"
  )
  func corruptLog() throws {
    defer { try? FileManager.default.removeItem(at: simDirectory.deletingLastPathComponent()) }
    let store = SimRunStore(simDirectory: simDirectory)
    try FileManager.default.createDirectory(at: simDirectory, withIntermediateDirectories: true)
    try Data("{\"n\":\n".utf8).write(to: store.stepLog)
    let staging = try staged(store, bytes: Data("png".utf8))

    #expect {
      try store.commit(
        staging, treeJSON: try Fixture.data("AgentDevice/snapshot.stdout"), makeStep: Self.step)
    } throws: { error in
      guard case .unreadableSteps(let path, _) = error as? SimRunStoreError else { return false }
      return path == store.stepLog.path
    }
    store.discard(staging)
    #expect(entries("steps").isEmpty)
    #expect(try Data(contentsOf: store.stepLog) == Data("{\"n\":\n".utf8))
  }

  @Test(
    "the session reads back what sim up wrote, and a missing one names its path — catches a snap on a run sim up never finished"
  )
  func session() throws {
    defer { try? FileManager.default.removeItem(at: simDirectory.deletingLastPathComponent()) }
    let store = SimRunStore(simDirectory: simDirectory)
    #expect {
      try store.session()
    } throws: { error in
      (error as? SimRunStoreError)?.message.contains(SimSession.fileName) == true
    }
    let session = SimSession(
      agentDeviceVersion: AgentDevicePin.version, udid: "MADE-1", deviceType: "iPhone 17",
      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", bundleID: "com.example.SampleApp",
      scenario: nil, headCommit: "0123456789abcdef0123456789abcdef01234567",
      startedAt: Date(timeIntervalSince1970: 1_791_115_200))
    try FileManager.default.createDirectory(at: simDirectory, withIntermediateDirectories: true)
    try session.encoded().write(to: simDirectory.appending(path: SimSession.fileName))
    #expect(try store.session() == session)
  }
}
