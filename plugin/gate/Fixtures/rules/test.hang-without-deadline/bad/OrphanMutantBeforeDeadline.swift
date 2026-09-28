import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// `swift test` puts its own test-runner helper (`xctest` on this toolchain, `swiftpm-testing-helper`
/// on others) in a process group of its own, so killing only the group `LiveProcessRunner` spawned
/// `swift test` into leaves the helper running: orphaned, reparented to init, spinning forever on
/// an infinite-loop mutant. 12 such orphans survived for hours at ~200% CPU after their mutate runs
/// were killed. Proven here with a real mutant, through the real `LiveMutationToolchain` and
/// `LiveProcessRunner` — no fakes standing in for the process tree.
@Suite("mutate's test timeout takes the whole process tree down")
struct MutationOrphanTests {
  /// The mutant: a real infinite loop, no test ever runs a package built from anything else.
  private static let hangingSource = "public func answer() -> Int { while true {} }\n"

  /// A real, minimal package on disk, already carrying the mutant: one test that calls the
  /// looping `answer()`, built and run for real by `LiveMutationToolchain`.
  private struct Package {
    let root: URL
    let uniqueToken: String

    init() throws {
      uniqueToken = "swiftgate-mutation-orphan-\(UUID().uuidString)"
      root = FileManager.default.temporaryDirectory.appending(
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

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// No process anywhere on the machine still names this package's one-of-a-kind temp path —
    /// the mark of a real orphan, not just this test's own already-reaped child. Reads the pipe
    /// before waiting on the process: on a machine busy enough to fill it, waiting first deadlocks
    /// against the child blocked writing to a full pipe nobody is draining.
    func noDescendantSurvives() -> Bool {
      let pipe = Pipe()
      let process = Process()
      process.executableURL = URL(filePath: "/bin/ps")
      process.arguments = ["-Ao", "command="]
      process.standardOutput = pipe
      try? process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let text = String(decoding: data, as: UTF8.self)
      return !text.contains(uniqueToken)
    }
  }

  @Test(
    "a mutant that loops forever is timed out, and no descendant of the test process (xctest, swiftpm-testing-helper) survives it — catches an orphan left spinning at ~200% CPU",
    .timeLimit(.minutes(10))
  )
  func timeoutTakesTheProcessTreeDown() async throws {
    let package = try Package()
    defer { package.remove() }
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

    #expect(package.noDescendantSurvives())
  }
}
