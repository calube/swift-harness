import Foundation

/// When a `qa run` inside a `swiftgate run`'s box must be done: a post-merge or at-base run by
/// the cutoff, the `--final` pass by the box's end. A row that can't finish before it isn't
/// started, and a command row that starts gets no more than the time left.
public struct QARunDeadline: Sendable, Equatable {
  /// What a flow row is expected to take when no run measured it. The send-money trial's flow rows
  /// took 53 to 124 s, each mostly leasing, booting and installing.
  public static let flowFloor: Duration = .seconds(60)

  public let at: Date
  /// "the run's cutoff" or "the run's box end", for the message a refused row carries.
  public let name: String

  public init(at: Date, name: String) {
    self.at = at
    self.name = name
  }

  /// The cutoff for a post-merge or at-base run, the box's end for the `--final` pass.
  public static func of(_ box: RunTimeBox, final: Bool) -> QARunDeadline {
    final
      ? QARunDeadline(at: box.deadlines.endsAt, name: "the run's box end")
      : QARunDeadline(at: box.deadlines.cutoffAt, name: "the run's cutoff")
  }

  /// The name a `qa run --deadline` carries in a refused row's message.
  public static let optionName = "its --deadline"

  /// A `qa run --deadline`: an ISO 8601 time, or whole seconds from `now`; `nil` when `text` is
  /// neither, or names no time after `now`.
  public static func parse(_ text: String, now: Date) -> QARunDeadline? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let at: Date
    if let seconds = Int(trimmed) {
      at = now.addingTimeInterval(TimeInterval(seconds))
    } else if let date = try? Date(trimmed, strategy: .iso8601) {
      at = date
    } else {
      return nil
    }
    guard at > now else { return nil }
    return QARunDeadline(at: at, name: optionName)
  }

  /// The earlier of 2 deadlines; `nil` when both are.
  public static func earlier(_ first: QARunDeadline?, _ second: QARunDeadline?) -> QARunDeadline? {
    guard let first, let second else { return first ?? second }
    return second.at < first.at ? second : first
  }

  /// Whether a row may start at `now`, and with how long.
  public enum Admission: Sendable, Equatable {
    /// Start it; a command gets at most `left`.
    case run(left: Duration)
    /// Don't: the row reads `unverified` with this message.
    case refuse(String)
  }

  /// - Parameter expectedMilliseconds: what the row took when a run recorded it; a flow row with
  ///   none is expected to take ``flowFloor``, any other row nothing.
  public func admit(layer: ValidationLayer, expectedMilliseconds: Int?, now: Date) -> Admission {
    let milliseconds = Int64((at.timeIntervalSince(now) * 1000).rounded())
    let when = at.formatted(.iso8601)
    guard milliseconds > 0 else {
      return .refuse("not started: \(name) at \(when) has passed")
    }
    let left = Duration.milliseconds(milliseconds)
    let expected =
      expectedMilliseconds.map { Duration.milliseconds($0) }
      ?? (layer == .flow ? Self.flowFloor : nil)
    if let expected, expected >= left {
      let measured = expectedMilliseconds != nil ? "its measured" : "a flow row's least"
      return .refuse(
        "not started: \(Self.seconds(left)) s left before \(name) at \(when), under "
          + "\(measured) \(Self.seconds(expected)) s")
    }
    return .run(left: left)
  }

  /// Whole seconds, rounded up.
  private static func seconds(_ duration: Duration) -> Int64 {
    let (whole, fraction) = duration.components
    return whole + (fraction > 0 ? 1 : 0)
  }
}
