import Foundation

/// Why a build stopped to wait on a person.
public enum BuildHaltReason: String, Sendable, Codable, CaseIterable {
  /// A question to the person that isn't one of the other reasons.
  case question
  /// A stall watch fired: no agent in a task's workflow moved.
  case stall
  /// A task's gate, a merge gate or the final gate stayed RED.
  case gateRed = "gate-red"
  case mergeConflict = "merge-conflict"
  /// A design conflict sent the design back for an amend.
  case amend
  /// The time budget ran out with tasks still running.
  case budget
  /// A tool call waits on a permission no one granted.
  case permission
}

/// What the person answered a halt with.
public enum BuildResumeAnswer: String, Sendable, Codable, CaseIterable {
  case retry
  case wait
  /// Drop the task, or stop the build.
  case abandon
  case amend
  /// Go on as the recommended option says.
  case `continue`
}

/// `build.halt`: a build run stopped to ask. Ids and a closed reason only: the question's text
/// never goes in.
public struct BuildHaltEvent: Sendable, Equatable, Codable {
  public let buildRun: String
  /// `nil` for a halt of the whole run, such as the time budget.
  public let task: String?
  public let reason: BuildHaltReason

  public init(buildRun: String, task: String?, reason: BuildHaltReason) {
    self.buildRun = buildRun
    self.task = task
    self.reason = reason
  }
}

/// `build.resume`: the answer to 1 halt, whose event is the resume's `parentID`. The answer's
/// text never goes in.
public struct BuildResumeEvent: Sendable, Equatable, Codable {
  public let buildRun: String
  public let task: String?
  public let answer: BuildResumeAnswer
  /// From the halt's time to the resume's.
  public let waitMilliseconds: Int

  public init(buildRun: String, task: String?, answer: BuildResumeAnswer, waitMilliseconds: Int) {
    self.buildRun = buildRun
    self.task = task
    self.answer = answer
    self.waitMilliseconds = waitMilliseconds
  }

  private enum CodingKeys: String, CodingKey {
    case buildRun, task, answer
    case waitMilliseconds = "waitMs"
  }
}

/// Matches halts to the resumes that answer them.
public enum BuildHalts {
  /// The newest halt of `buildRun` scoped to exactly `task` that no resume names as its parent.
  /// A halt of the whole run (`task` `nil`) is answered only by a resume of the whole run.
  public static func openHalt(in events: [HarnessEvent], buildRun: String, task: String?)
    -> HarnessEvent?
  { nil }

  /// Every halt no resume answered yet, oldest first: each one is still waiting.
  public static func open(in events: [HarnessEvent]) -> [HarnessEvent] { [] }

  /// Whole milliseconds from `halt` to `resume`; `0` when the clock ran backwards.
  public static func waitMilliseconds(from halt: Date, to resume: Date) -> Int { 0 }
}
