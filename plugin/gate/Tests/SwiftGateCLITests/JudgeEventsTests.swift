import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Every route that judges changed tests writes 1 `judge.decision` per subject and question, and
/// every backend call under it a `judge.call`, so a run's judgements can be audited afterwards.
@Suite("judge events: what each judgement call wrote")
struct JudgeEventsTests {
  typealias Steps = CheckJudgeStepTests
  static let runID = "20260930T120000Z-0000abcd"
  static let head = "c0ffee"

  struct Judged {
    let findings: [Finding]
    let log: MemoryEventLog
    let failures: HarnessEventFailures

    func decisions(_ question: String) -> [(event: HarnessEvent, decision: JudgeDecisionEvent)] {
      log.events.compactMap {
        guard case .judgeDecision(let decision) = $0.payload, decision.question == question
        else { return nil }
        return ($0, decision)
      }
    }

    func calls(_ role: JudgeCallRole) -> [(event: HarnessEvent, call: JudgeCallEvent)] {
      log.events.compactMap {
        guard case .judgeCall(let call) = $0.payload, call.role == role else { return nil }
        return ($0, call)
      }
    }
  }

  static func judged(
    judge: FakeJudge, config: String = Steps.jevConfig, reasonJudge: (any Judge)? = nil,
    ready: Bool = true, log: MemoryEventLog = MemoryEventLog(), secrets: [String] = []
  ) async throws -> Judged {
    let setup = try JudgeCommandsTests.Setup(config: config)
    defer { setup.repository.remove() }
    let git = FakeGit(
      changed: [JudgeCommandsTests.testFile, JudgeCommandsTests.sourceFile], mergeBase: "base",
      addedSince: [AddedLines(path: JudgeCommandsTests.testFile, ranges: [1...15])],
      revisions: ["HEAD": head])
    let scope = JudgeEventScope.testing(log, secrets: secrets)
    let findings = await TestJudgeCheck.run(
      ChangedTestChecks.Environment(
        root: setup.repository.root, git: git, swiftPM: FakeSwiftPM(serving: []),
        scratch: FakeScratchWorktrees(root: setup.repository.root),
        scratchSwiftPM: { _ in FakeSwiftPM(serving: []) }),
      graph: try ModuleGraph(packages: [try ProbeRepository.manifest()]),
      config: try setup.config(), base: "origin/main", atReadyTier: ready,
      dependencies: TestJudgeCheck.Dependencies(
        makeJudge: { _ in judge },
        diff: FakeDiff(
          text:
            "diff --git a/\(JudgeCommandsTests.sourceFile) b/\(JudgeCommandsTests.sourceFile)\n+func doubled() {}\n"
        ), reasonJudge: reasonJudge, secrets: secrets, events: scope),
      runID: runID)
    return Judged(findings: findings, log: log, failures: scope.failures)
  }

  @Test(
    "a fake Jev at 0.5 escalates fails-if-broken to a fake Claude: the decision is escalated with both distributions, decided by claude/sonnet with Claude's reason, and the escalation call's parent is the Jev call — catches an escalation the log can't show"
  )
  func cascadeEscalationIsRecorded() async throws {
    let judged = try await Self.judged(
      judge: Steps.judge(Steps.jev, flagged: 0.5, rationale: nil),
      reasonJudge: Steps.reasonJudge(
        flagged: 0.95, rationale: "the doubled value is never compared", asked: Steps.Asked()))

    let decisions = judged.decisions("fails-if-broken")
    #expect(!decisions.isEmpty)
    let answers = judged.calls(.answer)
    for (event, decision) in decisions {
      #expect(event.runID == Self.runID)
      #expect(event.head == Self.head)
      #expect(event.base == "base")
      #expect(event.source.route == .judgeTestsReady)
      #expect(decision.backend == .jev)
      #expect(decision.escalated)
      #expect(decision.inBand == true)
      #expect(decision.distribution == ["yes": 0.5, "no": 0.5])
      #expect(decision.p == 0.5)
      #expect(decision.escalation?.distribution?["no"] == 0.95)
      #expect(decision.escalation?.p == 0.95)
      #expect(decision.escalation?.model == "sonnet")
      #expect(decision.decidedBy == "claude/sonnet")
      #expect(decision.decision == .block)
      #expect(decision.severity == .major)
      #expect(decision.reasonSource == .claude)
      #expect(decision.reason == "the doubled value is never compared")
      #expect(decision.questionSet == "test-quality@2-jev")
      #expect(decision.blocking)
      #expect(Set(decision.calls.map(\.role)) == [.answer, .escalation])
    }
    let escalations = judged.calls(.escalation)
    #expect(escalations.count == answers.count)
    for (event, call) in escalations {
      #expect(call.backend == .claude)
      let parent = try #require(answers.first { $0.event.eventID == event.parentID })
      #expect(parent.call.subject.id == call.subject.id)
      #expect(parent.call.backend == .jev)
    }
  }

