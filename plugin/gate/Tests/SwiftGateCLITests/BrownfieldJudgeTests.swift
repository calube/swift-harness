import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// The brownfield judge seam with a scripted judge: no network, no `claude`.
@Suite("brownfield judge")
struct BrownfieldJudgeTests {
  /// What a scripted judge was asked.
  final class Asked: Sendable {
    private let calls = Mutex<[(subject: JudgeSubject, questions: String, base: String)]>([])
    func append(_ subject: JudgeSubject, _ questions: JudgeQuestionSet, _ base: JudgeQuestionSet) {
      calls.withLock { $0.append((subject, questions.versionedID, base.versionedID)) }
    }
    var all: [(subject: JudgeSubject, questions: String, base: String)] { calls.withLock { $0 } }
  }

  struct Down: Error, CustomStringConvertible {
    var description: String { "jev: transport down; claude: not logged in" }
  }

  /// A judge answering `fails-if-broken` with `no` at `pNo`, or throwing ``Down``.
  static func judge(pNo: Double?, asked: Asked = Asked()) -> BrownfieldJudge {
    BrownfieldJudge(thresholds: .defaults, testQuality: .testsJev) { subject, questions, base in
      asked.append(subject, questions, base)
      guard let pNo else { throw Down() }
      return [
        JudgeAnswer(
          question: "fails-if-broken", distribution: ["yes": 1 - pNo, "no": pNo], rationale: nil)
      ]
    }
  }

  static let source = """
    import pytest

    def check(value):
        assert value == 2

    def test_load():
        value = load()
        check(value)

    def test_other():
        pass
    """

  static let candidate = AssertionCandidate(
    path: "api/tests/test_load.py", line: 6, endLine: 8, testName: "test_load", gap: .noAssertion)

  @Test(
    "a confident no on fails-if-broken rules the test assertion-free, a confident yes passes it, and an unsure answer stays unanswered — catches a judge answer read the wrong way round, or doubt read as a verdict"
  )
  func assertionFollowsTheAnswer() async {
    let empty = await Self.judge(pNo: 0.95).assertion(Self.candidate, source: Self.source)
    #expect(empty == .assertsNothing)
    let asserts = await Self.judge(pNo: 0.1).assertion(Self.candidate, source: Self.source)
    #expect(asserts == .asserts)
    let unsure = await Self.judge(pNo: 0.5).assertion(Self.candidate, source: Self.source)
    guard case .unanswered(let why) = unsure else {
      Issue.record("an unsure answer gave \(unsure)")
      return
    }
    #expect(why.contains("0.5"))
  }

  @Test(
    "the judge reads the test's whole body as the subject and its file as context, through the test-quality set — catches a subject cut to the declaration line, so a helper call is never seen"
  )
  func subjectHoldsTheBodyAndTheFile() async throws {
    let asked = Asked()
    _ = await Self.judge(pNo: 0.95, asked: asked).assertion(Self.candidate, source: Self.source)

    let call = try #require(asked.all.first)
    #expect(call.subject.source == "def test_load():\n    value = load()\n    check(value)")
    #expect(call.subject.context.contains("def check(value):"))
    #expect(call.subject.file == Self.candidate.path)
    #expect(call.subject.line == 6)
    #expect(call.questions == JudgeQuestionSet.testsJev.versionedID)
    #expect(call.base == JudgeQuestionSet.tests.versionedID)
  }

  @Test(
    "a judge that throws leaves the candidate unanswered naming why — catches a failed cascade read as asserting"
  )
  func failureIsUnanswered() async {
    let result = await Self.judge(pNo: nil).assertion(Self.candidate, source: Self.source)
    #expect(result == .unanswered("jev: transport down; claude: not logged in"))
  }

  @Test(
    "a clone with no [judge] leaves every candidate unanswered and says the section is missing — catches a missing judge reported as a wiring gap or read as a pass"
  )
  func noJudgeSectionSaysSo() async {
    let judge = BrownfieldJudge.assertionJudge(nil)
    let result = await judge(Self.candidate, Self.source)
    #expect(result == .unanswered(BrownfieldJudge.notConfigured))
    #expect(BrownfieldJudge.live(.disabled, root: URL(filePath: "/nonexistent")) == nil)
  }

