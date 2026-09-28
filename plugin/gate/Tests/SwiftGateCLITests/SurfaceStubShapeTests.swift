import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// The stub shapes real surface commits use beyond the first allowed-body table, each a captured
/// commit, and 1 captured near miss per shape that must still fail.
@Suite("surface-check stub shapes from real surface commits")
struct SurfaceStubShapeTests {
  static let allowed: [(name: String, judged: [SurfaceJudged])] = [
    (
      "allowed-throw-only",
      [
        SurfaceJudged("ItemClient.load()", .throwsError),
        SurfaceJudged("ItemClient.save(_:)", .throwsError),
        SurfaceJudged("ItemClient.reset()", .throwsError),
        SurfaceJudged("ItemClient.retry(reason:)", .throwsError),
      ]
    ),
    (
      "allowed-empty-payload-case",
      [
        SurfaceJudged("ItemClient.run()", .emptyPayloadCase),
        SurfaceJudged("ItemClient.stopped()", .emptyPayloadCase),
        SurfaceJudged("ItemClient.state()", .emptyPayloadCase),
        SurfaceJudged("ItemClient.state(items:)", .emptyPayloadCase),
        SurfaceJudged("ItemClient.phase(named:)", .emptyPayloadCase),
        SurfaceJudged("Loader.makeState", .emptyPayloadCase),
      ]
    ),
    (
      "allowed-returns-unchanged",
      [
        SurfaceJudged("Limits.runsImpact(with:)", .returnsUnchanged),
        SurfaceJudged("Limits.extraSteps", .returnsUnchanged),
        SurfaceJudged("Limits.echo(_:)", .returnsUnchanged),
      ]
    ),
  ]

  private static let thrownMessage =
    "the disk is full and the retry budget is spent, so the load stops here now"

  /// Each near miss sits beside its allowed twin in the same commit, so a test sees both sides of
  /// the shape's edge: the twin passes and every near miss fails.
  static let nearMisses: [(name: String, twins: [SurfaceJudged], findings: [SurfaceRejected])] = [
    (
      "rejected-throw-near-miss",
      [SurfaceJudged("makeError()", .payloadFreeCase), SurfaceJudged("stop()", .throwsError)],
      [
        SurfaceRejected("load()", .notAStub(excerpt: "_ = 0"), line: 6),
        // 100 characters, the excerpt's limit, kept whole; 1 more is cut to 100 and marked.
        SurfaceRejected(
          "save()", .notAStub(excerpt: "throw LoadError.failed(\"\(thrownMessage)\")"), line: 11),
        SurfaceRejected(
          "saveLong()", .notAStub(excerpt: "throw LoadError.failed(\"\(thrownMessage)!\"…"),
          line: 15),
        SurfaceRejected("reset()", .notAStub(excerpt: "throw makeError()"), line: 19),
      ]
    ),
    (
      "rejected-payload-case-near-miss",
      [
        SurfaceJudged("LoadState.make(_:)", .payloadFreeCase),
        SurfaceJudged("done()", .emptyPayloadCase),
      ],
      [
        SurfaceRejected("failed()", .notAStub(excerpt: ".exited(1)"), line: 7),
        SurfaceRejected(
          "reloaded(items:)", .notAStub(excerpt: ".loaded(items.reversed())"), line: 11),
        SurfaceRejected("fresh()", .notAStub(excerpt: ".make([])"), line: 15),
      ]
    ),
    (
      "rejected-returns-near-miss",
      [SurfaceJudged("Flags.only()", .returnsUnchanged)],
      [
        SurfaceRejected("Flags.both()", .notAStub(excerpt: "return runsImpact && x"), line: 10),
        SurfaceRejected("Flags.nested()", .notAStub(excerpt: "return self.a.b"), line: 14),
        SurfaceRejected("Flags.member()", .notAStub(excerpt: "a.b"), line: 18),
      ]
    ),
  ]

  private static func check(_ name: String) async throws -> (
    judgements: [SurfaceJudgement], report: RunReport
  ) {
    let reader = CapturedSurfaceReader(name: name)
    let (_, judgements) = try await SurfaceCheckRun.judgements(commit: name, reader: reader)
    let outcome = await SurfaceCheckRun.outcome(commit: name, reader: reader)
    let report = try StaticCheckReport.make(
      runID: "surface", durationMilliseconds: 0, outcome: outcome)
    return (judgements, report)
  }

  @Test(
    "a throw-only body, an enum case built from empty defaults or parameters, and a parameter or self property returned unchanged pass as their own stub forms — catches a real surface commit's stubs failing the check",
    arguments: allowed)
  func stubShapePasses(_ fixture: (name: String, judged: [SurfaceJudged])) async throws {
    let (judgements, report) = try await Self.check(fixture.name)

    #expect(
      judgements.map { SurfaceJudged(declaration: $0.declaration, outcome: $0.outcome) }
        == fixture.judged)
    #expect(report.verdict == .green, "\(report.findings.map(\.message))")
    #expect(report.verdict.exitCode == 0)
  }

  @Test(
    "beside its allowed twin, a throw after a statement or of a non-empty or computed value, a case with literal content, a call or an undeclared case, and a returned operator or member chain each fail naming the declaration, with a long excerpt cut past 100 characters — catches a stub shape loosened into accepting behaviour",
    arguments: nearMisses)
  func nearMissFails(
    _ fixture: (name: String, twins: [SurfaceJudged], findings: [SurfaceRejected])
  ) async throws {
    let (judgements, report) = try await Self.check(fixture.name)

    let stubs = judgements.compactMap { judgement -> SurfaceJudged? in
      guard case .stub = judgement.outcome else { return nil }
      return SurfaceJudged(declaration: judgement.declaration, outcome: judgement.outcome)
    }
    #expect(stubs == fixture.twins)

    let behaviours = judgements.compactMap { judgement -> SurfaceRejected? in
      guard case .behaviour(let behaviour) = judgement.outcome else { return nil }
      return SurfaceRejected(
        judgement.declaration, behaviour, line: judgement.line, file: judgement.file)
    }
    #expect(behaviours.map(\.testDescription) == fixture.findings.map(\.testDescription))
    #expect(behaviours.map(\.behaviour) == fixture.findings.map(\.behaviour))
    #expect(report.verdict == .red)
    #expect(report.verdict.exitCode == 1)
    #expect(
      report.findings.filter { $0.ruleID == SurfaceCheck.behaviourRuleID }.count
        == fixture.findings.count)
  }
}
