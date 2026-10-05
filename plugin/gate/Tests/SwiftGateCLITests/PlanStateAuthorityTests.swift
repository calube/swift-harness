import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real repository with one linked worktree, driven through the built `swiftgate`, so every
/// command resolves the shared plan state the way two sessions in two checkouts would.
private struct AuthorityRepository {
  static let alice = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let bob = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d"
  static let carol = "c4a1d7e2-9b3f-4e8a-a6c2-1f0e9d8c7b6a"
  static let planA = "2026-09-26-search"
  static let planB = "2026-09-26-other"
  static let designA = "docs/search/designs/search.md"
  static let designB = "docs/other/designs/other.md"

  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  struct Result {
    let status: SwiftGateAdapters.ExitStatus

    var exit: Int32? {
      if case .exited(let code) = status { code } else { nil }
    }
    let stdout: String

    var json: [String: Any] {
      get throws {
        try #require(
          try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
          Comment(rawValue: stdout))
      }
    }
  }

  let scratch: URL
  let main: URL
  let linked: URL
  let runner = LiveProcessRunner(baseEnvironment: environment)

  init() async throws {
    scratch = URL(
      filePath: CanonicalPath.of(
        TestTemporaryDirectory.root.appending(
          path: "swiftgate-authority-\(UUID().uuidString)", directoryHint: .isDirectory)),
      directoryHint: .isDirectory)
    main = scratch.appending(path: "repo", directoryHint: .isDirectory)
    linked = scratch.appending(path: "repo-linked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    try await git(["init", "-q", "-b", "main"])
    try await git(["config", "commit.gpgsign", "false"])
    for design in [Self.designA, Self.designB] {
      let url = main.appending(path: design)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("# Design\n".utf8).write(to: url)
    }
    try await git(["add", "-A"])
    try await git(["commit", "-q", "-m", "designs"])
    try await git(["worktree", "add", "-q", "-b", "task", linked.path])
  }

  func remove() { TestTemporaryDirectory.remove(scratch) }

  private func git(_ arguments: [String]) async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: main.path,
        timeout: .seconds(30)))
    #expect(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
  }

  /// Checks that the command tree accepts `arguments` in process, then runs the built binary from
  /// `directory` (the commands act on the working directory's repository), with coverage output
  /// kept out of the checkout.
  func swiftgate(_ arguments: [String], in directory: URL) async throws -> Result {
    _ = try await SwiftGate.asyncParseAsRoot(arguments)
    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let output = try await runner.run(
      ProcessInvocation(
        executable: binary, arguments: arguments,
        environmentOverlay: [
          "LLVM_PROFILE_FILE": scratch.appending(path: "swiftgate-%p.profraw").path
        ],
        workingDirectory: directory.path, timeout: .seconds(60)))
    return Result(status: output.status, stdout: output.stdout.text)
  }

  var layout: PlanStateLayout {
    get throws { try PlanStateLayout(commonDirectory: main.appending(path: ".git").path) }
  }

  func contents(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

  func planFile(_ plan: String) throws -> PlanFile {
    try PlanFileJSON.decode(try #require(contents(try layout.plan(plan).planFile)))
  }

  func claim(_ plan: String, _ session: String, design: String, in directory: URL) async throws
    -> Result
  {
    try await swiftgate(
      ["plan", "claim", plan, "--session", session, "--design", design, "--json"], in: directory)
  }

  /// The PreToolUse hook's decision on a Bash `command` run from the linked worktree by `session`,
  /// from the recorded live payload; a subagent's payload adds the fields a live one carries.
  func hookDecision(_ command: String, session: String, subagent: Bool = false) async throws
    -> (decision: String?, reason: String?)
  {
    var text = try Fixture.text("Hooks/pre-tool-use-bash-allowed.json")
    let quoted = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
    text = text.replacingOccurrences(
      of: "\"swiftgate check --tier fast 2>&1 | tail -25\"", with: quoted)
    text = text.replacingOccurrences(of: "\"/REPO", with: "\"\(linked.path)")
    text = text.replacingOccurrences(
      of: "\"session_id\": \"8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f\"",
      with: "\"session_id\": \"\(session)\"")
    if subagent {
      text = text.replacingOccurrences(
        of: "\"tool_use_id\"",
        with: "\"agent_id\": \"a1b2c3d4\", \"agent_type\": \"general-purpose\", \"tool_use_id\"")
    }
    let payload = try HookPayload.decode(Data(text.utf8))
    #expect(payload.sessionID == session)
    let dependencies = HookDependencies(
      git: LiveGit(runner: runner, repositoryRoot: linked.path),
      swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), formatter: FakeSwiftFormatter(),
      xcode: FixedXcode(version: "26.2"), sweep: PendingOrphanCloneSweep(),
      commitJudge: DisabledCommitCommentJudge(), environment: [:])
    guard
      let stdout = await PreToolUseHook.run(payload, root: linked, dependencies: dependencies)
    else { return (nil, nil) }
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    let output = json["hookSpecificOutput"] as? [String: String]
    return (output?["permissionDecision"], output?["permissionDecisionReason"])
  }
}