  @Test(
    "a configured judge reaches the slice tier's assertion judge — catches the live slice keeping its stub"
  )
  func configuredJudgeIsUsed() async {
    let judge = BrownfieldJudge.assertionJudge(Self.judge(pNo: 0.95))
    #expect(await judge(Self.candidate, Self.source) == .assertsNothing)
  }

  // MARK: - diff-risk

  struct FixedDiff: DiffReading {
    let text: String
    func unifiedDiff(since ref: String) async throws(GitError) -> String { text }
  }

  static func riskJudge(_ level: String?, asked: Asked = Asked()) -> BrownfieldJudge {
    BrownfieldJudge(thresholds: .defaults, testQuality: .tests) { subject, questions, base in
      asked.append(subject, questions, base)
      guard let level else { throw Down() }
      return [
        JudgeAnswer(
          question: DiffRisk.questionID,
          distribution: Dictionary(
            uniqueKeysWithValues: ["high", "medium", "low"].map { ($0, $0 == level ? 0.9 : 0.05) }),
          rationale: nil)
      ]
    }
  }

  static func risk(
    paths: [String], sensitive: [String] = [], judge: BrownfieldJudge?
  ) async -> JudgeDiffRiskRun.Outcome {
    await JudgeDiffRiskRun.run(
      base: "swift-harness/plan",
      git: FakeGit(changed: paths, mergeBase: "base0"),
      diff: FixedDiff(text: "+print('hi')\n"), sensitive: sensitive, judge: judge)
  }

  @Test(
    "a path under a sensitive glob rates high without asking the judge, and other changes take the judge's level — catches a sensitive change sent to a judge that rates it low"
  )
  func diffRiskSensitiveAndJudged() async {
    let asked = Asked()
    let sensitive = await Self.risk(
      paths: ["docs/a.md", "api/auth/token.py"], sensitive: ["api/auth/**"],
      judge: Self.riskJudge("low", asked: asked))
    #expect(sensitive == .rated(.sensitive(path: "api/auth/token.py", glob: "api/auth/**")))
    #expect(asked.all.isEmpty)

    let judged = await Self.risk(paths: ["docs/a.md"], judge: Self.riskJudge("low", asked: asked))
    #expect(judged == .rated(.judged(.low)))
    #expect(asked.all.map(\.questions) == [JudgeQuestionSet.diffRisk.versionedID])
    #expect(asked.all.first?.subject.source == "+print('hi')\n")
  }

  @Test(
    "no judge, or a judge that can't answer, gives no level and says why, with exit 1 — catches silence read as a low-risk change"
  )
  func diffRiskNoAnswer() async {
    let unconfigured = await Self.risk(paths: ["docs/a.md"], judge: nil)
    #expect(unconfigured == .noAnswer(BrownfieldJudge.notConfigured))
    let down = await Self.risk(paths: ["docs/a.md"], judge: Self.riskJudge(nil))
    guard case .noAnswer(let why) = down else {
      Issue.record("a judge that threw gave \(down)")
      return
    }
    #expect(why.contains("transport down"))
    #expect(JudgeDiffRiskRun.render(down, json: false).status == 1)
  }

  @Test(
    "--json prints the level and what set it, or a null level and the reason — catches build-task.js reading a shape the command doesn't print"
  )
  func diffRiskJSON() throws {
    func object(_ outcome: JudgeDiffRiskRun.Outcome) throws -> [String: String?] {
      let text = JudgeDiffRiskRun.render(outcome, json: true).text
      return try JSONDecoder().decode([String: String?].self, from: Data(text.utf8))
    }
    #expect(
      try object(.rated(.sensitive(path: "api/auth/token.py", glob: "api/auth/**")))
        == ["level": "high", "by": "sensitive", "path": "api/auth/token.py", "glob": "api/auth/**"])
    #expect(try object(.rated(.judged(.medium))) == ["level": "medium", "by": "judge"])
    let none: [String: String?] = ["level": nil, "reason": "no judge"]
    #expect(try object(.noAnswer("no judge")) == none)
    #expect(JudgeDiffRiskRun.render(.rated(.judged(.low)), json: true).status == 0)
  }
}
