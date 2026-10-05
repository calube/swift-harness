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
  /// Merge a `review-blocked` return as it is: only the person's word, never a recommendation.
  case merge
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
  /// For each task of `buildRun`, when its newest halt was answered `retry`: what sends a task
  /// whose return was checked back to a fixer.
  public static func retried(in events: [HarnessEvent], buildRun: String) -> [String: Date] {
    var newest: [String: (time: Date, retry: Bool)] = [:]
    for event in events {
      guard case .buildResume(let resume) = event.payload, resume.buildRun == buildRun,
        let task = resume.task
      else { continue }
      newest[task] = (event.time, resume.answer == .retry)
    }
    return newest.compactMapValues { $0.retry ? $0.time : nil }
  }

  /// The newest halt of `buildRun` scoped to exactly `task` that no resume names as its parent.
  /// A halt of the whole run (`task` `nil`) is answered only by a resume of the whole run.
  public static func openHalt(in events: [HarnessEvent], buildRun: String, task: String?)
    -> HarnessEvent?
  {
    open(in: events)
      .filter {
        guard case .buildHalt(let halt) = $0.payload else { return false }
        return halt.buildRun == buildRun && halt.task == task
      }
      .last
  }

  /// Every halt no resume answered yet, oldest first: each one is still waiting.
  public static func open(in events: [HarnessEvent]) -> [HarnessEvent] {
    var answered = Set<String>()
    for event in events {
      if case .buildResume = event.payload, let parent = event.parentID {
        answered.insert(parent)
      }
    }
    let halts = events.enumerated().filter {
      guard case .buildHalt = $0.element.payload else { return false }
      return !answered.contains($0.element.eventID)
    }
    // Ties keep write order, so the newest of 2 halts in 1 millisecond is the later line.
    return halts.sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
      .map(\.element)
  }

  /// The answer to the newest halt of `buildRun` scoped to exactly `task` made at or after
  /// `since`, or `nil` when no such halt has been answered.
  public static func answer(
    in events: [HarnessEvent], buildRun: String, task: String?, since: Date
  ) -> BuildResumeAnswer? {
    var answers: [String: BuildResumeAnswer] = [:]
    for event in events {
      if case .buildResume(let resume) = event.payload, let parent = event.parentID {
        answers[parent] = resume.answer
      }
    }
    let halts = events.enumerated().filter {
      guard case .buildHalt(let halt) = $0.element.payload else { return false }
      return halt.buildRun == buildRun && halt.task == task && $0.element.time >= since
        && answers[$0.element.eventID] != nil
    }
    let newest = halts.max { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
    return newest.flatMap { answers[$0.element.eventID] }
  }

  /// Why `build halt` won't record `reason` at `now`, or `nil` when it may. A `budget` halt is
  /// `build cutoff`'s alone, so in a run with a time box one before `cutoffAt` is refused: time
  /// left in the box is priced by the cutoff, never judged by hand.
  /// - Parameter cutoffAt: the run's time-box cutoff; `nil` for a build with no box.
  public static func refusal(reason: BuildHaltReason, now: Date, cutoffAt: Date?) -> String? {
    guard reason == .budget, let cutoffAt, now < cutoffAt else { return nil }
    let left = Int(cutoffAt.timeIntervalSince(now).rounded(.up))
    return "a `budget` halt is `build cutoff`'s to record, and the cutoff at "
      + "\(cutoffAt.formatted(.iso8601)) is \(left) s away: go on with the loop, and run "
      + "`build cutoff` when the clock reaches it"
  }

  /// Whole milliseconds from `halt` to `resume`; `0` when the clock ran backwards.
  public static func waitMilliseconds(from halt: Date, to resume: Date) -> Int {
    let milliseconds = (resume.timeIntervalSince(halt) * 1000).rounded()
    guard milliseconds > 0 else { return 0 }
    return Int(exactly: milliseconds) ?? Int.max
  }
}
