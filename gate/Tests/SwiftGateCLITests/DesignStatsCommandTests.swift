import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

/// `stats --design` reads every §10/§12 input from a real repository: claims, amendments,
/// review-log and phases files, the probes directory, the evidence reuse cache and (with
/// `--plan`) the shared ledger. Every fixture lives under a fresh temp directory (worker-brief
/// pitfall 7) — never this checkout's own `docs/` or real `$HOME`, and never this checkout's git
/// common dir.
@Suite("swiftgate stats --design")
struct DesignStatsCommandTests {
  private struct Repository {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(
          path: "swiftgate-design-stats-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ contents: String, at relativePath: String) throws -> String {
      let url = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
      return relativePath
    }

    func freshCacheHome() throws -> String {
      try write("", at: "cache-home/.keep")
      return root.appending(path: "cache-home").path
    }
  }

  private static let design = "docs/ordering/designs/offline-queue.md"
  private static let layout = EvidenceLayout(designDocPath: design)

  private static func claim(id: String, lane: String, status: Claim.Status) -> Claim {
    Claim(
      id: id, lane: lane, text: "some fact",
      citation: Citation(kind: .file, loc: "Sources/Widget.swift:L1-L1", pin: nil, quote: "q"),
      status: status)
  }

  @Test(
    "no claims, amendments, review-log, phases, probes, plan or cache: exits green with a note per missing input, never a fabricated zero"
  )
  func allInputsMissingProducesNotes() async throws {
    let repo = try Repository()
    defer { repo.remove() }

    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: nil, cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: LiveProcessRunner())