@Suite("plan state authority through the built command")
struct PlanStateAuthorityTests {
  @Test(
    "a new plan naming a design another plan owns exits 1 and writes nothing, however the path is spelled — catches a second plan co-owning a design doc and its evidence",
    arguments: [
      AuthorityRepository.designA, "docs/Search/designs/SEARCH.md",
      "docs/alias/designs/search.md",
    ])
  func claimRefusesAnOwnedDesign(spelling: String) async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    try FileManager.default.createSymbolicLink(
      atPath: repo.linked.appending(path: "docs/alias").path, withDestinationPath: "search")
    let owner = try await repo.claim(
      AuthorityRepository.planA, AuthorityRepository.alice, design: AuthorityRepository.designA,
      in: repo.main)
    #expect(owner.exit == 0, "\(owner.stdout)")

    let second = try await repo.claim(
      AuthorityRepository.planB, AuthorityRepository.bob, design: spelling, in: repo.linked)

    #expect(second.exit == 1, "\(second.stdout)")
    #expect(try second.json["status"] as? String == "design-owned")
    #expect(second.stdout.contains(AuthorityRepository.planA))
    #expect(
      !FileManager.default.fileExists(
        atPath: try repo.layout.plan(AuthorityRepository.planB).directory))

    let free = try await repo.claim(
      AuthorityRepository.planB, AuthorityRepository.bob, design: AuthorityRepository.designB,
      in: repo.linked)
    #expect(free.exit == 0, "an unowned design stays claimable: \(free.stdout)")
  }

  @Test(
    "index set exits 1 unless --session holds that plan's lock, and 2 without --session, leaving the index untouched — catches a subagent or another plan's holder rewriting a plan's status"
  )
  func indexSetNeedsThePlanHolder() async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    _ = try await repo.claim(
      AuthorityRepository.planA, AuthorityRepository.alice, design: AuthorityRepository.designA,
      in: repo.main)
    _ = try await repo.claim(
      AuthorityRepository.planB, AuthorityRepository.bob, design: AuthorityRepository.designB,
      in: repo.linked)
    let index = try repo.layout.indexFile
    let set = ["index", "set", AuthorityRepository.planA, "approved", "approved by hand"]

    let otherPlanHolder = try await repo.swiftgate(
      set + ["--session", AuthorityRepository.bob], in: repo.linked)
    #expect(otherPlanHolder.exit == 1, "\(otherPlanHolder.stdout)")
    #expect(otherPlanHolder.stdout.contains(AuthorityRepository.alice))
    let noLock = try await repo.swiftgate(
      set + ["--session", AuthorityRepository.carol], in: repo.linked)
    #expect(noLock.exit == 1, "\(noLock.stdout)")
    let noSession = try await repo.swiftgate(set, in: repo.linked)
    #expect(noSession.exit == 2, "\(noSession.stdout)")
    #expect(repo.contents(index) == nil)

    let holder = try await repo.swiftgate(
      [
        "index", "set", AuthorityRepository.planA, "designing", "framed", "--session",
        AuthorityRepository.alice,
      ], in: repo.linked)
    #expect(holder.exit == 0, "\(holder.stdout)")
    let written = try #require(repo.contents(index))
    #expect(try PlanIndex.decode(written).plans.map(\.status) == ["designing"])

    _ = try await repo.swiftgate(
      ["plan", "release", AuthorityRepository.planA, "--session", AuthorityRepository.alice],
      in: repo.main)
    let released = try await repo.swiftgate(
      set + ["--session", AuthorityRepository.alice], in: repo.main)
    #expect(released.exit == 1, "\(released.stdout)")
    #expect(repo.contents(index) == written)
  }

  @Test(
    "a claim or release refused over another session's lock names the holder and hands the decision to the user, with no --force command to copy — catches an agent pasting the takeover it was shown"
  )
  func refusalCarriesNoForceRecipe() async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    _ = try await repo.claim(
      AuthorityRepository.planA, AuthorityRepository.alice, design: AuthorityRepository.designA,
      in: repo.main)
    let lock = try repo.layout.plan(AuthorityRepository.planA).orchestratorLock

    for arguments in [
      ["plan", "claim", AuthorityRepository.planA, "--session", AuthorityRepository.bob],
      ["plan", "release", AuthorityRepository.planA, "--session", AuthorityRepository.bob],
    ] {
      for format in [[], ["--json"]] {
        let refused = try await repo.swiftgate(arguments + format, in: repo.linked)
        #expect(refused.exit == 1, "\(arguments): \(refused.stdout)")
        #expect(refused.stdout.contains(AuthorityRepository.alice), "\(refused.stdout)")
        #expect(!refused.stdout.contains("--force"), "\(refused.stdout)")
        #expect(refused.stdout.contains("user"), "\(refused.stdout)")
      }
    }
    #expect(repo.contents(lock) == Data((AuthorityRepository.alice + "\n").utf8))
  }

  @Test(
    "plan set rewrites tier and resume for the holder only and keeps every other field — catches plan.json keeping its claimed tier and `framing` after a re-scope"
  )
  func planSetUpdatesTierAndResume() async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    _ = try await repo.swiftgate(
      [
        "plan", "claim", AuthorityRepository.planA, "--session", AuthorityRepository.alice,
        "--design", AuthorityRepository.designA, "--tier", "quick",
      ], in: repo.main)
    _ = try await repo.claim(
      AuthorityRepository.planB, AuthorityRepository.bob, design: AuthorityRepository.designB,
      in: repo.linked)
    let seed = try repo.planFile(AuthorityRepository.planA)
    #expect(seed.tier == .quick)
    #expect(seed.resume == "framing")
    let set = ["plan", "set", AuthorityRepository.planA]

    let rescoped = try await repo.swiftgate(
      set + [
        "--session", AuthorityRepository.alice, "--tier", "deep", "--resume",
        "re-scoped to deep; next: research", "--json",
      ], in: repo.linked)
    #expect(rescoped.exit == 0, "\(rescoped.stdout)")
    #expect(try rescoped.json["status"] as? String == "updated")
    let updated = try repo.planFile(AuthorityRepository.planA)
    #expect(updated.tier == .deep)
    #expect(updated.resume == "re-scoped to deep; next: research")
    #expect(
      updated
        == PlanFile(
          schemaVersion: seed.schemaVersion, slug: seed.slug, design: seed.design,
          designSha: seed.designSha, approval: seed.approval, clarifyChain: seed.clarifyChain,
          tier: .deep, resume: "re-scoped to deep; next: research"))

    let resumeOnly = try await repo.swiftgate(
      set + ["--session", AuthorityRepository.alice, "--resume", "drafting"], in: repo.main)
    #expect(resumeOnly.exit == 0, "\(resumeOnly.stdout)")
    #expect(try repo.planFile(AuthorityRepository.planA).tier == .deep)
    #expect(try repo.planFile(AuthorityRepository.planA).resume == "drafting")

    let toSketch = try await repo.swiftgate(
      set + ["--session", AuthorityRepository.alice, "--tier", "sketch"], in: repo.linked)
    #expect(toSketch.exit == 0, "plan set --tier sketch: \(toSketch.stdout)")
    #expect(try repo.planFile(AuthorityRepository.planA).tier == .sketch)

    let before = repo.contents(try repo.layout.plan(AuthorityRepository.planA).planFile)
    for (arguments, exit) in [
      (["--session", AuthorityRepository.bob, "--tier", "standard"], Int32(1)),
      (["--session", AuthorityRepository.carol, "--resume", "taken"], 1),
      (["--session", AuthorityRepository.alice], 2),
      (["--tier", "standard"], 2),
      (["--session", AuthorityRepository.alice, "--tier", "huge"], 2),
      (["--session", AuthorityRepository.alice, "--resume", ""], 2),
      (["--session", AuthorityRepository.alice, "--resume", "two\nlines"], 2),
    ] {
      let refused = try await repo.swiftgate(set + arguments, in: repo.linked)
      #expect(refused.exit == exit, "\(arguments): \(refused.stdout)")
    }
    #expect(repo.contents(try repo.layout.plan(AuthorityRepository.planA).planFile) == before)

    _ = try await repo.swiftgate(
      ["plan", "release", AuthorityRepository.planA, "--session", AuthorityRepository.alice],
      in: repo.main)
    let unheld = try await repo.swiftgate(
      set + ["--session", AuthorityRepository.alice, "--tier", "standard"], in: repo.main)
    #expect(unheld.exit == 1, "\(unheld.stdout)")
    #expect(repo.contents(try repo.layout.plan(AuthorityRepository.planA).planFile) == before)
  }

  @Test(
    "concurrent plan set calls each publish a whole plan.json and leave no staging file, and a malformed plan.json exits 2 untouched — catches a torn or clobbered plan file"
  )
  func planSetWritesWholeFiles() async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    _ = try await repo.claim(
      AuthorityRepository.planA, AuthorityRepository.alice, design: AuthorityRepository.designA,
      in: repo.main)
    let plan = try repo.layout.plan(AuthorityRepository.planA)
    let resumes = (0..<8).map { "resume \($0)" }

    let statuses = try await withThrowingTaskGroup(of: Int32?.self) { group in
      for resume in resumes {
        group.addTask {
          try await repo.swiftgate(
            [
              "plan", "set", AuthorityRepository.planA, "--session", AuthorityRepository.alice,
              "--resume", resume,
            ], in: repo.linked
          ).exit
        }
      }
      group.addTask {
        for _ in 0..<400 {
          let data = try #require(repo.contents(plan.planFile))
          _ = try PlanFileJSON.decode(data)
        }
        return 0
      }
      return try await group.reduce(into: [Int32?]()) { $0.append($1) }
    }

    #expect(statuses.allSatisfy { $0 == 0 }, "\(statuses)")
    #expect(resumes.contains(try repo.planFile(AuthorityRepository.planA).resume))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: plan.directory).sorted() == [
        "orchestrator.lock", "plan.json",
      ])

    let malformed = Data("{ not json".utf8)
    try malformed.write(to: URL(filePath: plan.planFile))
    let blocked = try await repo.swiftgate(
      [
        "plan", "set", AuthorityRepository.planA, "--session", AuthorityRepository.alice,
        "--tier", "deep",
      ], in: repo.main)
    #expect(blocked.exit == 2, "\(blocked.stdout)")
    #expect(repo.contents(plan.planFile) == malformed)
  }

  /// Every build command that writes plan state, spelled as the build skill runs it.
  static let buildVerbs: [(verb: String, arguments: String)] = [
    ("ledger set", "\(AuthorityRepository.planA) fetch done"),
    ("build start", "\(AuthorityRepository.planA) --preset default"),
    ("build finish", AuthorityRepository.planA),
    ("worktree create", "\(AuthorityRepository.planA) fetch"),
    ("build merge", "\(AuthorityRepository.planA) fetch"),
    ("build cutoff", AuthorityRepository.planA),
  ]

  @Test(
    "each build command that writes plan state is denied to a subagent even with its own session and to a foreign or non-literal --session, and passes for the session's own call — catches a build worker moving its own task or starting a run",
    arguments: buildVerbs)
  func buildVerbsActOnlyAsTheCallingSession(verb: String, arguments: String) async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    let own = AuthorityRepository.alice
    let command = "swiftgate \(verb) \(arguments)"

    let subagent = try await repo.hookDecision(
      "\(command) --session \(own)", session: own, subagent: true)
    #expect(subagent.decision == "deny", "\(verb)")
    #expect(subagent.reason?.contains("orchestrator") == true, "\(subagent.reason ?? "")")
    #expect(subagent.reason?.contains("task result") == true, "\(subagent.reason ?? "")")
    #expect(subagent.reason?.contains("design-conflict") == false, "\(subagent.reason ?? "")")

    for foreign in [
      "\(command) --session \(AuthorityRepository.bob)",
      "\(command) --session=\(AuthorityRepository.bob)",
      "\(command) --session \(own) --session \(AuthorityRepository.bob)",
      "\(command) --session \"$SESSION\"",
      "swift run swiftgate \(verb) \(arguments) --session \(AuthorityRepository.bob)",
    ] {
      #expect(try await repo.hookDecision(foreign, session: own).decision == "deny", "\(foreign)")
    }

    for allowed in ["\(command) --session \(own)", "\(command) --session=\(own)"] {
      let decision = try await repo.hookDecision(allowed, session: own)
      #expect(decision.decision == nil, "\(allowed): \(decision.reason ?? "")")
    }
  }

  @Test(
    "`build merge --undo` and `--fix` stay session-only: denied to a subagent and to a foreign --session, allowed for the session's own call, because spec §8.3 has the executor reset main after a red merge gate — catches a fixer or worker resetting main, or the reset shut off from the orchestrator",
    arguments: ["--undo", "--fix"])
  func buildMergeUndoAndFixActOnlyAsTheCallingSession(flag: String) async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    let own = AuthorityRepository.alice
    let command = "swiftgate build merge \(AuthorityRepository.planA) fetch \(flag)"

    let subagent = try await repo.hookDecision(
      "\(command) --session \(own) --json", session: own, subagent: true)
    #expect(subagent.decision == "deny", "\(flag)")
    #expect(subagent.reason?.contains("task result") == true, "\(subagent.reason ?? "")")

    let foreign = try await repo.hookDecision(
      "\(command) --session \(AuthorityRepository.bob) --json", session: own)
    #expect(foreign.decision == "deny", "\(flag)")

    let allowed = try await repo.hookDecision("\(command) --session \(own) --json", session: own)
    #expect(allowed.decision == nil, "\(flag): \(allowed.reason ?? "")")
  }

  @Test(
    "a subagent's `plan set` is still denied with the plan-verb message, word for word — catches the build-verb wording leaking onto claim, release, set and index"
  )
  func planVerbKeepsItsMessage() async throws {
    let repo = try await AuthorityRepository()
    defer { repo.remove() }
    let own = AuthorityRepository.alice

    let denied = try await repo.hookDecision(
      "swiftgate plan set \(AuthorityRepository.planA) --resume x --session \(own)", session: own,
      subagent: true)

    #expect(denied.decision == "deny")
    #expect(
      denied.reason
        == "swiftgate \(EditGuard.planStateRuleID): a subagent never runs `swiftgate plan set`: "
        + "claiming, releasing and indexing a plan belong to the main session that orchestrates "
        + "it. Report `design-conflict` or `needs-replan` to it instead. "
        + GuardViolation.commandNotRunNote)
  }
}
