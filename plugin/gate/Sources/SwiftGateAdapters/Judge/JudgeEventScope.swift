import Foundation
import SwiftGateDomain
import Synchronization

/// Collects the `judge.call` events emitted while it's bound, so a route can link its decisions to
/// the calls they rest on.
public final class JudgeCallRecorder: Sendable {
  private let recorded = Mutex<[JudgeDecisions.RecordedCall]>([])

  public init() {}

  public var calls: [JudgeDecisions.RecordedCall] { recorded.withLock { $0 } }

  func record(_ call: JudgeDecisions.RecordedCall) {
    recorded.withLock { $0.append(call) }
  }
}

/// The writes a scope couldn't make, which the route reports without changing its verdict.
public final class HarnessEventFailures: Sendable {
  private let failures = Mutex<[HarnessEventWriteError]>([])

  public init() {}

  public var all: [HarnessEventWriteError] { failures.withLock { $0 } }

  public func record(_ failure: HarnessEventWriteError) {
    failures.withLock { $0.append(failure) }
  }
}

/// Where judge events go and what each carries about its route. A route binds 1 for the length of
/// its work, and every backend call made inside reports itself through ``JudgeCallEvents``.
public struct JudgeEventScope: Sendable {
  @TaskLocal public static var current: JudgeEventScope?

  public let log: any HarnessEventWriting
  public let now: @Sendable () -> Date
  public let newID: @Sendable () -> String
  public let failures: HarnessEventFailures
  public var runID: String?
  public var head: String?
  public var base: String?
  public var source: HarnessEventSource
  /// Why the calls made under this scope are made.
  public var role: JudgeCallRole
  public var parentID: String?
  /// Values no event may carry.
  public var secrets: [String]
  var recorders: [JudgeCallRecorder]

  public init(
    log: any HarnessEventWriting, now: @escaping @Sendable () -> Date,
    newID: @escaping @Sendable () -> String, source: HarnessEventSource, runID: String? = nil,
    head: String? = nil, base: String? = nil, secrets: [String] = [],
    failures: HarnessEventFailures = HarnessEventFailures()
  ) {
    self.log = log
    self.now = now
    self.newID = newID
    self.failures = failures
    self.runID = runID
    self.head = head
    self.base = base
    self.source = source
    self.role = .answer
    self.parentID = nil
    self.secrets = secrets
    self.recorders = []
  }

