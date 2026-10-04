import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

@Suite("temporary directories: a root per test process, and SwiftPM's lock files")
struct TemporaryDirectoriesTests {
  static let gateDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// Lock files in `directory` SwiftPM named after `package`.
  static func locks(in directory: URL, for package: URL) throws -> [String] {
    let stem = CanonicalPath.of(package).replacingOccurrences(of: "/", with: "_")
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix(stem + "_") && $0.hasSuffix(".lock") }
  }

  @Test(
    "removing a temp package also removes the lock files SwiftPM left for it in the temp directory — catches every temp package leaving a lock file behind on every run",
    .timeLimit(.minutes(5)))
  func removeTakesSwiftPMLocks() async throws {
    let scratch = try TestTemporaryDirectory.make("swiftpm-locks")
    defer { TestTemporaryDirectory.remove(scratch) }
    // SwiftPM puts its locks in $TMPDIR; a private one can be listed and holds nothing else.
    let lockDirectory = scratch.appending(path: "tmp", directoryHint: .isDirectory)
    let tree = scratch.appending(path: "tree", directoryHint: .isDirectory)
    let package = tree.appending(path: "nested/Sample", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: package.appending(path: "Sources/Sample"), withIntermediateDirectories: true)
    try Data(
      """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(name: "Sample", targets: [.target(name: "Sample")])

      """.utf8
    ).write(to: package.appending(path: "Package.swift"))
    try Data("public enum Sample {}\n".utf8)
      .write(to: package.appending(path: "Sources/Sample/Sample.swift"))

    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "swift", arguments: ["package", "describe", "--type", "json"],
        environmentOverlay: ["TMPDIR": lockDirectory.path + "/"],
        workingDirectory: package.path, timeout: .seconds(240)))
    #expect(output.status.isSuccess, "\(output.stderr.text)")
    try #require(try !Self.locks(in: lockDirectory, for: package).isEmpty)

    TemporaryDirectories.remove(tree, lockDirectory: lockDirectory)

    #expect(try Self.locks(in: lockDirectory, for: package) == [])
    #expect(!FileManager.default.fileExists(atPath: tree.path))
  }

  @Test(
    "this process's root sits under the shared parent named for its pid, and a sweep removes the roots and lock files of exited processes while keeping live ones — catches test temp files left behind by a killed run"
  )
  func sweepRemovesExitedRoots() throws {
    let root = TestTemporaryDirectory.root
    #expect(root.deletingLastPathComponent().path == TestTemporaryDirectory.parent.path)
    #expect(root.lastPathComponent.hasPrefix("\(getpid())-"))

    let scratch = try TestTemporaryDirectory.make("sweep")
    defer { TestTemporaryDirectory.remove(scratch) }
    let parent = scratch.appending(path: "parent", directoryHint: .isDirectory)
    let locks = scratch.appending(path: "locks", directoryHint: .isDirectory)
    // Above macOS's highest pid, so it can never name a live process.
    let exited = parent.appending(path: "999999-0000", directoryHint: .isDirectory)
    let live = parent.appending(path: "\(getpid())-1111", directoryHint: .isDirectory)
    let package = exited.appending(path: "pkg", directoryHint: .isDirectory)
    for directory in [locks, live, package] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data().write(to: package.appending(path: "Package.swift"))
    let lockFiles = TemporaryDirectories.swiftPMLockFiles(forPackageAt: package, in: locks)
    for lock in lockFiles { try Data().write(to: lock) }

    TestTemporaryDirectory.sweep(parent: parent, lockDirectory: locks)

    #expect(!FileManager.default.fileExists(atPath: exited.path))
    #expect(FileManager.default.fileExists(atPath: live.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path) == [])
  }

  /// Names that make a temporary file somewhere other than this process's root.
  static let bypasses = [
    ".temporaryDirectory", "NSTemporaryDirectory", "mkdtemp(", "mkstemp(",
    "TemporaryDirectories.system", "TemporaryDirectories.make(",
  ]

  /// Test bodies that name the system temp directory themselves, each removing what it makes.
  /// Editing one of these tests is the time to move it onto ``TestTemporaryDirectory``, and to
  /// lower its count here; nothing may raise one or add a file.
  static let predating: [String: Int] = [
    "Tests/SwiftGateAdaptersTests/AppBuildAdapterTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/BrownfieldDiscoverAdaptersTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/BuildCalibrationReturnTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/CanonicalPathTests.swift": 3,
    "Tests/SwiftGateAdaptersTests/GitCommonDirTests.swift": 3,
    "Tests/SwiftGateAdaptersTests/GitTopLevelTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/JevJudgeTests.swift": 2,
    "Tests/SwiftGateAdaptersTests/JudgeAdaptersTests.swift": 2,
    "Tests/SwiftGateAdaptersTests/KilledRunChildrenTests.swift": 2,
    "Tests/SwiftGateAdaptersTests/LiveProcessRunnerTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/PlanStateStoreSpecPageTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/RepositoryScriptTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/RunViewReaderTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/SimulatorClonesTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/StateRootResolverTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/SwiftFormatterTests.swift": 1,
    "Tests/SwiftGateAdaptersTests/WorktreeSeedingTests.swift": 2,
    "Tests/SwiftGateAdaptersTests/XcodeGeneratorTests.swift": 1,
    "Tests/SwiftGateCLITests/ArchCommandTests.swift": 1,
    "Tests/SwiftGateCLITests/BrownfieldCheckOptionsTests.swift": 1,
    "Tests/SwiftGateCLITests/BrownfieldSliceCheckTests.swift": 1,
    "Tests/SwiftGateCLITests/BuildBrownfieldPresetTests.swift": 1,
    "Tests/SwiftGateCLITests/BuildMergeCommandTests.swift": 1,
    "Tests/SwiftGateCLITests/CheckJudgeStepTests.swift": 1,
    "Tests/SwiftGateCLITests/CommitMessageIdCheckTests.swift": 1,
    "Tests/SwiftGateCLITests/ConsumerSteeringTests.swift": 1,
    "Tests/SwiftGateCLITests/DesignScopeCommandTests.swift": 3,
    "Tests/SwiftGateCLITests/DesignStatsCommandTests.swift": 2,
    "Tests/SwiftGateCLITests/DocsLintCommandTests.swift": 1,
    "Tests/SwiftGateCLITests/GCEventsTests.swift": 1,
    "Tests/SwiftGateCLITests/GateRunEventsTests.swift": 1,
    "Tests/SwiftGateCLITests/GateRunProvenanceTests.swift": 2,
    "Tests/SwiftGateCLITests/HookCommandTests.swift": 1,
    "Tests/SwiftGateCLITests/HookRunnerEventsTests.swift": 1,
    "Tests/SwiftGateCLITests/NewSubcommandRegistrationTests.swift": 1,
    "Tests/SwiftGateCLITests/PlanScheduleCommandTests.swift": 1,
    "Tests/SwiftGateCLITests/ReportCommandTests.swift": 2,
    "Tests/SwiftGateCLITests/ReviewCommandsTests.swift": 1,
    "Tests/SwiftGateCLITests/ScratchWorktreeSweepTests.swift": 1,
    "Tests/SwiftGateCLITests/SelfTestCommandTests.swift": 1,
    "Tests/SwiftGateCLITests/SpecPagePlanCommandTests.swift": 1,
    "Tests/SwiftGateCLITests/SurfaceCheckCommandTests.swift": 2,
    "Tests/SwiftGateCLITests/TestResultHandoffTests.swift": 1,
  ]

  @Test(
    "tests and test support make temporary files only through TestTemporaryDirectory, beyond the test bodies that predate it — catches a test writing straight into the shared temp directory, where nothing removes what it leaves"
  )
  func testsUseTheRoot() throws {
    var counts: [String: Int] = [:]
    for base in ["Tests", "Sources/SwiftGateTestSupport"] {
      let directory = Self.gateDirectory.appending(path: base, directoryHint: .isDirectory)
      let files =
        FileManager.default.enumerator(atPath: directory.path)?
        .compactMap { $0 as? String } ?? []
      for relative in files
      where relative.hasSuffix(".swift") && !relative.hasPrefix("Fixtures/")
        && !relative.hasSuffix("TestTemporaryDirectory.swift")
        && !relative.hasSuffix("TemporaryDirectoriesTests.swift")
      {
        let text = try String(
          contentsOf: directory.appending(path: relative), encoding: .utf8)
        let count = text.split(separator: "\n", omittingEmptySubsequences: false)
          .filter { line in Self.bypasses.contains(where: line.contains) }.count
        if count > 0 { counts["\(base)/\(relative)"] = count }
      }
    }
    #expect(counts == Self.predating)
  }
}
