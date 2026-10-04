import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// Answers each request by its working directory and records every request.
private final class ScriptedAreaRunner: AreaCommandRunning {
  private let answer: @Sendable (AreaCommandRequest) -> AreaCommandOutcome
  private let recorded = Mutex<[AreaCommandRequest]>([])

  init(_ answer: @escaping @Sendable (AreaCommandRequest) -> AreaCommandOutcome) {
    self.answer = answer
  }

  var requests: [AreaCommandRequest] { recorded.withLock { $0 } }

  func run(_ request: AreaCommandRequest) async -> AreaCommandOutcome {
    recorded.withLock { $0.append(request) }
    return answer(request)
  }
}

@Suite("brownfield baseline store")
struct BaselineStoreTests {
  struct Clone {
    let root: URL
    let layout: BrownfieldStateLayout
    let scratchTree: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: "baseline-store-\(UUID().uuidString)", directoryHint: .isDirectory)
      layout = BrownfieldStateLayout(
        commonDir: root.appending(path: "repo/.git", directoryHint: .isDirectory),
        gitDir: root.appending(path: "repo/.git/worktrees/w", directoryHint: .isDirectory))
      scratchTree = root.appending(path: "scratch-tree", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: scratchTree, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  static let base = BaselineBase(commit: "1111111", tree: "aaaa")
  static let key = BaselineStepKey(area: "api", step: .test, command: "pytest")
  static let junit = Data(
    """
    <testsuites><testsuite><testcase classname="t" name="known"><failure message="x"/></testcase>\
    <testcase classname="t" name="new"><failure message="y"/></testcase></testsuite></testsuites>
    """.utf8)
  static let knownOnly = Data(
    """
    <testsuites><testsuite><testcase classname="t" name="known"><failure message="x"/></testcase>\
    </testsuite></testsuites>
    """.utf8)

  static func query(_ key: BaselineStepKey = key, head: AreaCommandOutcome) -> BaselineQuery {
    BaselineQuery(key: key, head: head) { scratch in
      AreaCommandRequest(
        area: key.area, step: key.step, command: key.command,
        workingDirectory: scratch.appending(path: key.area).path, deadline: .seconds(60),
        environment: [:], junitPath: nil)
    }
  }

  @Test(
    "a failure the merge base shares is absorbed, a head-only one stays, and the rerun is recorded once — catches a baseline that hides new failures"
  )
  func rerunsAtTheMergeBaseAndRecords() async throws {
    let clone = try Clone()
    defer { clone.remove() }
    let scratch = FakeScratchWorktrees(root: clone.scratchTree)
    let runner = ScriptedAreaRunner { _ in .failed(exit: 1, tail: "", junit: Self.knownOnly) }
    let store = BaselineStore(layout: clone.layout, runner: runner, scratch: scratch)
    let head = Self.query(head: .failed(exit: 1, tail: "", junit: Self.junit))

    let first = await store.lookupOrRerun([head], base: Self.base)
    let second = await store.lookupOrRerun([head], base: Self.base)

    #expect(first.verdict.absorbed == [BaselineFailure(key: Self.key, test: "t.known")])
    #expect(first.verdict.remaining == [BaselineFailure(key: Self.key, test: "t.new")])
    #expect(first.verdict.baselineCount == 1)
    #expect(first.reran == [Self.key])
    #expect(scratch.requests.map(\.revision) == [Self.base.commit])
    #expect(
      runner.requests.map(\.workingDirectory) == [clone.scratchTree.appending(path: "api").path])
    #expect(second.verdict == first.verdict)
    #expect(second.reran.isEmpty && runner.requests.count == 1)
    #expect(first.notes.map(\.ruleID) == [BrownfieldRuleID.baselineSummary.rawValue])
    #expect(first.notes.allSatisfy { $0.severity == .nit })
    #expect(store.load(tree: Self.base.tree).results == [Self.key: .failedTests(["t.known"])])
  }

