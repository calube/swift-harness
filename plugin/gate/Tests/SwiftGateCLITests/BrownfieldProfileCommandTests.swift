import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Doctor and the hooks in a temp clone whose own `.git` holds the brownfield state.
@Suite("brownfield profile commands")
struct BrownfieldProfileCommandTests {
  static let config = """
    schema = 1

    [harness]
    profile = "brownfield"

    [brownfield]
    discovered_at = "0123abcd"
    slice_budget_s = 30
    time_budget_min = 0
    sensitive = []

    """

  struct Clone {
    let root: URL
    var layout: BrownfieldStateLayout {
      let git = root.appending(path: ".git", directoryHint: .isDirectory)
      return BrownfieldStateLayout(commonDir: git, gitDir: git)
    }

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-brownfield-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: root.appending(path: ".git/swift-harness/discover", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try Data(BrownfieldProfileCommandTests.config.utf8).write(to: layout.config)
    }

    func dirty(_ paths: [String]) throws {
      try JSONEncoder().encode(DirtyFileList(paths: paths)).write(to: layout.discoverDirty)
    }
  }

  func doctor(_ root: URL) async throws -> GateRunParts {
    try await DoctorRun.run(
      root: root, sessionID: nil, swiftPM: FakeSwiftPM(serving: []),
      runner: FakeProcessRunner { invocation throws(ProcessRunnerError) in
        throw .launchFailed(executable: invocation.executable, reason: "not on this test machine")
      }, environment: [:])
  }

  @Test(
    "doctor in a clone with both configs is RED with doctor.config-conflict naming both paths — catches 1 config silently shadowing the other"
  )
  func doctorConflict() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    let committed = clone.root.appending(path: ConfigLoader.fileName)
    try Data("xcode = \"26.2\"\n".utf8).write(to: committed)

    let parts = try await doctor(clone.root)

    #expect(parts.tiers.first?.verdict == .red)
    let finding = try #require(parts.findings.first { $0.ruleID == "doctor.config-conflict" })
    #expect(finding.severity == .major)
    #expect(finding.message.contains(committed.path))
    #expect(finding.message.contains(clone.layout.config.path))
  }

  @Test(
    "doctor in a brownfield clone skips the owned repository's shim, SwiftLint and Xcode pin checks — catches it demanding a .swiftgate.toml"
  )
  func doctorSkipsOwnedChecks() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }

    let parts = try await doctor(clone.root)

    let rules = Set(parts.findings.map(\.ruleID))
    #expect(!parts.findings.contains { $0.message.contains(ConfigLoader.fileName) })
    for owned in [
      Doctor.xcodePinRuleID, Doctor.shimRuleID, Doctor.swiftLintRuleID, Doctor.simulatorRuleID,
      Doctor.mermaidCLIRuleID,
    ] {
      #expect(!rules.contains(owned), "\(owned)")
    }
    #expect(parts.tiers.first?.verdict != .red)
  }

  func hook(
    _ event: HookEvent, _ fixture: String, in clone: Clone, replacing: [String: String] = [:],
    git: FakeGit? = nil, judge: RecordingJudge? = nil
  ) async throws -> HookResult {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.environment = ["HOME": clone.root.path]
    if let git { harness.git = git }
    if let judge { harness.commitJudge = judge }
    let input = try harness.payload(fixture, cwd: clone.root, replacing: replacing)
    let dependencies = harness.dependencies
    return await HookRunner.run(event, input: input, source: .settings) { _ in dependencies }
  }

  func bash(_ command: String, in clone: Clone) async throws -> HookResult {
    try await hook(
      .preToolUse, "pre-tool-use-bash-allowed", in: clone,
      replacing: ["swiftgate check --tier fast 2>&1 | tail -25": command])
  }

  @Test(
    "the PreToolUse hook in a brownfield clone denies staging a dirty file and allows another — catches hooks that no-op without .swiftgate.toml"
  )
  func preToolUseGuardsDirtyFiles() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    try clone.dirty(["wip.txt"])

    let denied = try #require(try await bash("git add wip.txt", in: clone).stdout)
    #expect(denied.contains("\"deny\""))
    #expect(denied.contains(DirtyFileGuard.ruleID))
    #expect(denied.contains("wip.txt"))

    let allowed = try await bash("git add other.txt", in: clone)
    #expect(allowed.stdout?.contains("\"deny\"") != true)
  }

  @Test(
    "an unreadable dirty list leaves staging allowed but says so, naming the file — catches a corrupt list silently guarding nothing"
  )
  func unreadableDirtyListIsReported() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    try Data("not json".utf8).write(to: clone.layout.discoverDirty)

    let text = try #require(try await bash("git add wip.txt", in: clone).stdout)

    #expect(!text.contains("\"deny\""))
    #expect(text.contains("dirty.json"))
  }

  @Test(
    "a git commit in a brownfield clone gets no comments advice or commit judge, while the hook still guards it — catches our commit rules applied to a team's code"
  )
  func commitSkipsCommentsCheck() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    try clone.dirty(["wip.txt"])
    let judge = RecordingJudge()
    let git = FakeGit(staged: [
      "Sources/A.swift": FakeGit.StagedFile(
        content: "// Previously this used a timer; now uses the clock.\nlet a = 1\n",
        addedLines: [1...2])
    ])

    let commit = try await hook(
      .preToolUse, "pre-tool-use-bash-git-commit", in: clone, git: git, judge: judge)
    let all = try await hook(
      .preToolUse, "pre-tool-use-bash-git-commit", in: clone,
      replacing: ["git commit -m": "git commit -am"], git: git, judge: judge)

    #expect(commit.stdout?.contains("comments") != true)
    #expect(judge.reviews == 0)
    #expect(all.stdout?.contains(DirtyFileGuard.ruleID) == true)
  }

  @Test(
    "in a brownfield clone SessionStart answers with no state in the tree, Stop gates at slice and blocks a RED slice, and PostToolUse stays silent — catches the owned fast tier or formatter run on a team's code, or a brownfield stop that checks nothing"
  )
  func hooksFollowTheProfile() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.environment = ["HOME": clone.root.path]
    let ran = RecordedStrings()
    var dependencies = harness.dependencies
    dependencies.brownfieldSlice = { root in
      ran.append(root.lastPathComponent)
      return (.red, "slice: neutral.unsafe-shortcut on an added line")
    }
    let slice = dependencies

    let start = try await hook(.sessionStart, "session-start", in: clone)
    let stop = await HookRunner.run(
      .stop, input: try harness.payload("stop", cwd: clone.root), source: .settings
    ) { _ in slice }
    let post = try await hook(.postToolUse, "post-tool-use-edit-swift", in: clone)

    #expect(start.stdout?.contains("hookSpecificOutput") == true)
    #expect(!FileManager.default.fileExists(atPath: clone.root.appending(path: ".harness").path))
    #expect(ran.all == [clone.root.lastPathComponent])
    #expect(stop.stdout?.contains("neutral.unsafe-shortcut") == true)
    #expect(stop.stdout?.contains("block") == true)
    #expect(post == .silent)

    _ = await HookRunner.run(.stop, input: try harness.payload("stop")) { _ in slice }
    #expect(ran.all.count == 1, "an owned project's Stop runs the fast tier")
  }
}
