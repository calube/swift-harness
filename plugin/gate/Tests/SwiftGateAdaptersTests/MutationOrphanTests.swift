import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `swift test` puts its own test-runner helper (`xctest` on this toolchain, `swiftpm-testing-helper`
/// on others) in a process group of its own, so killing only the group `LiveProcessRunner` spawned
/// `swift test` into leaves the helper running: orphaned, reparented to init, spinning forever on
/// an infinite-loop mutant. 12 such orphans survived for hours at ~200% CPU after their mutate runs
/// were killed. Proven here with a real mutant, through the real `LiveMutationToolchain` and
/// `LiveProcessRunner` — no fakes standing in for the process tree.
@Suite("mutate's test timeout takes the whole process tree down")
struct MutationOrphanTests {
  /// The mutant: a busy loop that outlasts any timeout this test sets, but ends on its own after
  /// `hangSeconds` of wall time, so a copy a killed or reverted-runner run leaves behind dies by
  /// itself. Wall time, not a parent check: an orphan reparented to init must still be there when
  /// the test looks, or the test couldn't tell an unfixed runner from a fixed one.
  private static let hangSeconds = 90

  /// How long a descendant the runner has already killed may take to leave the process table.
  /// Well inside `hangSeconds`, so an orphan the runner never signalled is still spinning when it
  /// passes.
  private static let reapDeadline: Duration = .seconds(20)
  private static let hangingSource = """
    import Foundation

    public func answer() -> Int {
      let deadline = Date().addingTimeInterval(\(hangSeconds))
      while Date() < deadline {}
      return 0
    }

    """

  /// A real, minimal package on disk, already carrying the mutant: one test that calls the
  /// looping `answer()`, built and run for real by `LiveMutationToolchain`.
  private struct Package {
    let root: URL
    let uniqueToken: String

    init() throws {
      uniqueToken = "swiftgate-mutation-orphan-\(UUID().uuidString)"
      root = TestTemporaryDirectory.root.appending(
        path: uniqueToken, directoryHint: .isDirectory)
      let hang = root.appending(path: "Hang", directoryHint: .isDirectory)
      let sourceFile = hang.appending(path: "Sources/Hang/Hang.swift")
      try FileManager.default.createDirectory(
        at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: hang.appending(path: "Tests/HangTests"), withIntermediateDirectories: true)
      try Data(
        """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
          name: "Hang",
          targets: [
            .target(name: "Hang"),
            .testTarget(name: "HangTests", dependencies: ["Hang"]),
          ]
        )
        """.utf8
      ).write(to: hang.appending(path: "Package.swift"))
      try Data(MutationOrphanTests.hangingSource.utf8).write(to: sourceFile)
      try Data(
        """
        import XCTest
        import Hang

        final class HangTests: XCTestCase {
          func testValue() { XCTAssertEqual(answer(), 1) }
        }
        """.utf8
      ).write(to: hang.appending(path: "Tests/HangTests/HangTests.swift"))
    }

    func remove() { TestTemporaryDirectory.remove(root) }

    /// Makes a package for `body`, then kills whatever it left running and removes it, whether
    /// `body` throws or not.
    static func with(_ body: (Package) async throws -> Void) async throws {
      let package = try Package()
      let outcome: Result<Void, any Error>
      do {
        outcome = .success(try await body(package))
      } catch {
        outcome = .failure(error)
      }
      await package.killSurvivors()
      package.remove()
      try outcome.get()
    }

    /// Waits until no process anywhere on the machine names this package's one-of-a-kind temp
    /// path — the mark of a real orphan, not just this test's own already-reaped child — and
    /// returns the `ps` line of each one still there once `deadline` has passed. The runner
    /// returns as soon as it has sent SIGKILL, and on a loaded machine the kernel can list a killed
    /// `xctest` as running, reparented to init, for a moment after that (about 0.2 s at load 120),
    /// so a single look races the kill. The wait is on each survivor's own exit, through kqueue.
    /// An orphan nothing signalled spins for `hangSeconds`, long past the deadline, so it still
    /// fails.
    func survivors(reapedWithin deadline: Duration) async throws -> [String] {
      let pids = try await survivors()
      try await OffPool.run { () throws(POSIXError) in
        try Self.awaitExits(of: pids, within: deadline)
      }
      return try await survivorLines().map(String.init)
    }

    /// Blocks on kqueue until every one of `pids` has exited or `deadline` has passed.
    private static func awaitExits(of pids: [pid_t], within deadline: Duration) throws(POSIXError) {
      let queue = kqueue()
      guard queue >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      defer { close(queue) }
      var watched = 0
      for pid in pids {
        var change = kevent(
          ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
          fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        // ESRCH: it exited between the listing and the registration.
        if kevent(queue, &change, 1, nil, 0, nil) == 0 { watched += 1 }
      }
      let clock = ContinuousClock()
      let end = clock.now.advanced(by: deadline)
      while watched > 0 {
        let left = clock.now.duration(to: end)
        guard left > .zero else { break }
        var timeout = timespec(
          tv_sec: Int(left.components.seconds),
          tv_nsec: Int(left.components.attoseconds / 1_000_000_000))
        var event = kevent()
        let received = kevent(queue, nil, 0, &event, 1, &timeout)
        if received > 0 {
          watched -= 1
        } else if received < 0, errno != EINTR {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    }

    /// Every process whose command line names this package's temp path, by pid.
    func survivors() async throws -> [pid_t] {
      try await survivorLines().compactMap {
        pid_t($0.split(separator: " ", maxSplits: 1).first ?? "")
      }
    }

    /// The `pid ppid pgid state command` line of every process whose command line names this
    /// package's temp path.
    private func survivorLines() async throws -> [Substring] {
      let output = try await LiveProcessRunner().run(
        ProcessInvocation(
          executable: "/bin/ps", arguments: ["-Ao", "pid=,ppid=,pgid=,stat=,command="],
          timeout: .seconds(60)))
      return output.stdout.text.split(separator: "\n")
        .map { line in line.drop { $0 == " " } }
        .filter { $0.contains(uniqueToken) }
    }

    /// Kills whatever is still running from this package, whether the test passed or failed, so
    /// a run against an unfixed runner doesn't leave its orphan spinning until the deadline.
    func killSurvivors() async {
      for pid in (try? await survivors()) ?? [] { kill(pid, SIGKILL) }
    }
  }

  @Test(
    "a mutant that loops past its timeout is timed out, and no descendant of the test process (xctest, swiftpm-testing-helper) survives it — catches an orphan left spinning at ~200% CPU",
    .timeLimit(.minutes(10))
  )
  func timeoutTakesTheProcessTreeDown() async throws {
    try await Package.with { package in
      let toolchain = LiveMutationToolchain(runner: LiveProcessRunner())
      let selection = HostTestSelection(
        packagePath: "Hang",
        targets: [TestTargetReference(name: "HangTests", path: "Hang/Tests/HangTests")])
      func reportPath() -> String {
        package.root.appending(path: "reports/\(UUID().uuidString).xml").path
      }

      let built = await toolchain.buildTests(root: package.root, packageDirectory: "Hang")
      guard case .built = built else {
        Issue.record("expected the mutant to build, got \(built)")
        return
      }

      let (result, _) = await toolchain.test(
        root: package.root, selection: selection, timeout: .seconds(5), reportPath: reportPath())
      guard case .timedOut = result else {
        Issue.record("expected timedOut, got \(result)")
        return
      }

      let survivors = try await package.survivors(reapedWithin: Self.reapDeadline)
      #expect(
        survivors.isEmpty,
        """
        \(survivors.count) descendant(s) of the timed-out test run still running \(Self.reapDeadline) \
        after the runner returned (pid ppid pgid state command):
        \(survivors.joined(separator: "\n"))
        """)
    }
  }
}
