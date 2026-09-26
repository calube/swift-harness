import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real repository with a linked worktree, plan state in the real git common dir, and the
/// recorded live Bash payload rewritten to run a given command from the worktree. A subagent's
/// payload adds the `agent_id`/`agent_type` a live subagent payload carries.
private struct BashWriteScenario {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]
  static let recordedCommand = "\"swiftgate check --tier fast 2>&1 | tail -25\""
  static let designA = "docs/counter/designs/offline.md"
  static let resolved = "Packages/Feed/Package.resolved"
  static let snapshots = "Packages/Feed/Tests/FeedTests/__Snapshots__"

  let main: ProbeRepository
  /// The worker's checkout: every payload's `cwd`.
  let worktree: URL
  let layout: PlanStateLayout
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)
  var environment: [String: String] = [:]

  init() async throws {
    main = try ProbeRepository()
    for (path, content) in [
      (Self.designA, "# Offline\n"), ("docs/counter/designs/offline.evidence/claims.jsonl", ""),
      (Self.resolved, "{}\n"), (Self.snapshots + "/FeedTests/view.1.png", "png"),
    ] {
      try main.write(path, content)
    }
    worktree = main.root.deletingLastPathComponent()
      .appending(path: "\(main.root.lastPathComponent)-linked", directoryHint: .isDirectory)
    try await Self.git(runner, in: main.root, "init", "-q", "-b", "main")
    try await Self.git(runner, in: main.root, "add", "-A")
    try await Self.git(runner, in: main.root, "commit", "-q", "-m", "base")
    try await Self.git(runner, in: main.root, "worktree", "add", "-q", "-b", "task", worktree.path)
    let common = try await LiveGit(runner: runner, repositoryRoot: worktree.path)
      .commonDirectory()
    layout = try PlanStateLayout(commonDirectory: common)
    for plan in [PlanStateScenario.planA, PlanStateScenario.planB] {
      try write(layout.plan(plan).ledgerFile, "{}\n")
      let file = PlanFile(
        schemaVersion: 1, slug: plan, design: Self.designA, designSha: "3f1c", approval: nil,
        clarifyChain: [], tier: .standard, resume: "planned")
      try write(
        layout.plan(plan).planFile,
        String(decoding: try PlanFileJSON.encode(file), as: UTF8.self))
    }
    try write(layout.indexFile, "{}\n")
  }

  func remove() {
    try? FileManager.default.removeItem(at: worktree)
    main.remove()
  }

  var ledgerA: String { (try? layout.plan(PlanStateScenario.planA).ledgerFile) ?? "" }
  var ledgerB: String { (try? layout.plan(PlanStateScenario.planB).ledgerFile) ?? "" }
  var planDirectoryA: String { (try? layout.plan(PlanStateScenario.planA).directory) ?? "" }

  func claim(_ plan: String, by session: String) throws {
    try write(try layout.plan(plan).orchestratorLock, session + "\n")
  }

  func write(_ absolute: String, _ content: String) throws {
    let url = URL(filePath: absolute)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  /// Static: `init` runs git before every stored property is set.
  @discardableResult
  private static func git(_ runner: LiveProcessRunner, in directory: URL, _ arguments: String...)
    async throws -> String
  {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct Failure: Error { let stderr: String }
      throw Failure(stderr: output.stderr.text)
    }
    return output.stdout.text
  }

  /// The hook's output for `command`, and how long the hook took.
  func run(_ command: String, subagent: Bool) async throws -> (
    output: [String: String]?, milliseconds: Int
  ) {
    var text = try Fixture.text("Hooks/pre-tool-use-bash-allowed.json")
    let quoted = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
    text = text.replacingOccurrences(of: Self.recordedCommand, with: quoted)
    text = text.replacingOccurrences(of: "\"/REPO", with: "\"\(worktree.path)")
    if subagent {
      text = text.replacingOccurrences(
        of: "\"tool_use_id\"",
        with: "\"agent_id\": \"a1b2c3d4\", \"agent_type\": \"general-purpose\", \"tool_use_id\"")
    }
    let dependencies = HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: worktree.path),
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), formatter: FakeSwiftFormatter(),
      xcode: FixedXcode(version: "26.2"), sweep: PendingOrphanCloneSweep(),
      commitJudge: DisabledCommitCommentJudge(), environment: environment)
    let input = Data(text.utf8)
    let (result, milliseconds) = await GateRun.timed {
      await HookRunner.run(.preToolUse, input: input) { _ in dependencies }
    }
    guard let stdout = result.stdout else { return (nil, milliseconds) }
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    return (json["hookSpecificOutput"] as? [String: String], milliseconds)
  }

  /// `"deny"`, or `nil` when the call is left to the normal permission flow.
  func decision(_ command: String, subagent: Bool = false) async throws -> String? {
    try await run(command, subagent: subagent).output?["permissionDecision"]
  }
}

