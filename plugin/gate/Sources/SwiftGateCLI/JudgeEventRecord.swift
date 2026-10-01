import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// What a route that decides about subjects found: its findings, and for its events, what each
/// subject's first backend returned and how each block's reason call went.
struct JudgedSubjects: Sendable {
  let findings: [Finding]
  let outcomes: [String: JudgeDecisions.Outcome]
  /// Set when a call failed and the route reported a not-run note instead of findings.
  let batchFailure: JudgeEventError?
  let reasons: [JudgeDecisions.Key: JudgeDecisions.Reason]

  /// Each subject's outcome as its call ends, from concurrent calls.
  final class Outcomes: Sendable {
    private let stored = Mutex<[String: JudgeDecisions.Outcome]>([:])

    func set(_ subject: String, _ outcome: JudgeDecisions.Outcome) {
      stored.withLock { $0[subject] = outcome }
    }

    var all: [String: JudgeDecisions.Outcome] { stored.withLock { $0 } }
  }

  /// Every subject asked `questions` of `judge` alone, findings by ``JudgePolicy``, and Claude's
  /// reason on each block a backend without reasons decided.
  static func plain(
    _ subjects: [JudgeSubject], questions: JudgeQuestionSet, judge: any Judge,
    thresholds: JudgeThresholds, atReadyTier: Bool, reasonJudge: (any Judge)?,
    secrets: [String], decisionIDs: [JudgeDecisions.Key: String],
    maxConcurrent: Int = JudgeBatch.maxConcurrent
  ) async -> JudgedSubjects {
    let outcomes = Outcomes()
    let identity = judge.identity
    let answers: [String: [JudgeAnswer]]
    switch await JudgeBatch.each(
      subjects, maxConcurrent: maxConcurrent,
      { subject throws(JudgeError) in
        do throws(JudgeError) {
          let reply = try await judge.measuredAnswer(subject, questions: questions)
          outcomes.set(
            subject.id, .answered(identity: identity, answers: reply.answers, cascade: nil))
          return reply.answers
        } catch {
          outcomes.set(
            subject.id, .failed(identity: identity, JudgeEventError(error, by: identity)))
          throw error
        }
      })
    {
    case .failure(let error):
      return JudgedSubjects(
        findings: TestJudgeCheck.note("judge not run: \(error)"), outcomes: outcomes.all,
        batchFailure: JudgeEventError(error, by: identity), reasons: [:])
    case .success(let found): answers = found
    }
    var findings: [Finding] = []
    for subject in subjects {
      findings +=
        (try? JudgePolicy.findings(
          subject: subject, answers: answers[subject.id] ?? [], questions: questions,
          thresholds: thresholds, identity: identity, atReadyTier: atReadyTier)) ?? []
    }
    let reasoned = await JudgeBlockReason.attachReporting(
      findings, subjects: subjects, answers: answers, questions: questions, identity: identity,
      reasonJudge: reasonJudge, redacting: secrets, decisionIDs: decisionIDs)
    return JudgedSubjects(
      findings: reasoned.findings, outcomes: outcomes.all, batchFailure: nil,
      reasons: reasoned.reasons)
  }
}

/// Runs a deciding route under its event scope, then writes 1 `judge.decision` per subject and
/// question. A write that fails adds 1 nit and never changes another finding.
struct JudgeEventRecord: Sendable {
  let scope: JudgeEventScope?
  let subjects: [JudgeSubject]
  let questions: JudgeQuestionSet
  let thresholds: JudgeThresholds
  let atReadyTier: Bool
  let identity: JudgeIdentity

  func record(
    _ judge: @Sendable ([JudgeDecisions.Key: String]) async -> JudgedSubjects
  ) async -> [Finding] {
    guard let scope else { return await judge([:]).findings }
    // Decision ids come first, so a reason call can name the decision it explains.
    var ids: [JudgeDecisions.Key: String] = [:]
    for key in JudgeDecisions.keys(subjects, questions) where ids[key] == nil {
      ids[key] = scope.newID()
    }
    let recorder = JudgeCallRecorder()
    let decisionIDs = ids
    let judged = await JudgeEventScope.bind(scope.recording(into: recorder)) {
      await judge(decisionIDs)
    }
    if JudgeBackend(rawValue: identity.backend) == nil {
      scope.failures.record(
        HarnessEventWriteError(
          path: "judge.decision", reason: "`\(identity.backend)` is not a judge backend"))
    } else {
      let decisions = JudgeDecisions.make(
        JudgeDecisions.Inputs(
          subjects: subjects, questions: questions, thresholds: thresholds,
          atReadyTier: atReadyTier, identity: identity, outcomes: judged.outcomes,
          batchFailure: judged.batchFailure, findings: judged.findings, reasons: judged.reasons,
          calls: recorder.calls, secrets: scope.secrets),
        ids: ids)
      for (id, decision) in decisions {
        scope.emit(scope.event(.judgeDecision(decision), eventID: id, parentID: nil))
      }
    }
    return judged.findings + Self.unwritten(scope.failures.all)
  }

  /// 1 nit naming every path a write failed at, or none.
  static func unwritten(_ failures: [HarnessEventWriteError]) -> [Finding] {
    guard let first = failures.first else { return [] }
    var paths: [String] = []
    for failure in failures where !paths.contains(failure.path) { paths.append(failure.path) }
    return
      (try? Finding(
        ruleID: TestJudgeCheck.eventsUnwrittenRuleID, severity: .nit,
        file: RunLayout.eventsFile(.judge), line: nil,
        message:
          "\(failures.count) judge events not written to \(paths.joined(separator: ", ")): "
          + "\(first.reason); the verdict stands",
        failureScenario: nil)).map { [$0] } ?? []
  }
}

/// Binds the live event scope for a route that calls a judge without deciding about subjects, so
/// each of its backend calls is recorded under its name. A write failure goes to stderr.
enum JudgeEventRoute {
  static func run<T: Sendable>(
    root: URL, route: HarnessRoute, runID: String? = nil,
    _ body: () async throws -> T
  ) async throws -> T {
    let scope = JudgeEventScope.live(
      root: root, source: HarnessEventSource(route: route), runID: runID)
    defer {
      if let finding = JudgeEventRecord.unwritten(scope.failures.all).first {
        FileHandle.standardError.write(Data("swiftgate: \(finding.message)\n".utf8))
      }
    }
    return try await JudgeEventScope.bind(scope, body)
  }
}
