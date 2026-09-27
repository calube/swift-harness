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
  static let designB = "docs/search/designs/search.md"
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
      (Self.designB, "# Search\n"), ("notes.txt", "notes\n"),
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
    for (plan, design) in [
      (PlanStateScenario.planA, Self.designA), (PlanStateScenario.planB, Self.designB),
    ] {
      try write(layout.plan(plan).ledgerFile, "{}\n")
      let file = PlanFile(
        schemaVersion: 1, slug: plan, design: design, designSha: "3f1c", approval: nil,
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

  @Test(
    "a subagent's git checkout, restore, rm and mv of a design doc, its evidence or a ledger are denied, with or without `--`, a tree-ish, `--cached` or `-C` — catches git rewriting guarded files past the write guard"
  )
  func gitPathspecWritesDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    let design = BashWriteScenario.designA
    let claims = "docs/counter/designs/offline.evidence/claims.jsonl"

    for command in [
      "git checkout -- \(design)",
      "git checkout HEAD -- \(design)",
      "git checkout HEAD~1 \(design)",
      "git checkout \(design)",
      "git checkout -f main -- \(claims)",
      "git restore \(design)",
      "git restore --source=HEAD~1 --worktree -- \(claims)",
      "git restore -s HEAD \(design)",
      "git rm \(design)",
      "git rm -rf --cached -- \(claims)",
      "git mv \(design) docs/counter/designs/renamed.md",
      "git mv notes.txt \(design)",
      "git mv -f notes.txt docs/counter/designs/offline.evidence/",
      "git -C docs rm counter/designs/offline.md",
      "git -C docs/counter checkout -- designs/offline.md",
      "git -c core.autocrlf=false restore \(design)",
      "git checkout -- \(scenario.ledgerA)",
      "cd docs && git restore counter/designs/offline.md",
    ] {
      #expect(try await scenario.decision(command, subagent: true) == "deny", "\(command)")
    }
  }

  @Test(
    "a subagent's branch checkouts, git reads and git writes of unguarded files pass while its git rm of the design is denied — catches the git guard blocking ordinary version control"
  )
  func gitFalsePositivesPass() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    #expect(
      try await scenario.decision("git rm \(BashWriteScenario.designA)", subagent: true) == "deny")

    for command in [
      "git checkout main", "git checkout -b feature", "git checkout -B feature origin/main",
      "git checkout --orphan fresh", "git switch -c other", "git rm notes.txt",
      "git rm --cached notes.txt", "git mv notes.txt NOTES.md", "git restore Sources/x.swift",
      "git checkout -- Sources/x.swift", "git status", "git diff \(BashWriteScenario.designA)",
      "git log -- \(BashWriteScenario.designA)", "git show HEAD:\(BashWriteScenario.designA)",
      "git add \(BashWriteScenario.designA)",
      "git commit -m \"git rm \(BashWriteScenario.designA)\"",
    ] {
      #expect(try await scenario.decision(command, subagent: true) == nil, "\(command)")
    }
  }

  @Test(
    "the lock holder removing or moving another plan's directory is denied, its own passes — catches a holder deleting another plan's lock with its directory"
  )
  func otherPlanDirectoryDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    try scenario.claim(PlanStateScenario.planB, by: "another-session")
    let planB = try scenario.layout.plan(PlanStateScenario.planB).directory

    for command in ["rm -rf \(planB)", "rm -rf \(planB)/", "mv \(planB) /tmp/x"] {
      #expect(try await scenario.decision(command) == "deny", "\(command)")
    }
    #expect(try await scenario.decision("rm -rf \(scenario.planDirectoryA)") == nil)
  }

  @Test(
    "the holder's shell write to its plan.json is denied, its ledger write passes — catches plan.json's design repointed where the guard can't read the new content"
  )
  func shellPlanFileWriteDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let planFile = try scenario.layout.plan(PlanStateScenario.planA).planFile

    for command in [
      "cp /tmp/plan.json \(planFile)", "sed -i '' s/offline/search/ \(planFile)",
      "echo '{}' > \(planFile)",
    ] {
      #expect(try await scenario.decision(command) == "deny", "\(command)")
    }
    #expect(try await scenario.decision("echo '{}' > \(scenario.ledgerA)") == nil)
  }

  @Test(
    "the holder's shell write or delete of the claim and index lock files is denied, its index write passes — catches a lock holder forging or breaking the lock that serialises claims"
  )
  func lockFilesDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    try scenario.claim(PlanStateScenario.planA, by: PlanStateScenario.session)
    let root = scenario.layout.root

    for command in [
      "echo 1 > \(root)/claim.lock.0", "rm -f \(root)/claim.lock.guard",
      "touch \(root)/index.lock.0", "rm \(root)/index.lock.guard",
    ] {
      #expect(try await scenario.decision(command) == "deny", "\(command)")
    }
    #expect(try await scenario.decision("echo '{}' > \(scenario.layout.indexFile)") == nil)
  }
}