  /// The file log under `root`, the wall clock, random ids, and every backend key in the
  /// environment as a secret.
  public static func live(
    root: URL, source: HarnessEventSource, runID: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> JudgeEventScope {
    JudgeEventScope(
      log: HarnessEventFiles(root: root),
      now: { Date() },  // swiftgate:allow det.date-init — stamps the event
      newID: { UUID().uuidString },  // swiftgate:allow det.uuid-init — ids need only be unique
      source: source, runID: runID,
      secrets: JudgeBackend.allCases.compactMap { $0.keyVariable.flatMap { environment[$0] } })
  }

  /// This scope with calls made for `role`, caused by `parentID`.
  public func calling(_ role: JudgeCallRole, parentID: String?) -> JudgeEventScope {
    var scope = self
    scope.role = role
    scope.parentID = parentID
    return scope
  }

  /// This scope also recording into `recorder`.
  public func recording(into recorder: JudgeCallRecorder) -> JudgeEventScope {
    var scope = self
    scope.recorders.append(recorder)
    return scope
  }

  /// Writes `event`; a failure is kept in ``failures``, never thrown.
  public func emit(_ event: HarnessEvent) {
    do throws(HarnessEventWriteError) {
      try log.append(event)
    } catch {
      failures.record(error)
    }
    if case .judgeCall(let call) = event.payload {
      let recorded = JudgeDecisions.RecordedCall(
        eventID: event.eventID, parentID: event.parentID, call: call)
      for recorder in recorders { recorder.record(recorded) }
    }
  }

  /// An event under this scope's run, commit and route.
  public func event(_ payload: HarnessEventPayload, eventID: String, parentID: String?)
    -> HarnessEvent
  {
    HarnessEvent(
      eventID: eventID, parentID: parentID, time: now(), runID: runID, head: head, base: base,
      source: source, payload: payload)
  }

  /// Runs `body` with `scope` bound, or unbound when `scope` is `nil`.
  public static func bind<T: Sendable, Failure: Error>(
    _ scope: JudgeEventScope?, isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws(Failure) -> T
  ) async throws(Failure) -> T {
    guard let scope else { return try await body() }
    // `withValue` rethrows untyped, so the typed error crosses it inside a `Result`.
    let result: Result<T, Failure> = await $current.withValue(
      scope,
      operation: {
        do throws(Failure) {
          return .success(try await body())
        } catch {
          return .failure(error)
        }
      }, isolation: isolation)
    return try result.get()
  }
}

extension JudgeEventError {
  /// `error` from `judge`, in words a finding can carry.
  public init(_ error: JudgeError, by judge: JudgeIdentity) {
    let kind: Kind =
      switch error {
      case .notConfigured: .notConfigured
      case .backend: .backend
      case .malformedReply: .malformedReply
      case .stateTooLarge: .stateTooLarge
      case .process(.launchFailed): .launchFailed
      case .process(.timedOut): .timedOut
      case .process(.cancelled): .cancelled
      }
    self.init(kind: kind, message: error.explanation(by: judge))
  }
}

/// The 1 place every judge backend call reports itself: each backend, and the cache on a hit,
/// answers through ``observe(_:subject:questions:_:)``.
public enum JudgeCallEvents {
  /// Runs `body`, the call itself, and emits its `judge.call` event to the bound scope.
  public static func observe(
    _ identity: JudgeIdentity, subject: JudgeSubject, questions: JudgeQuestionSet,
    _ body: () async throws(JudgeError) -> JudgeReply
  ) async throws(JudgeError) -> JudgeReply {
    guard let scope = JudgeEventScope.current else { return try await body() }
    let clock = ContinuousClock()
    let start = clock.now
    let result: Result<JudgeReply, JudgeError>
    do throws(JudgeError) {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    let measured = JudgeUsage.milliseconds(clock.now - start)
    guard let backend = JudgeBackend(rawValue: identity.backend) else {
      scope.failures.record(
        HarnessEventWriteError(
          path: "judge.call", reason: "`\(identity.backend)` is not a judge backend"))
      return try result.get()
    }
    let usage = try? result.get().usage
    let answers = (try? result.get().answers)?.map {
      JudgeAnswer(
        question: $0.question, distribution: $0.distribution,
        rationale: $0.rationale.map { JudgeDecisions.redact($0, scope.secrets) })
    }
    let error: JudgeEventError? =
      switch result {
      case .success: nil
      case .failure(let failure):
        JudgeEventError(
          kind: JudgeEventError(failure, by: identity).kind,
          message: JudgeDecisions.redact(failure.explanation(by: identity), scope.secrets))
      }
    let call = JudgeCallEvent(
      role: scope.role, backend: backend, model: identity.model, servedModel: usage?.servedModel,
      questionSet: questions.versionedID,
      questions: questions.questions.map { JudgeEventQuestion(id: $0.id, blocking: $0.mayBlock) },
      subject: JudgeEventSubject(subject), answers: answers, cacheHit: usage?.cached ?? false,
      latencyMs: usage?.wallMilliseconds ?? measured, backendMs: usage?.backendMilliseconds,
      costUSD: usage?.costUSD, inputTokens: usage?.inputTokens, outputTokens: usage?.outputTokens,
      error: error)
    scope.emit(scope.event(.judgeCall(call), eventID: scope.newID(), parentID: scope.parentID))
    return try result.get()
  }
}
