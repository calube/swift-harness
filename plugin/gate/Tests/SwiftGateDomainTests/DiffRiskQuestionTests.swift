import Foundation
import SwiftGateDomain
import Synchronization
import Testing

@Suite("diff-risk and finding-severity question sets")
struct DiffRiskQuestionTests {
  struct Unreachable: Error, CustomStringConvertible {
    var description: String { "Jev is unreachable: connection refused" }
  }

  /// An `ask` that counts its calls and answers every question with all weight on `option`.
  final class Asker: Sendable {
    let option: String?
    private let count = Mutex(0)

    init(answering option: String?) { self.option = option }

    var calls: Int { count.withLock { $0 } }

    func ask(_ subject: JudgeSubject, _ questions: JudgeQuestionSet) async throws -> [JudgeAnswer] {
      count.withLock { $0 += 1 }
      guard let option else { throw Unreachable() }
      return questions.questions.map { question in
        JudgeAnswer(
          question: question.id,
          distribution: Dictionary(
            uniqueKeysWithValues: question.options.map { ($0, $0 == option ? 1 : 0) }),
          rationale: nil)
      }
    }
  }

  static func risk(
    _ change: DiffRiskChange, sensitive: [String],
    ask: (JudgeSubject, JudgeQuestionSet) async throws -> [JudgeAnswer]
  ) async -> Result<DiffRiskVerdict, JudgeClassificationError> {
    do throws(JudgeClassificationError) {
      return .success(try await DiffRisk.classify(change, sensitive: sensitive, ask: ask))
    } catch {
      return .failure(error)
    }
  }

  static func severity(
    _ finding: Finding, diff: String,
    ask: (JudgeSubject, JudgeQuestionSet) async throws -> [JudgeAnswer]
  ) async -> Result<Severity, JudgeClassificationError> {
    do throws(JudgeClassificationError) {
      return .success(try await FindingSeverity.classify(finding, diff: diff, ask: ask))
    } catch {
      return .failure(error)
    }
  }

  static let change = DiffRiskChange(
    id: "change", paths: ["README.md", "Services/Auth/Keychain/TokenStore.swift"],
    diff: "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-Hello\n+Hi\n")