@Suite("PreToolUse plan and index commands act only as the calling session")
struct PlanCommandAuthorityTests {
  static let session = PlanStateScenario.session
  static let plan = PlanStateScenario.planA

  @Test(
    "`plan release --force` is denied from the main session and a subagent, in any spelling — catches an agent taking over another session's lock"
  )
  func forceReleaseDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }

    for command in [
      "swiftgate plan release \(Self.plan) --force",
      "swiftgate plan release --force \(Self.plan) --session \(Self.session)",
      "plugin/bin/swiftgate plan release \(Self.plan) --force",
      "SWIFT_HARNESS_ORCHESTRATOR=1 ~/.local/bin/swiftgate plan release \(Self.plan) --force",
      "cd /tmp && bash -c 'swiftgate plan release \(Self.plan) --force'",
      "swift run swiftgate plan release \(Self.plan) --force",
      "swiftgate --format json plan release \(Self.plan) --force",
    ] {
      #expect(try await scenario.decision(command) == "deny", "\(command)")
      #expect(try await scenario.decision(command, subagent: true) == "deny", "\(command)")
    }
    let reason = try await scenario.run(
      "swiftgate plan release \(Self.plan) --force", subagent: false
    ).output?["permissionDecisionReason"]
    #expect(reason?.contains(EditGuard.planStateRuleID) == true)
    #expect(reason?.contains("user") == true)
  }

  @Test(
    "plan claim, release and set and index set naming another session are denied — catches a session releasing or claiming as the holder with the id the lock message printed"
  )
  func otherSessionDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }

    for command in [
      "swiftgate plan release \(Self.plan) --session another-session",
      "swiftgate plan release \(Self.plan) --session=another-session",
      "swiftgate plan claim \(Self.plan) --session another-session",
      "swiftgate plan claim \(Self.plan) --design docs/x/designs/y.md --session another-session",
      "swiftgate plan set \(Self.plan) --tier deep --session another-session",
      "swiftgate index set \(Self.plan) approved --resume x --session another-session",
      "swiftgate plan release \(Self.plan) --session \(Self.session) --session another-session",
      "swiftgate plan release \(Self.plan) --session \"$SESSION\"",
    ] {
      #expect(try await scenario.decision(command) == "deny", "\(command)")
    }
  }

  @Test(
    "plan claim, release and set and index set from a subagent are denied even with its own session id — catches a worker claiming, releasing or re-indexing the orchestrator's plan"
  )
  func subagentDenied() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }

    for command in [
      "swiftgate plan claim \(Self.plan) --session \(Self.session)",
      "swiftgate plan release \(Self.plan) --session \(Self.session)",
      "swiftgate plan set \(Self.plan) --resume done --session \(Self.session)",
      "swiftgate index set \(Self.plan) done --resume x",
      "swiftgate index set \(Self.plan) done --resume x --session \(Self.session)",
    ] {
      #expect(try await scenario.decision(command, subagent: true) == "deny", "\(command)")
    }
  }

  @Test(
    "the main session's own claim, release, set and index set, other swiftgate commands and mentions in text pass — catches the authority guard blocking the design skill's own calls"
  )
  func ownCommandsPass() async throws {
    let scenario = try await BashWriteScenario()
    defer { scenario.remove() }
    #expect(
      try await scenario.decision("swiftgate plan release \(Self.plan) --force") == "deny")

    for command in [
      "swiftgate plan claim \(Self.plan) --session \(Self.session) --design docs/x/designs/y.md",
      "swiftgate plan release \(Self.plan) --session=\(Self.session)",
      "swiftgate plan set \(Self.plan) --tier deep --session \(Self.session)",
      "swiftgate index set \(Self.plan) approved --resume x --session \(Self.session)",
      "swiftgate plan-lint --plan \(Self.plan)", "swiftgate check --tier fast",
      "echo swiftgate plan release \(Self.plan) --force",
      "git commit -m \"docs: swiftgate plan release --force is for the user\"",
    ] {
      #expect(try await scenario.decision(command) == nil, "\(command)")
    }
  }
}
