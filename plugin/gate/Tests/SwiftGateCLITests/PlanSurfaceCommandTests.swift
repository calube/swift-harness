import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository on `main` with 1 commit and its own `.git` common dir, holding a
/// spec-page plan claimed by ``session``. Gate runs are recorded by the real ``GateRun`` driver at
/// the repository's real HEAD, and the page and spec are the captured task-status pair.
private struct SurfaceRepo {
  static let slug = "2026-09-28-task-status"
  static let session = "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f"
  static let branch = "surface/task-status"
  static let clean = "func feature() -> Int {\n  0\n}\n"
  static let behaviour = "func feature() -> Int {\n  40 + 2\n}\n"
  static let preset = "fast"

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ])

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-plan-surface-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources/App"), withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try Data(".harness/\n".utf8).write(to: root.appending(path: ".gitignore"))
    try await commit("Sources/App/App.swift", "func existing() -> Int {\n  1\n}\n", "base")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  var liveGit: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  static func preset(mergeGate: CheckTier) -> BuildPreset {
    BuildPreset(
      designTier: .none, maxParallel: 2, review: .gate, taskGate: .tier(.push),
      mergeGate: mergeGate, workerModel: .opus, timeBudgetMin: 0, stopStartsBeforeMin: 0,
      onDesignConflict: .block)
  }

  func context(mergeGate: CheckTier = .push) -> PlanSurfaceContext {
    PlanSurfaceContext(
      root: root, git: liveGit,
      branches: LiveSprintBranches(runner: runner, repositoryRoot: root.path),
      surfaceReader: LiveSurfaceCommitReader(runner: runner, repositoryRoot: root.path),
      presets: [Self.preset: Self.preset(mergeGate: mergeGate)])
  }

  func layout() async throws -> PlanStateLayout {
    try PlanStateLayout(commonDirectory: try await liveGit.commonDirectory())
  }

  func planFilePath() async throws -> String { try await layout().plan(Self.slug).planFile }

  func pagePath() async throws -> String {
    try await layout().plan(Self.slug).directory + "/" + PlanFile.SpecPageSource.fileName
  }

  func planFile() async throws -> PlanFile {
    try PlanFileJSON.decode(
      try #require(FileManager.default.contents(atPath: try await planFilePath())))
  }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @discardableResult
  func commit(_ path: String, _ text: String, _ message: String) async throws -> String {
    try Data(text.utf8).write(to: root.appending(path: path))
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
    return try await git("rev-parse", "HEAD")
  }

  func sha(_ ref: String) async throws -> String { try await git("rev-parse", ref) }

  /// Claims the plan as a spec-page plan, writes the captured page and, when `confirm`, confirms
  /// it by its spec quotes.
  func claimed(confirm: Bool = true) async throws {
    let claim = await PlanLockRun.claim(
      slug: Self.slug, session: Self.session, specPage: true, root: root, git: liveGit)
    try #require(claim.status == .claimed, "\(claim.message)")
    try PlanIndex(plans: []).encode().write(to: URL(filePath: try await layout().indexFile))
    try Data(try Fixture.text("spec-page/task-status.page.txt").utf8)
      .write(to: URL(filePath: try await pagePath()))
    guard confirm else { return }
    let confirmed = await PlanConfirmRun.run(
      slug: Self.slug, session: Self.session, by: "spec-quotes",
      specPath: Fixture.directory.appending(path: "spec-page/task-status.spec.txt").path,
      git: liveGit)
    try #require(confirmed.status == .confirmed, "\(confirmed.message)")
  }

  /// Commits `text` as the surface on ``branch`` from `main` and returns its sha.
  func surface(_ text: String = Self.clean) async throws -> String {
    try await git("switch", "-q", "-c", Self.branch)
    return try await commit("Sources/App/Feature.swift", text, "surface")
  }

  /// Records a gate run at the current HEAD through the real run driver and returns its id.
  func gate(_ command: String = "check push", _ verdict: Verdict = .green) async throws -> String {
    let parts = GateRunParts(
      tiers: [try TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 1, testCounts: nil)]
    )
    var captured: String?
    do {
      try await GateRun.execute(
        root: root, format: .json, command: command, git: liveGit
      ) { context in
        captured = context.runID
        return parts
      }
    } catch is ExitCode {
      // A RED or BLOCKED run exits non-zero after recording itself.
    }
    return try #require(captured)
  }

  func run(
    _ commit: String, gate: String, session: String? = Self.session, preset: String = Self.preset,
    mergeGate: CheckTier = .push
  ) async -> PlanSurfaceReport {
    await PlanSurfaceRun.run(
      slug: Self.slug, commit: commit, gate: gate, session: session, preset: preset,
      context: context(mergeGate: mergeGate))
  }

  /// `main`'s sha and plan.json's bytes, to show a refusal moved and wrote nothing.
  func state() async throws -> [String?] {
    [
      try await sha("main"),
      FileManager.default.contents(atPath: try await planFilePath()).map {
        String(decoding: $0, as: UTF8.self)
      },
    ]
  }
}