  @Test(
    "a step that passes at the merge base leaves the head failure gating, and a passing head step reruns nothing — catches a rerun answer ignored"
  )
  func headOnlyFailureStays() async throws {
    let clone = try Clone()
    defer { clone.remove() }
    let runner = ScriptedAreaRunner { _ in .passed }
    let store = BaselineStore(
      layout: clone.layout, runner: runner, scratch: FakeScratchWorktrees(root: clone.scratchTree))
    let lint = BaselineStepKey(
      area: "web", step: .lint, command: "eslint {files}", selection: ["a.ts"])

    let lookup = await store.lookupOrRerun(
      [Self.query(head: .crashed(signal: 6, tail: "")), Self.query(lint, head: .passed)],
      base: Self.base)

    #expect(lookup.verdict.remaining == [BaselineFailure(key: Self.key, test: nil)])
    #expect(lookup.verdict.absorbed.isEmpty && lookup.notes.isEmpty)
    #expect(runner.requests.map(\.area) == ["api"])
  }

  @Test(
    "8 concurrent writers each record 1 answer and the file holds all 8 — catches a write outside the lock"
  )
  func concurrentWritersAllLand() async throws {
    for _ in 0..<5 {
      let clone = try Clone()
      defer { clone.remove() }
      let store = BaselineStore(
        layout: clone.layout, runner: ScriptedAreaRunner { _ in .passed },
        scratch: FakeScratchWorktrees(root: clone.scratchTree))

      try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<8 {
          group.addTask {
            let key = BaselineStepKey(area: "area-\(index)", step: .test, command: "make test")
            try await store.record([BaselineRecord(key: key, result: .failed)], tree: "bbbb")
          }
        }
        try await group.waitForAll()
      }

      let load = store.load(tree: "bbbb")
      #expect(load.records.count == 8)
      #expect(load.notes.isEmpty)
    }
  }

  @Test(
    "a corrupt file is a non-gating note naming it, then a rerun that replaces it — catches a corrupt file read as a silent empty set"
  )
  func corruptFileIsNamedAndRerun() async throws {
    let clone = try Clone()
    defer { clone.remove() }
    let path = clone.layout.baseline(tree: Self.base.tree)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"version\":1,".utf8).write(to: path)
    let runner = ScriptedAreaRunner { _ in .failed(exit: 1, tail: "", junit: nil) }
    let store = BaselineStore(
      layout: clone.layout, runner: runner, scratch: FakeScratchWorktrees(root: clone.scratchTree))

    let lookup = await store.lookupOrRerun(
      [Self.query(head: .failed(exit: 2, tail: "", junit: nil))], base: Self.base)

    let corrupt = try #require(lookup.notes.first { $0.message.contains("decode") })
    #expect(corrupt.file == path.path)
    #expect(lookup.notes.filter { $0.message.contains("decode") }.count == 1)
    #expect(corrupt.severity == .nit)
    #expect(lookup.reran == [Self.key])
    #expect(lookup.verdict.absorbed == [BaselineFailure(key: Self.key, test: nil)])
    let reloaded = store.load(tree: Self.base.tree)
    #expect(reloaded.notes.isEmpty && reloaded.results == [Self.key: .failed])
  }

  @Test(
    "a merge-base tree that can't be made leaves the failure gating, says why and records nothing — catches an unrun base treated as a known failure"
  )
  func scratchFailureKeepsTheFailure() async throws {
    let clone = try Clone()
    defer { clone.remove() }
    let runner = ScriptedAreaRunner { _ in .failed(exit: 1, tail: "", junit: nil) }
    let store = BaselineStore(
      layout: clone.layout, runner: runner,
      scratch: FakeScratchWorktrees(root: clone.scratchTree, failure: .fileSystem("disk full")))

    let lookup = await store.lookupOrRerun(
      [Self.query(head: .failed(exit: 1, tail: "", junit: nil))], base: Self.base)

    #expect(lookup.verdict.remaining == [BaselineFailure(key: Self.key, test: nil)])
    #expect(lookup.verdict.absorbed.isEmpty && runner.requests.isEmpty)
    #expect(lookup.notes.count == 1 && lookup.notes.allSatisfy { $0.message.contains("disk full") })
    #expect(store.load(tree: Self.base.tree).records.isEmpty)
  }
}
