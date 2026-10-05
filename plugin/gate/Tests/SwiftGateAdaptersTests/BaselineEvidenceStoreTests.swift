import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("a failing step's evidence is kept where the baseline names it")
struct BaselineEvidenceStoreTests {
  private struct Clone {
    let root: URL
    let layout: BrownfieldStateLayout
    let scratchTree: URL

    init() throws {
      root = TestTemporaryDirectory.root.appending(
        path: "baseline-evidence-\(UUID().uuidString)", directoryHint: .isDirectory)
      layout = BrownfieldStateLayout(
        commonDir: root.appending(path: "repo/.git", directoryHint: .isDirectory),
        gitDir: root.appending(path: "repo/.git/worktrees/w", directoryHint: .isDirectory))
      scratchTree = root.appending(path: "scratch-tree", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: scratchTree, withIntermediateDirectories: true)
    }

    func remove() { TestTemporaryDirectory.remove(root) }
  }

  static let base = BaselineBase(commit: "1111111", tree: "aaaa")
  static let key = BaselineStepKey(area: "app", step: .test, command: "xcodebuild test")
  static let launchFailed = "Testing failed:\n\tapp-Runner encountered an error\n** TEST FAILED **"

  /// A rerun whose command writes a result bundle into the scratch tree.
  private static func query(_ clone: Clone, headEvidence: [String] = []) -> BaselineQuery {
    BaselineQuery(
      key: key, head: .failed(exit: 65, tail: "head tail", junit: nil), headEvidence: headEvidence
    ) { scratch in
      AreaCommandRequest(
        area: key.area, step: key.step, command: key.command,
        workingDirectory: scratch.path, deadline: .seconds(60), environment: [:],
        junitPath: nil, resultBundlePath: scratch.appending(path: "app.test.xcresult").path)
    }
  }

  /// Fails every request as a test runner that couldn't launch, after writing its bundle.
  private static func launchFailing() -> FakeAreaCommandRunner {
    FakeAreaCommandRunner { request in
      if let bundle = request.resultBundlePath {
        try? FileManager.default.createDirectory(
          atPath: bundle, withIntermediateDirectories: true)
        FileManager.default.createFile(
          atPath: bundle + "/Info.plist", contents: Data("bundle".utf8))
      }
      return .failed(exit: 65, tail: launchFailed, junit: nil)
    }
  }

  @Test(
    "a merge base rerun that fails keeps its tail and result bundle under the baseline directory, and every later lookup names them — catches a whole step excused with no log to read"
  )
  func rerunKeepsEvidence() async throws {
    let clone = try Clone()
    defer { clone.remove() }
    let store = BaselineStore(
      layout: clone.layout, runner: Self.launchFailing(),
      scratch: FakeScratchWorktrees(root: clone.scratchTree))
    let head = ["/runs/r1/app.test.txt"]

    let first = await store.lookupOrRerun(
      [Self.query(clone, headEvidence: head)], base: Self.base)

    #expect(store.load(tree: Self.base.tree).records.count == 1)
    let record = try #require(store.load(tree: Self.base.tree).records.first)
    let kept = try #require(record.evidence)
    let folder = clone.layout.baselineDirectory.appending(path: kept, directoryHint: .isDirectory)
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(files.contains { $0.hasSuffix(".txt") })
    #expect(files.contains { $0.hasSuffix(".xcresult") })
    let tail = try #require(files.first { $0.hasSuffix(".txt") })
    #expect(
      try String(contentsOf: folder.appending(path: tail), encoding: .utf8)
        .contains("encountered an error"))

