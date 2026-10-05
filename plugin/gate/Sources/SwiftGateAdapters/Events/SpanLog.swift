import Darwin
import Foundation
import SwiftGateDomain

/// Why a span's start or end wasn't recorded.
public enum SpanLogError: Error, Sendable, Equatable, CustomStringConvertible {
  /// No `span.start` with this id is in the store.
  case noStart(spanID: String)
  /// The span already has a `span.end`.
  case alreadyEnded(spanID: String)
  /// The span stream, or its lock, couldn't be read.
  case unreadable(path: String, reason: String)
  case unwritten(HarnessEventWriteError)

  public var description: String {
    switch self {
    case .noStart(let spanID): "no span \(spanID) was started"
    case .alreadyEnded(let spanID): "span \(spanID) already ended"
    case .unreadable(let path, let reason): "\(path): \(reason)"
    case .unwritten(let error): "\(error)"
    }
  }
}

/// The `span.start` and `span.end` events of a checkout's store. Start and end each run holding
/// the lock in ``lockFile``, so 2 ends can't both close 1 span.
public struct SpanLog: Sendable {
  /// Relative to the event store's state root, beside the halt lock.
  public static let lockFile = "\(RunLayout.eventsDirectory)/spans.lock"

  public let root: URL
  private let now: @Sendable () -> Date
  private let newEventID: @Sendable () -> String
  private let newSpanID: @Sendable () -> String

  /// - Parameter root: the checkout whose state root's `events/` holds the span stream.
  public init(
    root: URL,
    now: @escaping @Sendable () -> Date = {
      Date()  // swiftgate:allow det.date-init — stamps the event
    },
    newEventID: @escaping @Sendable () -> String = {
      UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
    },
    newSpanID: @escaping @Sendable () -> String = { SpanLog.randomSpanID() }
  ) {
    self.root = root
    self.now = now
    self.newEventID = newEventID
    self.newSpanID = newSpanID
  }

  /// 16 lowercase hex characters from the system's random source.
  public static func randomSpanID() -> String {
    let bits = UInt64.random(in: 0 ... .max)  // swiftgate:allow det.random — ids only differ
    let hex = String(bits, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
  }

  /// Records that `phase` began and returns the `span.start` event, whose payload holds the new
  /// span id.
  public func start(
    phase: SpanPhase, buildRun: String, task: String?, role: AgentRole?, parentSpan: String?
  ) throws(SpanLogError) -> HarnessEvent {
    try locked { () throws(SpanLogError) -> HarnessEvent in
      let event = HarnessEvent(
        eventID: newEventID(), time: now(), source: HarnessEventSource(route: nil),
        payload: .spanStart(
          SpanStartEvent(
            spanID: newSpanID(), parentSpan: parentSpan, phase: phase, buildRun: buildRun,
            task: task, role: role)))
      try write(event)
      return event
    }
  }

  /// Records the end of `spanID` with `ms` from its start's time to now; writes nothing when no
  /// start has that id or the span already ended.
  public func end(spanID: String, outcome: SpanOutcome) throws(SpanLogError) -> HarnessEvent {
    try locked { () throws(SpanLogError) -> HarnessEvent in
      var start: HarnessEvent?
      for event in try events() {
        switch event.payload {
        case .spanStart(let payload) where payload.spanID == spanID: start = event
        case .spanEnd(let payload) where payload.spanID == spanID:
          throw .alreadyEnded(spanID: spanID)
        default: continue
        }
      }
      guard let start else { throw .noStart(spanID: spanID) }
      let time = now()
      let event = HarnessEvent(
        eventID: newEventID(), parentID: start.eventID, time: time,
        source: HarnessEventSource(route: nil),
        payload: .spanEnd(
          SpanEndEvent(
            spanID: spanID, outcome: outcome,
            milliseconds: max(0, Int((time.timeIntervalSince(start.time) * 1000).rounded())))))
      try write(event)
      return event
    }
  }

  /// Ends, with `outcome`, every span of `buildRun` still open that `matching` picks, oldest
  /// first, each timed from its start to now; returns the `span.end` events written. An agent
  /// stopped, or one that never ran its own `span end`, leaves its span open until this.
  public func endOpen(
    buildRun: String, outcome: SpanOutcome, matching: (SpanStartEvent) -> Bool
  ) throws(SpanLogError) -> [HarnessEvent] {
    try locked { () throws(SpanLogError) -> [HarnessEvent] in
      let events = try events()
      let open = Set(OpenSpans.of(events, buildRun: buildRun).filter(matching).map(\.spanID))
      let time = now()
      var written: [HarnessEvent] = []
      for start in events {
        guard case .spanStart(let payload) = start.payload, open.contains(payload.spanID) else {
          continue
        }
        let event = HarnessEvent(
          eventID: newEventID(), parentID: start.eventID, time: time,
          source: HarnessEventSource(route: nil),
          payload: .spanEnd(
            SpanEndEvent(
              spanID: payload.spanID, outcome: outcome,
              milliseconds: max(0, Int((time.timeIntervalSince(start.time) * 1000).rounded())))))
        try write(event)
        written.append(event)
      }
      return written
    }
  }

  /// Every span event in the store, sealed segments included, oldest first. An undecodable line
  /// or unreadable file fails the read, since it could hold the start or end being looked for. A
  /// torn last line is a write a crashed process never finished, and a segment whose index
  /// didn't read was read whole, so neither hides a recorded span.
  private func events() throws(SpanLogError) -> [HarnessEvent] {
    let read = EventStoreReader(files: LiveEventStoreFiles(root: root)).read(
      EventQuery(kinds: [.spanStart, .spanEnd]))
    if let damage = read.damage.first(where: {
      $0.kind == .undecodableLine || $0.kind == .unreadableFile
    }) {
      throw .unreadable(path: damage.file, reason: damage.description)
    }
    return read.events.map(\.event)
  }

  private func write(_ event: HarnessEvent) throws(SpanLogError) {
    do throws(HarnessEventWriteError) {
      try HarnessEventFiles(root: root).append(event)
    } catch {
      throw .unwritten(error)
    }
  }

  /// Runs `body` holding the span lock, so the read that finds a start and the write that ends
  /// it are 1 step to every other start and end.
  private func locked<T>(_ body: () throws(SpanLogError) -> T) throws(SpanLogError) -> T {
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

/// Which checkout's store each span started in, by span id, in a machine-wide directory, so
/// `events span end` finds a span's start whatever directory it runs from.
public struct SpanStoreIndex: Sendable {
  /// How long an entry is kept: longer than any run whose span could still be open.
  public static let retainedSeconds: TimeInterval = 7 * 24 * 60 * 60

  public let directory: URL

  /// `~/.cache/swift-harness/spans`.
  public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> URL
  {
    home.appending(path: ".cache/swift-harness/spans", directoryHint: .isDirectory)
  }

  public init(directory: URL = Self.defaultDirectory()) {
    self.directory = directory
  }

  /// Records that `spanID` started in the store of the checkout at `root`, and drops entries
  /// older than ``retainedSeconds``. An entry that can't be written leaves the span to the
  /// directory its end runs from.
  public func record(spanID: String, root: URL) {}

  /// The checkout whose store holds `spanID`'s start; `nil` when no entry names it.
  public func root(spanID: String) -> URL? {
    nil
  }
}
