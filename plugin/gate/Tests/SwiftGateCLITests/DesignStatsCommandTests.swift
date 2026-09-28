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
    let withoutActuals = LedgerTask(
      id: "queue-core", deps: [], writeSet: ["Sample/Sources/Core/"], gate: .fast,
      tests: ["test-a"], covers: ["test-a"], estLines: 120, status: .pending,
      worktree: "../app-queue-core")
    let withActuals = LedgerTask(
      id: "queue-networking", deps: [], writeSet: ["Sample/Sources/Networking/"], gate: .fast,
      tests: ["test-b"], covers: ["test-b"], estLines: 100, status: .done,
      worktree: "../app-queue-networking", actualLines: 145)
    let ledger = Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: 3,
      tasks: [withoutActuals, withActuals], waves: [["queue-core", "queue-networking"]])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
    let file = PlanFile(
      schemaVersion: 1, slug: "queue-plan", design: Self.design, designSha: nil, approval: nil,
      clarifyChain: [], tier: .standard, resume: "planned")
    try PlanFileJSON.encode(file).write(to: URL(filePath: plan.planFile))

    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: "queue-plan", cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: runner)

    #expect(report.verdict == .green)
    // Without actualLines: excluded, never a fabricated zero error.
    #expect(report.estimateError.excludedTaskIDs == ["queue-core"])
    // With actualLines: included, error = actualLines - estLines = 145 - 100 = 45.
    let included = try #require(
      report.estimateError.perTask.first { $0.id == "queue-networking" })
    #expect(included.error == 45)
    #expect(report.estimateError.meanAbsoluteError == 45.0)
    #expect(report.notes.contains { $0.contains("1 task(s) have no actualLines yet") })
  }

  @Test(
    "with --plan, overhead share is the ledger's critical-path figure the ledger page shows, and the phases figure is reported as non-draft wall share — catches stats reporting a different overhead share than the spec's formula"
  )
  func overheadShareComesFromTheLedger() async throws {
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
    let initialised = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q", "-b", "main"],
        workingDirectory: repo.root.path, timeout: .seconds(30)))
    #expect(initialised.status.isSuccess)

    let liveGit = LiveGit(runner: runner, repositoryRoot: repo.root.path)
    let plan = try PlanStateLayout(commonDirectory: try await liveGit.commonDirectory())
      .plan("queue-plan")
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    func task(_ id: String, deps: [String] = [], estLines: Int) -> LedgerTask {
      LedgerTask(
        id: id, deps: deps, writeSet: ["Sample/Sources/\(id)/"], gate: .fast, tests: [],
        covers: [], estLines: estLines, status: .pending, worktree: "../app-\(id)")
    }
    // Waves [[a, b], [c]]: wall = 200 + 50; the critical path is b alone, 200. Share 0.2.
    let tasks = [
      task("a", estLines: 100), task("b", estLines: 200), task("c", deps: ["a"], estLines: 50),
    ]
    let ledger = Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: tasks,
      waves: [["a", "b"], ["c"]])
    try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))

    let slug = URL(filePath: Self.design).deletingPathExtension().lastPathComponent
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var phases = Data()
    for (phase, wall) in [(DesignPlanPhase.draft, 7_000), (.review, 3_000)] {
      phases.append(
        try encoder.encode(
          PhaseRecord(
            runId: "design-\(slug)", phase: phase, agentRole: nil, tokens: 10, costUSD: nil,
            wallMilliseconds: wall)))
      phases.append(UInt8(ascii: "\n"))
    }
    try repo.write(
      String(decoding: phases, as: UTF8.self),
      at: RunLayout.runDirectory(for: "design-\(slug)") + "phases.jsonl")

    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: "queue-plan", cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: runner)

    #expect(report.verdict == .green)
    let expected = try #require(
      LedgerRender.predictedOverheadShare(tasks: tasks, waves: [["a", "b"], ["c"]]))
    #expect(expected == 0.2)
    let json = try Self.jsonObject(report)
    #expect(json["overheadShare"] as? Double == expected)
    let nonDraft = try #require(json["nonDraftWallShare"] as? [String: Any])
    #expect(nonDraft["value"] as? Double == 0.3)
    let human = DesignStatsRun.render(report, format: .human)
    #expect(human.contains("non-draft wall share: 30.0%"))
    #expect(human.contains("overhead share: 20.0%"))

    let withoutPlan = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: nil, cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: runner)
    #expect(try Self.jsonObject(withoutPlan)["overheadShare"] == nil)
    #expect(withoutPlan.notes.contains { $0.contains("overhead share excluded") })
  }

  @Test(
    "stats reads schema 1 and schema 2 phase lines together and counts unmeasured records apart, never adding them as 0 — catches an unknown token count summed as zero"
  )
  func unmeasuredPhaseRecordsCountedApart() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    let slug = URL(filePath: Self.design).deletingPathExtension().lastPathComponent
    let lines = [
      #"{"schemaVersion":1,"runId":"design-20260925T180000Z","phase":"research","agentRole":"research-lane","lane":"codebase","tokens":48213,"costUSD":null,"wallMilliseconds":212000}"#,
      #"{"agentRole":"research-lane","costUSD":null,"lane":null,"phase":"research","runId":"design-20260928T010000Z","schemaVersion":2,"tokens":null,"unavailable":["output tokens: the Workflow runtime gave this script no budget.spent()"],"wallMilliseconds":90000}"#,
      #"{"agentRole":null,"costUSD":null,"lane":null,"phase":"review","runId":"design-20260928T010000Z","schemaVersion":2,"tokens":null,"unavailable":["output tokens: the Workflow runtime gave this script no budget.spent()"],"wallMilliseconds":30000}"#,
    ]
    try repo.write(
      lines.joined(separator: "\n") + "\n",
      at: RunLayout.runDirectory(for: "design-\(slug)") + "phases.jsonl")

    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: nil, cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: LiveProcessRunner())

    #expect(report.verdict == .green)
    #expect(report.unmeasuredPhaseRecords == 2)
    let research = try #require(report.phaseTotals.first { $0.phase == .research })
    #expect(research.runs == 2)
    #expect(research.tokens == 48_213)
    #expect(research.unmeasuredRuns == 1)
    #expect(research.wallMilliseconds == 302_000)
    let review = try #require(report.phaseTotals.first { $0.phase == .review })
    #expect(review.tokens == nil)
    #expect(review.unmeasuredRuns == 1)
    #expect(report.notes.contains { $0.contains("2 phase record(s)") && $0.contains("unmeasured") })
    let human = DesignStatsRun.render(report, format: .human)
    #expect(human.contains("review: runs=1 tokens=n/a unmeasured=1"))
    let json = try Self.jsonObject(report)
    #expect(json["unmeasuredPhaseRecords"] as? Int == 2)
  }

  @Test(
    "a phase line with an unknown key blocks the report naming its line — catches a closed record read as a real one"
  )
  func unknownPhaseKeyBlocks() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    let slug = URL(filePath: Self.design).deletingPathExtension().lastPathComponent
    let path = try repo.write(
      #"{"schemaVersion":1,"runId":"design-20260925T180000Z","phase":"draft","agentRole":"drafter","tokens":10,"costUSD":null,"wallMilliseconds":5,"model":"opus"}"#
        + "\n",
      at: RunLayout.runDirectory(for: "design-\(slug)") + "phases.jsonl")
    let report = await DesignStatsRun.run(
      options: .init(design: Self.design, plan: nil, cacheHome: try repo.freshCacheHome()),
      root: repo.root, runner: LiveProcessRunner())
    #expect(report.verdict == .blocked)
    #expect(report.message.contains("\(path):1"))
  }

  private static func jsonObject(_ report: DesignStatsReport) throws -> [String: Any] {
    let json = DesignStatsRun.render(report, format: .json)
    return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }
}
