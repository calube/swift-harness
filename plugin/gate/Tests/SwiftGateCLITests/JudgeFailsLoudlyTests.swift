import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// A configured Jev judge that can't answer at `ready` hands its blocking questions to Claude, and
/// the gate is BLOCKED only when Claude can't answer either. Below `ready` nothing changes.
@Suite("judge: a Jev judge that can't run at ready")
struct JudgeFailsLoudlyTests {
  typealias Steps = CheckJudgeStepTests
  typealias Events = JudgeEventsTests

  static let missingKey = JudgeError.notConfigured(
    "set \(JevPin.keyVariable) to use the Jev judge backend")
  static let blockingQuestions = ["fails-if-broken", "asserts-implementation"]

  /// Each subject's Jev calls, counted.
  final class Calls: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    /// The call number this is for `subject`, from 1.
    func next(_ subject: String) -> Int {
      counts.withLock {
        $0[subject, default: 0] += 1
        return $0[subject] ?? 0
      }
    }

    var all: [String: Int] { counts.withLock { $0 } }
  }

  /// A Jev judge that throws `failures` in order on each subject's first calls, then answers 0.1
  /// on every question.
  static func jev(failing failures: [JudgeError], calls: Calls) -> FakeJudge {
    FakeJudge(identity: Steps.jev) { subject, questions throws(JudgeError) in
      let call = calls.next(subject.id)
      if call <= failures.count { throw failures[call - 1] }
      return Steps.answers(subject, questions, flagged: 0.1, rationale: nil)
    }
  }

  @Test(
    "with no TYPESAFE_API_KEY at ready, Jev is asked once, Claude answers only the blocking questions and its 0.95 blocks under claude/sonnet, and each decision records the escalation as caused by Jev's error — catches a missing key turning the judge silently off"
  )
  func missingKeyEscalatesToClaude() async throws {
    let calls = Calls()
    let asked = Steps.Asked()

    let judged = try await Events.judged(
      judge: Self.jev(failing: [Self.missingKey, Self.missingKey], calls: calls),
      reasonJudge: Steps.reasonJudge(
        flagged: 0.95, rationale: "the doubled value is never compared", asked: asked))

    #expect(!calls.all.isEmpty)
    #expect(calls.all.values.allSatisfy { $0 == 1 })
    #expect(asked.all == Array(repeating: Self.blockingQuestions, count: calls.all.count))
    let blocking = judged.findings.filter { $0.severity.failsGate }
    #expect(
      Set(blocking.map(\.ruleID)) == Set(Self.blockingQuestions.map { "judge." + $0 }))
    for finding in blocking {
      #expect(finding.message.contains("(p=0.95, claude/sonnet)"))
      #expect(finding.message.contains(JevPin.keyVariable))
      #expect(finding.failureScenario == "the doubled value is never compared")
    }
    let note = try #require(judged.findings.first { $0.ruleID == TestJudgeCheck.notRunRuleID })
    #expect(note.severity == .minor)
    #expect(note.message.contains(JevPin.keyVariable))
    #expect(TestJudgeCheck.verdict(judged.findings) == .red)

    for question in Self.blockingQuestions {
      let decisions = judged.decisions(question)
      #expect(!decisions.isEmpty)
      for (_, decision) in decisions {
        #expect(decision.escalated)
        #expect(decision.escalation?.cause == .jevFailed)
        #expect(decision.escalation?.jevError?.kind == .notConfigured)
        #expect(decision.escalation?.jevError?.message.contains(JevPin.keyVariable) == true)
        #expect(decision.decidedBy == "claude/sonnet")
        #expect(decision.decision == .block)
        #expect(decision.error == nil)
      }
    }
    for question in ["tier", "name-specificity"] {
      let decisions = judged.decisions(question)
      #expect(!decisions.isEmpty)
      for (_, decision) in decisions {
        #expect(!decision.escalated)
        #expect(decision.decision == .error)
        #expect(decision.error?.kind == .notConfigured)
      }
    }
    let escalations = judged.calls(.escalation)
    #expect(escalations.count == calls.all.count)
    for (event, _) in escalations {
      let parent = try #require(judged.calls(.answer).first { $0.event.eventID == event.parentID })
      #expect(parent.call.backend == .jev)
      #expect(parent.call.error?.kind == .notConfigured)
    }
  }

  enum Retried: String, CaseIterable, CustomTestStringConvertible {
    case transport, malformedReply
    var testDescription: String { rawValue }

    var error: JudgeError {
      switch self {
      case .transport: .transport("Jev is unreachable: connection refused")
      case .malformedReply: .malformedReply("Jev's reply isn't the reply shape")
      }
    }
  }

  @Test(
    "a Jev transport or parse error at ready is asked again once, and the answer that follows stands with Claude asked nothing — catches a passing blip escalating, or no retry",
    arguments: Retried.allCases)
  func failureOnceIsRetried(_ failure: Retried) async throws {
    let calls = Calls()
    let asked = Steps.Asked()

    let judged = try await Events.judged(
      judge: Self.jev(failing: [failure.error], calls: calls),
      reasonJudge: Steps.reasonJudge(flagged: 0.95, rationale: "a reason", asked: asked))

    #expect(!calls.all.isEmpty)
    #expect(calls.all.values.allSatisfy { $0 == 2 })
    #expect(asked.all.isEmpty)
    #expect(judged.findings.isEmpty)
    #expect(TestJudgeCheck.verdict(judged.findings) == .green)
  }

  @Test(
    "a Jev 401 at ready isn't asked again: its blocking questions go straight to Claude — catches retrying a refused key"
  )
  func refusalIsNotRetried() async throws {
    let calls = Calls()
    let asked = Steps.Asked()

    _ = try await Events.judged(
      judge: Self.jev(
        failing: [.backend("Jev refused the key in TYPESAFE_API_KEY (401)"), .backend("again")],
        calls: calls),
      reasonJudge: Steps.reasonJudge(flagged: 0.1, rationale: "a reason", asked: asked))

    #expect(!calls.all.isEmpty)
    #expect(calls.all.values.allSatisfy { $0 == 1 })
    #expect(asked.all == Array(repeating: Self.blockingQuestions, count: calls.all.count))
  }

  @Test(
    "when Jev has no key and Claude fails too, ready is BLOCKED, not RED, with a judge.blocked finding naming both errors — catches a judge that can't run passing as a minor note"
  )
  func bothFailingIsBlocked() async throws {
    let calls = Calls()

    let judged = try await Events.judged(
      judge: Self.jev(failing: [Self.missingKey], calls: calls),
      reasonJudge: Steps.failingReasonJudge(.backend("overloaded"), asked: Steps.Asked()))

    let blocked = judged.findings.filter { $0.ruleID == JudgeCascade.blockedRuleID }
    #expect(!blocked.isEmpty)
    #expect(blocked.count == calls.all.count)
    for finding in blocked {
      #expect(finding.message.contains(JevPin.keyVariable))
      #expect(finding.message.contains("overloaded"))
    }
    #expect(!judged.findings.contains { $0.severity.failsGate })
    #expect(TestJudgeCheck.verdict(judged.findings) == .blocked)
    for (_, decision) in judged.decisions("fails-if-broken") {
      #expect(decision.escalation?.cause == .jevFailed)
      #expect(decision.escalation?.error != nil)
      #expect(decision.decision == .error)
    }

    let step = try await Steps.ready(
      judge: Self.jev(failing: [Self.missingKey], calls: Calls()), config: Steps.jevConfig,
      reasonJudge: Steps.failingReasonJudge(.backend("overloaded"), asked: Steps.Asked()))
    #expect(step.steps.first { $0.step == .judge }?.verdict == .blocked)
    #expect(step.t1.verdict == .blocked)
  }

  @Test(
    "a judge that can't run at ready reports judge.blocked and the judge.not-run note, BLOCKED with exit 2, through judge tests --ready and check --tier ready alike — catches the blocked judge reported as 1 swiftgate.environment finding"
  )
  func blockedKeepsItsRuleAndNote() async throws {
    let expected: Set = [JudgeCascade.blockedRuleID, TestJudgeCheck.notRunRuleID]
    let judged = try await Events.judged(
      judge: Self.jev(failing: [Self.missingKey], calls: Calls()),
      reasonJudge: Steps.failingReasonJudge(.backend("overloaded"), asked: Steps.Asked()))

    let report = try StaticCheckReport.make(
      runID: Events.runID, durationMilliseconds: 0,
      outcome: TestJudgeCheck.outcome(judged.findings),
      blockingRuleIDs: TestJudgeCheck.blockingRuleIDs)

    #expect(report.verdict == .blocked)
    #expect(report.verdict.exitCode == 2)
    #expect(Set(report.findings.map(\.ruleID)) == expected)
    let blocked = report.findings.filter { $0.ruleID == JudgeCascade.blockedRuleID }
    #expect(!blocked.isEmpty)
    #expect(blocked.allSatisfy { $0.file == JudgeCommandsTests.testFile })
    #expect(blocked.allSatisfy { $0.message.contains("overloaded") })

    let step = try await Steps.ready(
      judge: Self.jev(failing: [Self.missingKey], calls: Calls()), config: Steps.jevConfig,
      reasonJudge: Steps.failingReasonJudge(.backend("overloaded"), asked: Steps.Asked()))
    #expect(step.t1.verdict == .blocked)
    #expect(Set(step.judged.map(\.ruleID)) == expected)
  }

  @Test(
    "the missing key that escalates to Claude at ready stays 1 minor judge.not-run note below it, with Claude asked nothing — catches the ready-tier escalation reaching advisory runs"
  )
  func belowReadyStaysAdvisory() async throws {
    func judged(ready: Bool) async throws -> (findings: [Finding], asked: [[String]]) {
      let asked = Steps.Asked()
      let judged = try await Events.judged(
        judge: Self.jev(failing: [Self.missingKey], calls: Calls()),
        reasonJudge: Steps.reasonJudge(flagged: 0.95, rationale: "a reason", asked: asked),
        ready: ready)
      return (judged.findings, asked.all)
    }

    let atReady = try await judged(ready: true)
    let below = try await judged(ready: false)

    #expect(!atReady.asked.isEmpty)
    #expect(below.asked.isEmpty)
    #expect(below.findings.map(\.ruleID) == [TestJudgeCheck.notRunRuleID])
    #expect(below.findings.allSatisfy { $0.severity == .minor })
    #expect(below.findings.first?.message.contains(JevPin.keyVariable) == true)
    #expect(TestJudgeCheck.verdict(below.findings) == .green)
  }
}
