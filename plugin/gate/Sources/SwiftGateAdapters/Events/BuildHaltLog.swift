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

  public var description: String {
    switch self {
    case .noOpenHalt(let buildRun, let task):
      "no open halt for build run \(buildRun)" + (task.map { ", task \($0)" } ?? " as a whole")
    case .unreadable(let path, let reason): "\(path): \(reason)"
    case .unwritten(let error): "\(error)"
    }
  }
}

/// The `build.halt` and `build.resume` events of a checkout's store. Halt and resume each run
/// holding the lock in ``lockFile``, so 2 resumes can't both answer 1 halt.
public struct BuildHaltLog: Sendable {
  /// Relative to the event store's state root, beside its other locks, and apart from the build
  /// stream's own, which every append takes and releases inside the read-then-write this lock
  /// spans.
  public static let lockFile = "\(RunLayout.eventsDirectory)/build-halts.lock"

  public let root: URL
  private let now: @Sendable () -> Date
  private let newEventID: @Sendable () -> String

  /// - Parameter root: the checkout whose state root's `events/` holds the build stream.
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

  /// The time a halt written now would carry.
  public func time() -> Date { now() }

  /// Records that `buildRun` (and `task`, when given) stopped for `reason`.
  public func halt(buildRun: String, task: String?, reason: BuildHaltReason)
    throws(BuildHaltLogError) -> HarnessEvent
  {
    try locked { () throws(BuildHaltLogError) -> HarnessEvent in
      let event = HarnessEvent(
        eventID: newEventID(), time: now(), source: HarnessEventSource(route: nil),
        payload: .buildHalt(BuildHaltEvent(buildRun: buildRun, task: task, reason: reason)))
      try write(event)
      return event
    }
  }

  /// Answers the newest open halt of `buildRun` and `task` with `answer`; writes nothing when
  /// there is none.
  public func resume(buildRun: String, task: String?, answer: BuildResumeAnswer)
    throws(BuildHaltLogError) -> HarnessEvent
  {
    try locked { () throws(BuildHaltLogError) -> HarnessEvent in
      guard let halt = BuildHalts.openHalt(in: try events(), buildRun: buildRun, task: task)
      else {
        throw .noOpenHalt(buildRun: buildRun, task: task)
      }
      let time = now()
      let event = HarnessEvent(
        eventID: newEventID(), parentID: halt.eventID, time: time,
        source: HarnessEventSource(route: nil),
        payload: .buildResume(
          BuildResumeEvent(
            buildRun: buildRun, task: task, answer: answer,
            waitMilliseconds: BuildHalts.waitMilliseconds(from: halt.time, to: time))))
      try write(event)
      return event
    }
  }

  private var files: HarnessEventFiles { HarnessEventFiles(root: root) }

  /// Every event of the build stream, halts and resumes among them, in write order.
  public func events() throws(BuildHaltLogError) -> [HarnessEvent] {
    let data: Data?
    do throws(HarnessEventReadError) {
      data = try files.read(.build, runID: nil)
    } catch {
      throw .unreadable(path: error.path, reason: error.reason)
    }
    guard let data else { return [] }
    do throws(HarnessEventDecodeError) {
      // A torn last line is a write still in flight from a crashed process; its halt never
      // finished recording, so there is nothing in it to answer.
      return try HarnessEventJSON.decode(data).events
    } catch {
      throw .unreadable(path: files.path(.build, runID: nil), reason: error.description)
    }
  }

  private func write(_ event: HarnessEvent) throws(BuildHaltLogError) {
    do throws(HarnessEventWriteError) {
      try files.append(event)
    } catch {
      throw .unwritten(error)
    }
  }

  /// Runs `body` holding the halt lock: the read of open halts and the write that answers 1 are
  /// 1 step to every other halt and resume.
  private func locked<T>(_ body: () throws(BuildHaltLogError) -> T) throws(BuildHaltLogError)
    -> T
  {
    let lock = StateRootResolver.eventStore(worktree: root).url(Self.lockFile)
    do {
      try FileManager.default.createDirectory(
        at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      throw .unwritten(
        HarnessEventWriteError(
          path: lock.deletingLastPathComponent().path, reason: error.localizedDescription))
    }
    let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else {
      throw .unwritten(
        HarnessEventWriteError(path: lock.path, reason: "open: \(String(cString: strerror(errno)))")
      )
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      throw .unwritten(
        HarnessEventWriteError(
          path: lock.path, reason: "flock: \(String(cString: strerror(errno)))"))
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }
}
