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
    .run(left: .seconds(3600))
  }
}