@Suite("PreToolUse Bash writes go through the file guards")
struct BashWriteGuardTests {
  @Test(
    "a subagent's Bash writes to plan state and design artifacts are denied by redirect, tee, cp, mv, install, ln, sed -i, perl -i, rm, truncate, touch, dd, cd and bash -c, even in the holder's session with the override — catches workers rewriting the ledger through the shell"
  )
  func subagentBashWritesDenied() async throws {
    var scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    scenario.environment = [OrchestratorMarker.environmentVariable: "1"]
    let ledger = scenario.ledgerA
    let plan = try scenario.layout.plan(PlanStateScenario.planA)

    for command in [
      "echo '{}' > \(ledger)",
      "echo x >> \(ledger)",
      "cat /tmp/x | tee \(ledger)",
      "cp -f /tmp/x \(plan.planFile)",
      "mv /tmp/x \(scenario.layout.indexFile)",
      "install -m 644 /tmp/x \(ledger)",
      "ln -sf /tmp/x \(ledger)",
      "sed -i '' s/a/b/ \(ledger)",
      "perl -pi -e 's/a/b/' \(ledger)",
      "rm -f \(ledger)",
      "truncate -s 0 \(ledger)",
      "touch \(scenario.planDirectoryA)/notes.json",
      "dd if=/dev/zero of=\(ledger) count=0",
      "cp /tmp/ledger.json \(scenario.planDirectoryA)",
      "(cd \(scenario.planDirectoryA) && echo '{}' > ledger.json)",
      "ls && bash -c \"echo '{}' > \(ledger)\"",
      "echo x >> \(BashWriteScenario.designA)",
      "echo x > docs/counter/designs/offline.evidence/claims.jsonl",
    ] {
      #expect(try await scenario.decision(command, subagent: true) == "deny", "\(command)")
    }
    let reason = try await scenario.run("echo '{}' > \(ledger)", subagent: true)
      .output?["permissionDecisionReason"]
    #expect(reason?.contains(EditGuard.planStateRuleID) == true)
    #expect(reason?.contains(ledger) == true)
  }

  @Test(
    "Bash writes to Package.resolved, __Snapshots__ and orchestrator.lock are denied as their Write is, relative targets resolved against cwd — catches `echo > Package.resolved` and `rm -rf __Snapshots__` passing"
  )
  func artifactWritesDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let resolved = BashWriteScenario.resolved

    for (command, rule) in [
      ("echo {} > \(resolved)", EditGuard.packageResolvedRuleID),
      ("sed -i '' s/a/b/ \(resolved)", EditGuard.packageResolvedRuleID),
      ("cp -f /tmp/x \(scenario.worktree.path)/\(resolved)", EditGuard.packageResolvedRuleID),
      ("rm -rf \(BashWriteScenario.snapshots)", EditGuard.snapshotReferenceRuleID),
      ("cp /tmp/v.png \(BashWriteScenario.snapshots)/", EditGuard.snapshotReferenceRuleID),
      (
        "echo other > \(try scenario.layout.plan(PlanStateScenario.planA).orchestratorLock)",
        EditGuard.planStateRuleID
      ),
    ] {
      let output = try await scenario.run(command, subagent: false).output
      #expect(output?["permissionDecision"] == "deny", "\(command)")
      #expect(output?["permissionDecisionReason"]?.contains(rule) == true, "\(command)")
    }
  }

  @Test(
    "the lock holder writes its own plan state and design through Bash as through Write, and not another plan's — catches the guard locking out the orchestrator, or a holder of plan A writing plan B"
  )
  func holderWritesOwnPlan() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    try scenario.claim(PlanStateScenario.planB, by: "another-session")

    for command in [
      "echo '{}' > \(scenario.ledgerA)",
      "cd \(scenario.planDirectoryA) && echo '{}' > ledger.json",
      "cat /tmp/index | tee \(scenario.layout.indexFile)",
      "echo x >> \(BashWriteScenario.designA)",
    ] {
      #expect(try await scenario.decision(command) == nil, "\(command)")
    }
    #expect(try await scenario.decision("echo '{}' > \(scenario.ledgerB)") == "deny")
    #expect(
      try await scenario.decision("echo '{}' > \(scenario.ledgerA)", subagent: true) == "deny")
  }

  @Test(
    "a subagent's quoted mentions, reads, descriptor redirects, /dev/null, ordinary writes, backups and heredoc text pass while its ledger write is denied — catches the guard denying everyday commands that only mention plan state"
  )
  func ordinaryCommandsPass() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    let ledger = scenario.ledgerA
    #expect(try await scenario.decision("echo {} > \(ledger)", subagent: true) == "deny")

    for command in [
      "git commit -m \"record progress: echo {} > \(ledger)\"",
      "grep '>' \(ledger)",
      "echo hi > /tmp/x",
      "swift build 2>&1 | tee build.log",
      "cat \(ledger)",
      "cp \(ledger) /tmp/backup",
      "cp \(ledger) \(scenario.worktree.path)/docs",
      "make > /dev/null 2>&1",
      "echo note >> docs/notes.md",
      "cat > notes.md <<'EOF'\necho {} > \(ledger)\nrm -rf \(BashWriteScenario.snapshots)\nEOF",
    ] {
      #expect(try await scenario.decision(command, subagent: true) == nil, "\(command)")
    }
  }

  @Test(
    "a subagent command whose last write is the ledger, after ordinary writes and a backup, is denied fastest of 5 under 50ms — catches write-target checks blowing the PreToolUse Bash budget"
  )
  func fast() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    let command =
      "swift build 2>&1 | tee build.log && cp \(scenario.ledgerA) /tmp/backup "
      + "&& echo '{}' > \(scenario.ledgerA)"

    let samples = try await Latency.samples {
      let (output, milliseconds) = try await scenario.run(command, subagent: true)
      #expect(output?["permissionDecision"] == "deny")
      return milliseconds
    }
    #expect(samples.min()! < 50, "fast samples: \(samples)ms, budget: 50ms")
  }
}
