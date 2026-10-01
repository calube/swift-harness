import Darwin
import Foundation
import SwiftGateDomain

/// Why a halt or resume wasn't recorded.
public enum BuildHaltLogError: Error, Sendable, Equatable, CustomStringConvertible {
  /// No halt of the run and task is waiting for an answer.
  case noOpenHalt(buildRun: String, task: String?)
  /// The build stream, or its lock, couldn't be read.
  case unreadable(path: String, reason: String)
  case unwritten(HarnessEventWriteError)

  public var description: String { "" }
}

/// The `build.halt` and `build.resume` events of a checkout's store. Halt and resume each run
/// holding the lock in ``lockFile``, so 2 resumes can't both answer 1 halt.
public struct BuildHaltLog: Sendable {
  /// Beside the store's other locks, and apart from the build stream's own, which every append
  /// takes and releases inside the read-then-write this lock spans.
  public static let lockFile = "\(RunLayout.eventsDirectory)/build-halts.lock"

  public let root: URL
  private let now: @Sendable () -> Date
  private let newEventID: @Sendable () -> String

  /// - Parameter root: the checkout whose `.harness/events/` holds the build stream.
  public init(
    root: URL,
    now: @escaping @Sendable () -> Date = {
      Date()  // swiftgate:allow det.date-init — stamps the event
    },
    newEventID: @escaping @Sendable () -> String = {
      UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
    }
  ) {
    self.root = root
    self.now = now
    self.newEventID = newEventID
  }

  /// Records that `buildRun` (and `task`, when given) stopped for `reason`.
  public func halt(buildRun: String, task: String?, reason: BuildHaltReason)
    throws(BuildHaltLogError) -> HarnessEvent
  {
    throw .noOpenHalt(buildRun: buildRun, task: task)
  }

  /// Answers the newest open halt of `buildRun` and `task` with `answer`; writes nothing when
  /// there is none.
  public func resume(buildRun: String, task: String?, answer: BuildResumeAnswer)
    throws(BuildHaltLogError) -> HarnessEvent
  {
    throw .noOpenHalt(buildRun: buildRun, task: task)
  }
}