    #expect(report.verdict == .green)
    #expect(report.notes.contains { $0.contains("no claims file") })
    #expect(report.notes.contains { $0.contains("no amendments file") })
    #expect(report.notes.contains { $0.contains("no review-log file") })
    #expect(report.notes.contains { $0.contains("no phases file") })
    #expect(report.notes.contains { $0.contains("no probes directory") })
    #expect(report.notes.contains { $0.contains("no --plan given") })
    #expect(report.notes.contains { $0.contains("no evidence cache") })
    #expect(report.claimLanes.allSatisfy { $0.total == 0 })
    #expect(report.escapeRate.value == nil)
  }

  @Test("claims, amendments, review-log, phases and probes feed the real §10/§12 metrics")
  func greenPathComputesRealMetrics() async throws {
    let repo = try Repository()
    defer { repo.remove() }

    let supported = Self.claim(id: "ev-cancel-effect-works", lane: "packages", status: .supported)
    let refuted = Self.claim(id: "ev-retry-caps-at-30s", lane: "codebase", status: .refuted)
    try repo.write(
      String(decoding: try ClaimJSON.encodeLine(supported), as: UTF8.self)
        + String(decoding: try ClaimJSON.encodeLine(refuted), as: UTF8.self),
      at: Self.layout.claimsFile)

    let amendment = Amendment(
      title: "narrower retry window", at: Date(timeIntervalSince1970: 0), class: .amend,
      fromSha: "aaa", toSha: "bbb", changedIds: ["ev-cancel-effect-works"], newClaims: [],
      trigger: "design-conflict", review: nil, approval: nil)
    try repo.write(
      String(decoding: try AmendmentJSON.encodeLine(amendment), as: UTF8.self),
      at: Self.layout.amendmentsFile)

    let reviewLogRecord = ReviewLogRecord(
      findingId: "finding-decision-contradicts-evidence", reviewer: "evidence-auditor",
      disposition: .accepted, reason: "the cited quote doesn't support the decision")
    try repo.write(
      String(decoding: try ReviewLogJSON.encodeLine(reviewLogRecord), as: UTF8.self),
      at: Self.layout.root + "/review-log.jsonl")

    let slug = URL(filePath: Self.design).deletingPathExtension().lastPathComponent
    let phaseRecord = PhaseRecord(
      runId: "design-\(slug)", phase: .draft, agentRole: .drafter, tokens: 4_000, costUSD: 0.5,
      wallMilliseconds: 10_000)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var phasesData = try encoder.encode(phaseRecord)
    phasesData.append(UInt8(ascii: "\n"))
    try repo.write(
      String(decoding: phasesData, as: UTF8.self),
      at: RunLayout.runDirectory(for: "design-\(slug)") + "phases.jsonl")

    let probe = ProbeVerdictRecord(
      claimId: "ev-cancel-effect-works", verdict: .fail, diagnostics: [], pins: [:],
      sdk: "iphonesimulator26.2")
    try repo.write(
      String(decoding: try ProbeVerdictRecord.encode(probe), as: UTF8.self),
      at: Self.layout.probesDirectory + "/Probe_ev-cancel-effect-works.verdict.json")

    let cacheHome = try repo.freshCacheHome()
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let cachedClaim = try ReusableClaim(
      Claim(
        id: "ev-cache-hit", lane: "packages", text: "cached fact",
        citation: Citation(
          kind: .file, loc: ".build/checkouts/tca/Sources/Widget.swift:L1-L1",
          pin: "tca@1.0.0", quote: "q"),
        status: .supported))
    try await store.record(cachedClaim, origin: .researchLane)
    try await store.markReused(cachedClaim)

    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: nil, cacheHome: cacheHome), root: repo.root,
      runner: LiveProcessRunner())

    #expect(report.verdict == .green)

    let packages = try #require(report.claimLanes.first { $0.lane == .packages })
    #expect(packages.total == 1)
    #expect(packages.refuteRate.value == 0.0)
    let codebase = try #require(report.claimLanes.first { $0.lane == .codebase })
    #expect(codebase.refuteRate.value == 1.0)

    // The supported claim's id is named in an `amend` amendment, so it escaped.
    #expect(report.escapeRate.value == 1.0)

    let precision = try #require(
      report.reviewerPrecision.first { $0.reviewer == "evidence-auditor" })
    #expect(precision.accepted == 1)
    #expect(precision.precision.value == 1.0)

    let draft = try #require(report.phaseTotals.first { $0.phase == .draft })
    #expect(draft.tokens == 4_000)
    let drafter = try #require(report.agentTotals.first { $0.agentRole == .drafter })
    #expect(drafter.tokens == 4_000)

    #expect(report.probes.total == 1)
    #expect(report.probes.failed == 1)

    #expect(report.cache.reuses == 1)
    #expect(report.cache.entries == 1)
  }

  @Test(
    "a torn claims.jsonl line blocks the whole report, naming its file and 1-based line — catches a metric silently built over a partly-unread file"
  )
  func malformedClaimsLineBlocks() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    let good = try ClaimJSON.encodeLine(
      Self.claim(id: "ev-a-b-c", lane: "packages", status: .supported))
    var data = good
    data.append(contentsOf: Array("{not json}\n".utf8))
    try repo.write(String(decoding: data, as: UTF8.self), at: Self.layout.claimsFile)

    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: nil, cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: LiveProcessRunner())

    #expect(report.verdict == .blocked)
    #expect(report.message.contains("\(Self.layout.claimsFile):2"))
  }

  @Test(
    "with --plan and a real ledger, tasks are named excluded from estimate error rather than silently reported as zero error"
  )
  func planLedgerNamesTasksExcluded() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    let environment: [String: String] = [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
      "HOME": FileManager.default.temporaryDirectory.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
      "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ]
    let runner = LiveProcessRunner(baseEnvironment: environment)
    func git(_ arguments: String...) async throws {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: repo.root.path,
          timeout: .seconds(30)))
      #expect(output.status.isSuccess)
    }
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try repo.write("placeholder\n", at: "README.md")
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "init")

    let liveGit = LiveGit(runner: runner, repositoryRoot: repo.root.path)
    let layout = try PlanStateLayout(commonDirectory: try await liveGit.commonDirectory())
    let plan = try layout.plan("queue-plan")
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    let task = LedgerTask(
      id: "queue-core", deps: [], writeSet: ["Sample/Sources/Core/"], gate: .fast,
      tests: ["test-a"], covers: ["test-a"], estLines: 120, status: .pending,
      worktree: "../app-queue-core")
    let ledger = Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: [task], waves: [["queue-core"]])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
    let file = PlanFile(
      schemaVersion: 1, slug: "queue-plan", design: Self.design, designSha: nil, approval: nil,
      clarifyChain: [], tier: "standard", resume: "planned")
    try PlanFileJSON.encode(file).write(to: URL(filePath: plan.planFile))

    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: "queue-plan", cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: runner)

    #expect(report.verdict == .green)
    #expect(report.estimateError.excludedTaskIDs == ["queue-core"])
    #expect(report.estimateError.meanAbsoluteError == nil)
    #expect(report.notes.contains { $0.contains("actual line counts aren't tracked yet") })
  }
}