  @Test(
    "a sensitive path rates high without asking the judge, whether it answers low or is down — catches the override applied after the cascade"
  )
  func sensitivePathRatesHigh() async throws {
    for answering in ["low", nil] as [String?] {
      let asker = Asker(answering: answering)
      let result = await Self.risk(
        Self.change, sensitive: ["docs/**", "Services/Auth/**"], ask: asker.ask)
      #expect(
        result
          == .success(
            .sensitive(path: "Services/Auth/Keychain/TokenStore.swift", glob: "Services/Auth/**")),
        "judge answering \(answering ?? "nothing")")
      #expect(try result.get().level == .high)
      #expect(asker.calls == 0)
    }
  }

  @Test(
    "a glob matches segment by segment, and ** spans 0 or more directories — catches a prefix match flagging a sibling directory"
  )
  func globsMatchBySegment() {
    let paths = ["Payments.swift", "notsecrets/a.txt", "config/prod/secrets.env", "secrets/k.pem"]
    #expect(
      DiffRisk.sensitive(paths, globs: ["secrets/*"])
        == .sensitive(path: "secrets/k.pem", glob: "secrets/*"))
    #expect(
      DiffRisk.sensitive(paths, globs: ["**/*.env"])
        == .sensitive(path: "config/prod/secrets.env", glob: "**/*.env"))
    #expect(
      DiffRisk.sensitive(paths, globs: ["**/Payments.swift"])
        == .sensitive(path: "Payments.swift", glob: "**/Payments.swift"))
    #expect(DiffRisk.sensitive(paths, globs: ["secret/*", "config/*.env"]) == nil)
    #expect(DiffRisk.sensitive(paths, globs: []) == nil)
  }

  @Test(
    "an unreachable judge gives no level and an error naming why, never low — catches a silent default"
  )
  func unreachableIsAnError() async throws {
    let asker = Asker(answering: nil)
    let risk = await Self.risk(Self.change, sensitive: ["vendor/**"], ask: asker.ask)
    #expect(risk == .failure(.noAnswer("Jev is unreachable: connection refused")))
    #expect(asker.calls == 1)

    let finding = try Finding(
      ruleID: "C3", severity: .nit, file: "Sources/Feature.swift", line: 70, message: "m",
      failureScenario: nil)
    let severity = await Self.severity(
      finding, diff: "", ask: Asker(answering: nil).ask)
    #expect(severity == .failure(.noAnswer("Jev is unreachable: connection refused")))
  }

  @Test(
    "with no sensitive path the judge's most likely level stands — catches a fixed level ignoring the answer"
  )
  func judgedLevelStands() async {
    for level in DiffRiskLevel.allCases {
      let result = await Self.risk(
        Self.change, sensitive: ["vendor/**"], ask: Asker(answering: level.rawValue).ask)
      #expect(result == .success(.judged(level)))
    }
  }

  @Test(
    "each severity option reads as its gate severity — catches blocking read as anything but a blocker"
  )
  func severityLevelsMap() async throws {
    let finding = try Finding(
      ruleID: "P2", severity: .nit, file: "Tests/FeatureTests.swift", line: 74, message: "m",
      failureScenario: "s")
    let expected: [(String, Severity)] = [
      ("blocking", .blocker), ("major", .major), ("minor", .minor), ("nit", .nit),
    ]
    for (option, severity) in expected {
      let result = await Self.severity(
        finding, diff: "", ask: Asker(answering: option).ask)
      #expect(result == .success(severity), "\(option)")
    }
  }

  @Test(
    "an answer to another question, with an unknown option or with no weight is unreadable and says which — catches a level read from the wrong key"
  )
  func unreadableAnswers() {
    let cases: [(named: String, answer: JudgeAnswer)] = [
      (
        "answered [\"severity\"]",
        JudgeAnswer(question: "severity", distribution: ["high": 1], rationale: nil)
      ),
      (
        "[\"critical\"]",
        JudgeAnswer(question: "risk", distribution: ["critical": 1], rationale: nil)
      ),
      (
        "no weight",
        JudgeAnswer(
          question: "risk", distribution: ["high": 0, "medium": 0, "low": 0], rationale: nil)
      ),
    ]
    for (named, answer) in cases {
      let result = Result { () throws(JudgeClassificationError) in
        try DiffRisk.level(from: [answer])
      }
      guard case .failure(.unreadable(let why)) = result else {
        Issue.record("\(answer) read as \(result)")
        continue
      }
      #expect(why.contains(named), "\(why)")
    }
  }

  @Test("a tie between levels reads as the worse one — catches a tie resolved toward low")
  func tieReadsWorse() throws {
    let level = try DiffRisk.level(from: [
      JudgeAnswer(
        question: "risk", distribution: ["low": 0.45, "medium": 0.45, "high": 0.1], rationale: nil)
    ])
    #expect(level == .medium)
    let severity = try FindingSeverity.severity(from: [
      JudgeAnswer(
        question: "severity", distribution: ["blocking": 0.5, "major": 0, "minor": 0, "nit": 0.5],
        rationale: nil)
    ])
    #expect(severity == .blocker)
  }

  @Test(
    "judge ask accepts diff-risk@1 and finding-severity@1 by name — catches the sets missing from the built-in registry"
  )
  func setsAreBuiltIn() throws {
    for set in [JudgeQuestionSet.diffRisk, .findingSeverity] {
      let input = Data(
        #"{"schemaVersion": 1, "questionSet": "\#(set.versionedID)", "subjects": [{"id": "a", "source": "s", "context": "c"}]}"#
          .utf8)
      #expect(try JudgeAskInput.decode(input).questions == set)
    }
  }
}
