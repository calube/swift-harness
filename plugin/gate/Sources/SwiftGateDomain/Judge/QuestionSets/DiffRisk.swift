import Foundation

/// How much review a change needs past the gate (design §11.5): `low` the gate only, `medium` 1
/// reviewer, `high` a full review plus QA.
public enum DiffRiskLevel: String, Sendable, Hashable, CaseIterable, Codable {
  case low
  case medium
  case high
}

/// 1 change to rate: the paths it touches and its unified diff.
public struct DiffRiskChange: Sendable, Equatable {
  /// Names the change in the judge's events, such as the task it came from.
  public let id: String
  public let paths: [String]
  public let diff: String

  public init(id: String, paths: [String], diff: String) {
    self.id = id
    self.paths = paths
    self.diff = diff
  }
}

/// A change's level and what set it.
public enum DiffRiskVerdict: Sendable, Equatable {
  /// `path` matches the sensitive glob `glob`, so the judge was never asked.
  case sensitive(path: String, glob: String)
  case judged(DiffRiskLevel)

  public var level: DiffRiskLevel {
    .low
  }
}

extension JudgeQuestionSet {
  /// `mayBlock` because the level decides whether a change gets any review at all: when Jev gives
  /// no answer, the cascade sends the question to Claude instead of leaving it unasked.
  public static let diffRisk = JudgeQuestionSet(
    id: "diff-risk", version: 1,
    subjectDescription: "a change to a repository as a unified diff, with the paths it touches",
    questions: [
      JudgeQuestion(
        id: DiffRisk.questionID,
        text:
          "How much review does this change need before it merges, beyond automated build, lint "
          + "and test checks? high: it touches security, authentication, secrets, payments, data "
          + "migrations, persisted formats, concurrency or a public interface, or it is too large "
          + "to review at a glance; medium: it changes behaviour in ordinary code a reviewer "
          + "should read; low: documentation, comments, formatting, tests only, or a small local "
          + "change that can't alter behaviour.",
        kind: .score(DiffRiskLevel.worstFirst.map(\.rawValue)), flag: .option("high"),
        mayBlock: true, problem: "the change needs a full review",
        levelDescriptions: [
          "high: touches security, authentication, secrets, payments, data migrations, persisted "
            + "formats, concurrency or a public interface, or is too large to review at a glance",
          "medium: changes behaviour in ordinary code a reviewer should read",
          "low: documentation, comments, formatting, tests only, or a small local change that "
            + "can't alter behaviour",
        ])
    ])
}

extension DiffRiskLevel {
  /// The order the question lists its levels in.
  static let worstFirst: [DiffRiskLevel] = [.high, .medium, .low]
}

public enum DiffRisk {
  public static let questionID = "risk"

  /// The first path, in `paths` order, that matches 1 of `globs`, as a `.sensitive` verdict.
  /// A glob matches path segment by segment, and `**` spans any number of directories.
  public static func sensitive(_ paths: [String], globs: [String]) -> DiffRiskVerdict? {
    nil
  }

  /// What the judge reads: the diff as the subject and the touched paths as its context.
  public static func subject(_ change: DiffRiskChange) -> JudgeSubject {
    JudgeSubject(id: change.id, file: "", line: 0, source: "", context: "")
  }

  public static func level(from answers: [JudgeAnswer]) throws(JudgeClassificationError)
    -> DiffRiskLevel
  {
    throw .unreadable("")
  }

  /// Rates `change`. A path matching `sensitive` rates `high` before `ask` runs, so a sensitive
  /// change is `high` even when the judge is down. `ask` is the judge, normally the cascade.
  public static func classify(
    _ change: DiffRiskChange, sensitive globs: [String],
    ask: (JudgeSubject, JudgeQuestionSet) async throws -> [JudgeAnswer]
  ) async throws(JudgeClassificationError) -> DiffRiskVerdict {
    throw .noAnswer("")
  }
}