    let second = await store.lookupOrRerun(
      [Self.query(clone, headEvidence: head)], base: Self.base)
    #expect(second.reran.isEmpty)
    for lookup in [first, second] {
      let summary = try #require(
        lookup.notes.first { $0.message.contains("also fail at the merge base") })
      #expect(summary.message.contains(folder.path))
      #expect(summary.message.contains(head[0]))
      #expect(lookup.verdict.absorbed == [BaselineFailure(key: Self.key, test: nil)])
    }
  }

  @Test(
    "asked for test ids, a test step failing whole at both trees comes back as a gating finding naming both runs' evidence — catches final reading GREEN over a step it excused whole"
  )
  func unattributedGatesWithEvidence() async throws {
    let clone = try Clone()
    defer { clone.remove() }
    let store = BaselineStore(
      layout: clone.layout, runner: Self.launchFailing(),
      scratch: FakeScratchWorktrees(root: clone.scratchTree))

    let lookup = await store.lookupOrRerun(
      [Self.query(clone, headEvidence: ["/runs/r1/app.test.txt"])], base: Self.base,
      attributingTests: true)

    #expect(lookup.verdict.absorbed.isEmpty)
    #expect(lookup.verdict.unattributed == [BaselineFailure(key: Self.key, test: nil)])
    #expect(lookup.unattributed.count == 1)
    let finding = try #require(lookup.unattributed.first)
    #expect(finding.ruleID == BrownfieldRuleID.baselineWholeStep.rawValue)
    #expect(finding.severity.failsGate)
    #expect(finding.message.contains("/runs/r1/app.test.txt"))
    let kept = try #require(store.load(tree: Self.base.tree).records.first?.evidence)
    #expect(finding.message.contains(kept))
  }

  @Test(
    "a failing step's tail, JUnit and result bundle move into the evidence folder, and a passing one keeps nothing — catches the next run of the step overwriting the only report"
  )
  func keepsTailJUnitAndBundle() throws {
    let clone = try Clone()
    defer { clone.remove() }
    let reports = clone.root.appending(path: "junit", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    let junit = reports.appending(path: "app.test.xml")
    try Data("<testsuites/>".utf8).write(to: junit)
    let bundle = reports.appending(path: "app.test.xcresult", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let request = AreaCommandRequest(
      area: "app", step: .test, command: "xcodebuild test", workingDirectory: clone.root.path,
      deadline: .seconds(60), environment: [:], junitPath: junit.path,
      resultBundlePath: bundle.path)
    let into = clone.root.appending(path: "run", directoryHint: .isDirectory)

    let kept = StepEvidence.keep(
      .failed(exit: 65, tail: "the tail", junit: nil), of: request, named: "app.test", in: into)
    let none = StepEvidence.keep(.passed, of: request, named: "app.build", in: into)

    #expect(none.isEmpty)
    #expect(
      Set(kept.map { URL(filePath: $0).lastPathComponent })
        == ["app.test.txt", "app.test.xml", "app.test.xcresult"])
    #expect(
      try String(contentsOf: into.appending(path: "app.test.txt"), encoding: .utf8)
        .contains("the tail"))
    #expect(!FileManager.default.fileExists(atPath: bundle.path), "the bundle moved")
  }

  @Test(
    "the live runner reads a failed xcodebuild run's result bundle into per-test failures — catches every xcode test failure baselined as the whole step"
  )
  func liveRunnerReadsTheBundle() async throws {
    let tests = try Fixture.data("Xcresult/fail.tests.json")
    let bundle = TestTemporaryDirectory.root.appending(
      path: "runner-bundle-\(UUID().uuidString).xcresult", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { TestTemporaryDirectory.remove(bundle) }
    let process = FakeProcessRunner { invocation in
      if invocation.executable == "/bin/sh" {
        #expect(
          !FileManager.default.fileExists(atPath: bundle.path),
          "an earlier bundle is cleared before xcodebuild writes its own")
        return ProcessOutput(status: .exited(65), stdout: "** TEST FAILED **\n")
      }
      if invocation.arguments.contains("test-results") {
        return ProcessOutput(status: .exited(0), stdout: String(decoding: tests, as: UTF8.self))
      }
      return ProcessOutput(status: .exited(0), stdout: "{\"errors\":[]}")
    }
    let runner = LiveAreaCommandRunner(processRunner: process)

    let outcome = await runner.run(
      AreaCommandRequest(
        area: "app", step: .test, command: "xcodebuild test", workingDirectory: "/",
        deadline: .seconds(60), environment: [:], junitPath: nil, resultBundlePath: bundle.path))

    #expect(
      BaselineStepResult.of(outcome)
        == .failedTests([
          "CounterUISnapshotTests.ProbeFailXCTests/testAddsWrong()",
          "CounterUISnapshotTests.ProbeFailSwiftTests/multipliesWrong()",
        ]))
    #expect(
      process.invocations.contains {
        $0.arguments.contains("--path") && $0.arguments.contains(bundle.path)
      })
  }

  @Test(
    "a test step pointed at a leased clone still writes the result bundle its request names — catches the leased run dropping the bundle the baseline reads test ids from"
  )
  func leasedRunKeepsTheBundle() async throws {
    let base = FakeAreaCommandRunner { _ in .passed }
    let request = AreaCommandRequest(
      area: "app", step: .test,
      command:
        "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 17' "
        + "-resultBundlePath '/junit/app.test.xcresult'",
      workingDirectory: "/work", deadline: .seconds(60), environment: [:], junitPath: nil,
      resultBundlePath: "/junit/app.test.xcresult")

    _ = await LeasedDeviceAreaRunner(base: base, leases: FakeTestDeviceLeases()).run(request)

    let leased = try #require(base.requests.first)
    #expect(leased.command.contains("id=\(FakeDevices.device.udid)"))
    #expect(leased.resultBundlePath == "/junit/app.test.xcresult")
  }

  @Test(
    "a test step moved to a worktree's own DerivedData keeps its result bundle, and a leased run keeps its DerivedData seed — catches 1 request rewrite dropping what another added"
  )
  func rewritesKeepEveryField() async throws {
    let layout = BrownfieldStateLayout(
      commonDir: URL(filePath: "/clone/.git", directoryHint: .isDirectory),
      gitDir: URL(filePath: "/clone/.git/worktrees/task", directoryHint: .isDirectory))
    let request = AreaCommandRequest(
      area: "app", step: .test,
      command:
        "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 17' "
        + "-resultBundlePath '/junit/app.test.xcresult'",
      workingDirectory: "/work", deadline: .seconds(60), environment: [:], junitPath: nil,
      resultBundlePath: "/junit/app.test.xcresult")

    let seeded = XcodeDerivedData.request(request, layout: layout)
    #expect(seeded.derivedDataSeed != nil)
    #expect(seeded.resultBundlePath == "/junit/app.test.xcresult")

    let base = FakeAreaCommandRunner { _ in .passed }
    _ = await LeasedDeviceAreaRunner(base: base, leases: FakeTestDeviceLeases()).run(seeded)
    let leased = try #require(base.requests.first)
    #expect(leased.derivedDataSeed == seeded.derivedDataSeed)
    #expect(leased.resultBundlePath == "/junit/app.test.xcresult")
  }
}
