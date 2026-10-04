import Foundation
import SwiftGateAdapters
import Synchronization

/// A scripted ``MutationToolchain``. Handlers see the scratch root, so they can read the file a
/// mutant was written to; every call is recorded. Each handler runs on a thread of its own, as the
/// live toolchain's processes do, so a handler may block to hold workers in step.
public final class FakeMutationToolchain: MutationToolchain {
  public struct TestCall: Sendable, Equatable {
    public let root: URL
    public let selection: HostTestSelection
    public let timeout: Duration
  }

  public typealias Build = @Sendable (_ root: URL, _ packageDirectory: String) -> MutantBuildResult
  public typealias Test =
    @Sendable (_ root: URL, _ selection: HostTestSelection) -> (MutantTestResult, Duration)

  private let buildHandler: Build
  private let testHandler: Test
  private let recordedBuilds = Mutex<[URL]>([])
  private let recordedTests = Mutex<[TestCall]>([])

  public init(
    build: @escaping Build = { _, _ in .built },
    test: @escaping Test = { _, _ in (.passed(executed: 1), .seconds(1)) }
  ) {
    buildHandler = build
    testHandler = test
  }

  /// Scratch roots of every build, in call order.
  public var builds: [URL] { recordedBuilds.withLock { $0 } }
  public var tests: [TestCall] { recordedTests.withLock { $0 } }
  /// Scripted handlers already stand in for the whole build, so a compile width changes nothing.
  public func sharing(jobs: Int) -> any MutationToolchain { self }

  public func buildTests(root: URL, packageDirectory: String) async -> MutantBuildResult {
    recordedBuilds.withLock { $0.append(root) }
    let handler = buildHandler
    return await OffPool.run { handler(root, packageDirectory) }
  }

  public func test(
    root: URL, selection: HostTestSelection, timeout: Duration, reportPath: String
  ) async -> (result: MutantTestResult, elapsed: Duration) {
    recordedTests.withLock {
      $0.append(TestCall(root: root, selection: selection, timeout: timeout))
    }
    let handler = testHandler
    let (result, elapsed) = await OffPool.run { handler(root, selection) }
    return (result, elapsed)
  }
}

/// A ``ScratchWorktrees`` that gives every call its own copy of `seed` under a fresh directory,
/// as the live adapter gives every worker its own worktree, and removes it afterwards.
public final class CopyingScratchWorktrees: ScratchWorktrees {
  private let seed: URL
  private let failure: ScratchWorktreeError?
  private let made = Mutex<[URL]>([])
  private let recorded = Mutex<[ScratchTreeRequest]>([])

  public init(seed: URL, failure: ScratchWorktreeError? = nil) {
    self.seed = seed
    self.failure = failure
  }

  /// Every tree handed out, in call order.
  public var trees: [URL] { made.withLock { $0 } }

  /// Every request, in call order.
  public var requests: [ScratchTreeRequest] { recorded.withLock { $0 } }

  public func withScratchTree<T: Sendable>(
    _ request: ScratchTreeRequest, _ body: (URL) async -> T
  ) async throws(ScratchWorktreeError) -> T {
    recorded.withLock { $0.append(request) }
    if let failure { throw failure }
    let token = UUID().uuidString  // swiftgate:allow det.uuid-init — unique directory
    let name = "swiftgate-fake-scratch-\(token)"
    let tree = TestTemporaryDirectory.root.appending(
      path: name, directoryHint: .isDirectory)
    do {
      try FileManager.default.copyItem(at: seed, to: tree)
    } catch {
      throw .fileSystem("\(error)")
    }
    made.withLock { $0.append(tree) }
    let result = await body(tree)
    TestTemporaryDirectory.remove(tree)
    return result
  }
}