@Suite("plan surface lands a spec-page plan's surface on main")
struct PlanSurfaceCommandTests {
  /// Asserts a refusal: exit 1, the rule, and nothing moved or written.
  private func expectRefused(
    _ report: PlanSurfaceReport, _ rule: PlanSurfaceRule, _ repo: SurfaceRepo, before: [String?],
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    #expect(report.status == .refused, "\(report.message)", sourceLocation: sourceLocation)
    #expect(report.rule == rule, "\(report.message)", sourceLocation: sourceLocation)
    #expect(report.verdict.exitCode == 1, sourceLocation: sourceLocation)
    #expect(try await repo.state() == before, sourceLocation: sourceLocation)
  }

  @Test(
    "a clean surface on main's HEAD with a green push gate at it fast-forwards main and records the sha — catches a surface that lands without moving main, or moves main without being recorded"
  )
  func happyPathMovesMainAndRecords() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let surface = try await repo.surface()
    let gate = try await repo.gate()

    let report = await repo.run(surface, gate: gate)

    #expect(report.status == .recorded, "\(report.message)")
    #expect(report.verdict.exitCode == 0)
    #expect(report.surfaceCommit == surface)
    #expect(try await repo.sha("main") == surface)
    #expect(try await repo.git("rev-list", "--merges", "--count", "main") == "0")
    #expect(try await repo.planFile().surfaceCommit == surface)
    #expect(try await repo.planFile().specPageSource?.approval != nil)
  }

  @Test(
    "a surface whose body holds behaviour is refused as plan-surface.behaviour, naming the file — catches a surface landing on main without surface-check"
  )
  func behaviourRefused() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let surface = try await repo.surface(SurfaceRepo.behaviour)
    let gate = try await repo.gate()
    let before = try await repo.state()

    let report = await repo.run(surface, gate: gate)

    try await expectRefused(report, .behaviour, repo, before: before)
    #expect(report.message.contains("Sources/App/Feature.swift"), "\(report.message)")
    #expect(report.findings.contains { $0.ruleID == SurfaceCheck.behaviourRuleID })
  }

  @Test(
    "a gate run at another commit than the surface is refused as plan-surface.gate-stale — catches a green gate on main standing in for the surface's own"
  )
  func staleGateRefused() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let onMain = try await repo.gate()
    let surface = try await repo.surface()
    let before = try await repo.state()

    let report = await repo.run(surface, gate: onMain)

    try await expectRefused(report, .gateStale, repo, before: before)
    #expect(report.message.contains(surface), "\(report.message)")
  }

  @Test(
    "a RED or BLOCKED gate at the surface is refused as plan-surface.gate-red — catches main moving to a surface its merge gate failed"
  )
  func redGateRefused() async throws {
    for verdict in [Verdict.red, .blocked] {
      let repo = try await SurfaceRepo()
      defer { repo.remove() }
      try await repo.claimed()
      let surface = try await repo.surface()
      let gate = try await repo.gate("check push", verdict)
      let before = try await repo.state()

      let report = await repo.run(surface, gate: gate)

      try await expectRefused(report, .gateRed, repo, before: before)
      #expect(report.message.contains(verdict.rawValue), "\(report.message)")
    }
  }

  @Test(
    "a gate below the preset's merge_gate is refused as plan-surface.gate-tier, and one at or above it passes — catches a fast gate standing in for the merge gate"
  )
  func gateTierRefused() async throws {
    for (command, mergeGate, refused) in [
      ("check fast", CheckTier.push, true), ("check push", .ready, true),
      ("check ready", .push, false),
    ] {
      let repo = try await SurfaceRepo()
      defer { repo.remove() }
      try await repo.claimed()
      let surface = try await repo.surface()
      let gate = try await repo.gate(command)
      let before = try await repo.state()

      let report = await repo.run(surface, gate: gate, mergeGate: mergeGate)

      if refused {
        try await expectRefused(report, .gateTier, repo, before: before)
        #expect(report.message.contains(mergeGate.rawValue), "\(report.message)")
        #expect(report.mergeGate == mergeGate)
      } else {
        #expect(report.status == .recorded, "\(report.message)")
      }
    }
  }

  @Test(
    "a gate run id this checkout's history doesn't hold is refused as plan-surface.gate-unknown — catches an invented run id passing"
  )
  func unknownGateRefused() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    _ = try await repo.gate()
    let surface = try await repo.surface()
    let before = try await repo.state()

    let report = await repo.run(surface, gate: "20260928T000000Z-00000000")

    try await expectRefused(report, .gateUnknown, repo, before: before)
  }

  @Test(
    "a surface whose parent isn't main's HEAD is refused as plan-surface.not-on-main — catches main being merged or rebased onto a surface cut from an older main"
  )
  func parentNotMainRefused() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let surface = try await repo.surface()
    let gate = try await repo.gate()
    try await repo.git("switch", "-q", "main")
    try await repo.commit("Sources/App/Other.swift", "func other() {}\n", "main moved")
    try await repo.git("switch", "-q", SurfaceRepo.branch)
    let before = try await repo.state()

    let report = await repo.run(surface, gate: gate)

    try await expectRefused(report, .notOnMain, repo, before: before)
    #expect(report.message.contains(try await repo.sha("main")), "\(report.message)")
  }

  @Test(
    "a page never confirmed, or edited after its confirm, is refused as plan-surface.not-confirmed — catches a surface landing for a page nobody confirmed"
  )
  func unconfirmedPageRefused() async throws {
    for edited in [false, true] {
      let repo = try await SurfaceRepo()
      defer { repo.remove() }
      try await repo.claimed(confirm: edited)
      if edited {
        let path = try await repo.pagePath()
        let page = try String(contentsOf: URL(filePath: path), encoding: .utf8)
        try Data((page + "\nOne more line.\n").utf8).write(to: URL(filePath: path))
      }
      let surface = try await repo.surface()
      let gate = try await repo.gate()
      let before = try await repo.state()

      let report = await repo.run(surface, gate: gate)

      try await expectRefused(report, .notConfirmed, repo, before: before)
      #expect(report.message.contains("plan confirm"), "\(report.message)")
    }
  }

  @Test(
    "a second surface for a plan that recorded one is refused as plan-surface.already-recorded — catches a plan with 2 surfaces its tasks disagree on"
  )
  func secondSurfaceRefused() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let first = try await repo.surface()
    let landed = await repo.run(first, gate: try await repo.gate())
    try #require(landed.status == .recorded, "\(landed.message)")
    let second = try await repo.commit("Sources/App/More.swift", SurfaceRepo.clean, "again")
    let gate = try await repo.gate()
    let before = try await repo.state()

    let report = await repo.run(second, gate: gate)

    try await expectRefused(report, .alreadyRecorded, repo, before: before)
    #expect(report.message.contains(first), "\(report.message)")
  }

  @Test(
    "a worktree with main checked out is refused as plan-surface.main-checked-out — catches a moved ref leaving a checkout's files behind"
  )
  func mainCheckedOutRefused() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let surface = try await repo.surface()
    let gate = try await repo.gate()
    try await repo.git("switch", "-q", "main")
    let before = try await repo.state()

    let report = await repo.run(surface, gate: gate)

    try await expectRefused(report, .mainCheckedOut, repo, before: before)
  }

  @Test(
    "main already at the surface with nothing recorded, as a run that moved main and stopped, records it — catches a retry refused as not-on-main forever"
  )
  func movedButUnrecordedIsRecorded() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let surface = try await repo.surface()
    let gate = try await repo.gate()
    try await repo.git("update-ref", "refs/heads/main", surface)

    let report = await repo.run(surface, gate: gate)

    #expect(report.status == .recorded, "\(report.message)")
    #expect(try await repo.planFile().surfaceCommit == surface)
  }

  @Test(
    "a session without the lock is not-held and exit 1; an unknown preset, a design plan, an unknown commit or an unreadable plan.json exits 2 — each writing nothing"
  )
  func notHeldAndBlocked() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let surface = try await repo.surface()
    let gate = try await repo.gate()
    let before = try await repo.state()

    let other = await repo.run(surface, gate: gate, session: "5e0c7a1b-2d3f-4a6b-8c9d")
    #expect(other.status == .notHeld, "\(other.message)")
    #expect(other.verdict.exitCode == 1)
    #expect(other.holder == SurfaceRepo.session)

    let preset = await repo.run(surface, gate: gate, preset: "nope")
    #expect(preset.status == .blocked, "\(preset.message)")
    #expect(preset.verdict.exitCode == 2)
    #expect(preset.message.contains(SurfaceRepo.preset), "\(preset.message)")

    let unknown = await repo.run("0000000000000000000000000000000000000000", gate: gate)
    #expect(unknown.verdict.exitCode == 2, "\(unknown.message)")

    #expect(try await repo.state() == before)

    try Data("{".utf8).write(to: URL(filePath: try await repo.planFilePath()))
    let unreadable = await repo.run(surface, gate: gate)
    #expect(unreadable.verdict.exitCode == 2, "\(unreadable.message)")
    #expect(try await repo.sha("main") == before[0])

    let design = PlanFile(
      schemaVersion: 1, slug: SurfaceRepo.slug, design: "docs/designs/x.md", designSha: "3f1c",
      approval: nil, clarifyChain: [], tier: .standard, resume: "planned")
    try PlanFileJSON.encode(design).write(to: URL(filePath: try await repo.planFilePath()))
    let designPlan = await repo.run(surface, gate: gate)
    #expect(designPlan.verdict.exitCode == 2, "\(designPlan.message)")
    #expect(designPlan.message.contains("design plan"), "\(designPlan.message)")
    #expect(try await repo.planFile().surfaceCommit == nil)
    #expect(try await repo.sha("main") == before[0])
  }

  @Test(
    "--json prints every key, null when absent, and a refusal's rule id; human output leads with the verdict and rule — catches a key the ship skill reads going missing"
  )
  func jsonKeys() async throws {
    let repo = try await SurfaceRepo()
    defer { repo.remove() }
    try await repo.claimed()
    let surface = try await repo.surface()
    let report = await repo.run(surface, gate: try await repo.gate("check fast"))

    let text = PlanSurfaceRun.render(report, format: .json)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "\(text)")
    #expect(
      Set(object.keys)
        == [
          "command", "plan", "status", "verdict", "rule", "holder", "surfaceCommit", "gate",
          "mergeGate", "findings", "message",
        ])
    #expect(object["command"] as? String == "plan surface")
    #expect(object["status"] as? String == "refused")
    #expect(object["verdict"] as? String == "RED")
    #expect(object["rule"] as? String == "plan-surface.gate-tier")
    #expect(object["surfaceCommit"] as? String == surface)
    #expect(object["mergeGate"] as? String == "push")
    #expect(object["holder"] is NSNull)

    let human = PlanSurfaceRun.render(report, format: .human)
    #expect(human.hasPrefix("plan surface: RED plan-surface.gate-tier"), "\(human)")
  }

  @Test(
    "plan surface parses its documented arguments and resolves to its own leaf — catches a skill calling an unregistered command"
  )
  func registered() async throws {
    let parsed = try await SwiftGate.asyncParseAsRoot([
      "plan", "surface", SurfaceRepo.slug, "abc1234", "--gate", "20260928T000000Z-00000000",
      "--preset", "fast", "--session", "s1", "--json",
    ])
    #expect(type(of: parsed).configuration.commandName == "surface")
  }
}