  @Test(
    "a Jev block records Claude as its reason's source, and the reason call's parent is that decision — catches a Jev block whose reason the log can't trace"
  )
  func jevBlockReasonIsClaudes() async throws {
    let judged = try await Self.judged(
      judge: Steps.judge(Steps.jev, flagged: ["fails-if-broken": 0.95], otherwise: 0.1),
      reasonJudge: Steps.reasonJudge(
        flagged: 0.1, rationale: "the assertion compares the doubled value", asked: Steps.Asked()))

    let decisions = judged.decisions("fails-if-broken")
    #expect(!decisions.isEmpty)
    let reasons = judged.calls(.reason)
    for (event, decision) in decisions {
      #expect(decision.decision == .block)
      #expect(!decision.escalated)
      #expect(decision.inBand == false)
      #expect(decision.band == JudgeCascade.Band(lower: 0.4, upper: 0.9))
      #expect(decision.decidedBy == "jev/\(Steps.pin)")
      #expect(decision.reasonSource == .claude)
      #expect(decision.reason == "the assertion compares the doubled value")
      #expect(
        decision.thresholds == JudgeEventThresholds(JudgeThresholds(advisory: 0.6, block: 0.9)))
      let reason = try #require(reasons.first { $0.event.parentID == event.eventID })
      #expect(reason.call.questions.map(\.id) == ["fails-if-broken"])
      #expect(decision.calls.contains { $0.eventID == reason.event.eventID })
    }
    let passes = judged.decisions("asserts-implementation")
    #expect(!passes.isEmpty)
    #expect(
      passes.allSatisfy { $0.decision.decision == .pass && $0.decision.reasonSource == .none })
  }

  @Test(
    "when Claude can't write a Jev block's reason, the decision's reason is the template with the error, and the key the failure echoes reaches no event — catches a missing reason logged as Claude's, or the key in the log"
  )
  func failedReasonIsTemplate() async throws {
    let key = "tsk-sentinel-cli-91b2"
    let judged = try await Self.judged(
      judge: Steps.judge(Steps.jev, flagged: ["fails-if-broken": 0.99], otherwise: 0.01),
      reasonJudge: Steps.failingReasonJudge(
        .backend("overloaded; saw \(key)"), asked: Steps.Asked()),
      secrets: [key])

    let decisions = judged.decisions("fails-if-broken")
    #expect(!decisions.isEmpty)
    for (_, decision) in decisions {
      #expect(decision.decision == .block)
      #expect(decision.reasonSource == .template)
      #expect(decision.reason?.hasPrefix(JudgeBlockReason.missingPrefix) == true)
      #expect(decision.reasonError?.kind == .backend)
    }
    #expect(judged.calls(.reason).allSatisfy { $0.call.error?.kind == .backend })
    let text = try judged.log.events.map {
      String(decoding: try HarnessEventJSON.encodeLine($0), as: UTF8.self)
    }.joined()
    #expect(text.contains("overloaded"))
    #expect(!text.contains(key))
  }

  @Test(
    "a Jev that fails records an error decision for every question with the error's kind, beside the unchanged not-run note — catches a judge outage leaving no trace in the log"
  )
  func failedJevIsErrorDecisions() async throws {
    let judged = try await Self.judged(
      judge: FakeJudge(identity: Steps.jev) { _, _ throws(JudgeError) in throw .backend("500") })

    #expect(judged.findings.map(\.ruleID) == [TestJudgeCheck.notRunRuleID])
    let decisions = judged.log.decisions
    #expect(!decisions.isEmpty)
    #expect(decisions.count % JudgeQuestionSet.testsJev.questions.count == 0)
    #expect(decisions.allSatisfy { $0.decision == .error && $0.error?.kind == .backend })
  }

  @Test(
    "a log that refuses every write leaves the findings as they were and adds 1 nit naming the path — catches a lost audit log flipping the verdict, or going unreported"
  )
  func unwritableLogIsNit() async throws {
    let judge = Steps.judge(Steps.claude, flagged: 0.95, rationale: "r")
    let path = ".harness/events/judge.jsonl"
    let written = try await Self.judged(judge: judge, config: JudgeCommandsTests.enabled)
    let refused = try await Self.judged(
      judge: judge, config: JudgeCommandsTests.enabled,
      log: MemoryEventLog(failing: HarnessEventWriteError(path: path, reason: "read-only")))

    let nits = refused.findings.filter { $0.ruleID == TestJudgeCheck.eventsUnwrittenRuleID }
    #expect(nits.count == 1)
    #expect(nits.first?.severity == .nit)
    #expect(nits.first?.message.contains(path) == true)
    #expect(
      refused.findings.filter { $0.ruleID != TestJudgeCheck.eventsUnwrittenRuleID }
        == written.findings)
    #expect(!written.log.decisions.isEmpty)
    #expect(written.findings.allSatisfy { $0.ruleID != TestJudgeCheck.eventsUnwrittenRuleID })
  }

  @Test(
    "without --ready the route is judge-tests and a confident block is advisory — catches events from the advisory route read as ready blocks"
  )
  func advisoryRoute() async throws {
    let judged = try await Self.judged(
      judge: Steps.judge(Steps.claude, flagged: 0.95, rationale: "r"),
      config: JudgeCommandsTests.enabled, ready: false)

    #expect(!judged.log.decisions.isEmpty)
    #expect(judged.log.events.allSatisfy { $0.source.route == .judgeTests })
    let decisions = judged.decisions("fails-if-broken").map(\.decision)
    #expect(decisions.allSatisfy { $0.decision == .advisory && !$0.atReadyTier })
    #expect(decisions.allSatisfy { $0.reasonSource == .claude && $0.band == nil && !$0.escalated })
  }

  @Test(
    "the commit comment judge records its calls and decisions under the comment-hook route from the PreToolUse hook — catches the hook's judge missing from the audit log"
  )
  func commentHookIsRecorded() async throws {
    let log = MemoryEventLog()
    let repository = try ProbeRepository(config: JevCommitCommentJudgeTests.config)
    defer { repository.remove() }
    let reply = try FakeHTTPTransport.captured("comments")
    var judge = ConfiguredCommitCommentJudge(
      makeJudge: { config, root in
        ConfiguredCommitCommentJudge.judge(
          for: config, root: root, transport: FakeHTTPTransport([reply]),
          environment: JevCommitCommentJudgeTests.keyed, clock: FakeRetryClock())
      },
      git: { _ in JevCommitCommentJudgeTests.git() })
    judge.events = { _ in JudgeEventScope.testing(log) }

    _ = await judge.review(root: repository.root)

    #expect(log.calls.count == 1)
    #expect(log.decisions.map(\.question).sorted() == ["loses-fact", "right-size"])
    #expect(
      log.events.allSatisfy {
        $0.source == HarnessEventSource(route: .commentHook, hook: .preToolUse)
      })
  }

  // MARK: - judge events

  static func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-judge-events-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  @Test(
    "judge events reads the shared log and 1 run's copy, prints decisions and blocks with reasons, and exits 0 — catches a run's judgements unreadable after the fact"
  )
  func eventsReportReadsLog() async throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root)
    let judged = try await Self.judged(
      judge: Steps.judge(Steps.jev, flagged: ["fails-if-broken": 0.95], otherwise: 0.1),
      reasonJudge: Steps.reasonJudge(
        flagged: 0.1, rationale: "never compared", asked: Steps.Asked()))
    for event in judged.log.events { try files.append(event) }

    let shared = JudgeEventsReport.make(
      reader: files, runID: nil, filter: JudgeEventFilter(), json: false)
    let run = JudgeEventsReport.make(
      reader: files, runID: Self.runID, filter: JudgeEventFilter(), json: true)

    #expect(shared.status == 0)
    #expect(shared.stdout.contains("fails-if-broken"))
    #expect(shared.stdout.contains("never compared"))
    #expect(run.status == 0)
    let summary = try JSONDecoder().decode(JudgeEventSummary.self, from: Data(run.stdout.utf8))
    #expect(summary.events == judged.log.events.count)
    #expect(summary.blocks.allSatisfy { $0.reason == "never compared" })
    #expect(!summary.blocks.isEmpty)
  }

  @Test(
    "judge events exits 2 naming an unknown key, and reports a torn last line with exit 0 — catches a log from a newer writer misread, or a write in flight failing the reader"
  )
  func eventsReportStrictness() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = HarnessEventFiles(root: root)
    let directory = root.appending(path: RunLayout.eventsDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = root.appending(path: RunLayout.eventsFile(.judge))
    let line = try HarnessEventJSON.encodeLine(
      HarnessEvent(
        eventID: "d-1", time: Date(timeIntervalSince1970: 1_790_000_000),
        source: HarnessEventSource(route: .judgeTests),
        payload: .judgeDecision(
          HarnessEventTestsSupport.decision())))

    try (line + Data("{\"schemaVersion\":1,\"even".utf8)).write(to: file)
    let torn = JudgeEventsReport.make(
      reader: files, runID: nil, filter: JudgeEventFilter(), json: false)
    try Data(String(decoding: line, as: UTF8.self).replacing("{", with: "{\"mystery\":0,").utf8)
      .write(to: file)
    let unknown = JudgeEventsReport.make(
      reader: files, runID: nil, filter: JudgeEventFilter(), json: false)

    #expect(torn.status == 0)
    #expect(torn.stdout.contains("torn"))
    #expect(unknown.status == 2)
    #expect(unknown.stderr.contains("mystery"))
    #expect(unknown.stderr.contains(file.lastPathComponent))
  }

  @Test(
    "judge events reads a log the writer wrote before segments existed, before and after a write seals it, and prints Claude's long reasons — catches today's audit log unreadable after rotation"
  )
  func eventsReportReadsLegacyLog() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = try Fixture.data("Events/judge.jsonl")
    let file = root.appending(path: RunLayout.eventsFile(.judge))
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacy.write(to: file)
    let events = try HarnessEventJSON.decode(legacy).events.count

    let before = JudgeEventsReport.make(
      reader: HarnessEventFiles(root: root), runID: nil, filter: JudgeEventFilter(), json: true)
    let files = HarnessEventFiles(root: root, rotationBytes: { _ in legacy.count })
    try files.append(
      HarnessEvent(
        eventID: "after", time: Date(timeIntervalSince1970: 1_790_000_000),
        source: HarnessEventSource(route: .judgeTests),
        payload: .judgeDecision(HarnessEventTestsSupport.decision())))
    let after = JudgeEventsReport.make(
      reader: files, runID: nil, filter: JudgeEventFilter(), json: true)

    #expect(before.status == 0)
    #expect(after.status == 0, "\(after.stderr)")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let decoded = try [before, after].map {
      try JSONDecoder().decode(JudgeEventSummary.self, from: Data($0.stdout.utf8))
    }
    #expect(decoded.map(\.events) == [events, events + 1])
    #expect(
      decoded.allSatisfy { summary in
        summary.blocks.contains { ($0.reason?.utf8.count ?? 0) > 512 }
      })
  }

  @Test(
    "the repository's .gitignore and the template new repositories copy both ignore .harness/events/ — catches the audit log committed"
  )
  func eventsAreIgnored() throws {
    let plugin = Fixture.gateDirectory.deletingLastPathComponent()
    for file in [
      plugin.appending(path: "templates/gitignore"),
      plugin.deletingLastPathComponent().appending(path: ".gitignore"),
    ] {
      let text = try String(contentsOf: file, encoding: .utf8)
      #expect(text.contains("**/.harness/events/"), "\(file.lastPathComponent)")
    }
  }
}

/// A plain decision for tests that need 1 well-formed line.
enum HarnessEventTestsSupport {
  static func decision() -> JudgeDecisionEvent {
    JudgeDecisionEvent(
      subject: JudgeEventSubject(id: "t", file: "T.swift", line: 1, sourceSHA256: "00"),
      questionSet: "test-quality@1", questionSetVersion: 1, question: "fails-if-broken",
      blocking: true, atReadyTier: false, backend: .claude, model: "sonnet", servedModel: nil,
      distribution: ["yes": 1, "no": 0], p: 0,
      thresholds: JudgeEventThresholds(
        JudgeThresholds(advisory: 0.6, block: 0.9)), band: nil, inBand: nil, escalated: false,
      escalation: nil, decision: .pass, severity: nil, decidedBy: "claude/sonnet",
      reasonSource: .none, reason: nil, reasonError: nil, rationale: nil, cacheHit: false,
      calls: [], error: nil)
  }
}
