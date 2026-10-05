import Foundation

/// The earliest time an event a build run keeps can carry, so a reader opens no sealed segment
/// that ended before it.
public enum RunViewEventWindow {
  /// How long before its start a build run's events can be: the session that starts a build
  /// also ingests the usage of its messages before `build start` under the run.
  public static let lookback: TimeInterval = 24 * 60 * 60

  /// The earliest of ``lookback`` before the build run's start, each named gate run's start, and
  /// the plan's launch when the run keeps what came before it. Run ids start with their UTC
  /// start time to the second, and a gate run's events come at or after it. `nil` when
  /// `buildRun` names no time.
  public static func since(buildRun: String, gateRuns: Set<String>, launchedAt: Date?) -> Date? {
    guard let start = startTime(of: buildRun) else { return nil }
    let earlier = gateRuns.compactMap(startTime(of:)) + [launchedAt].compactMap { $0 }
    return ([start.addingTimeInterval(-lookback)] + earlier).min()
  }

  /// `20261004T045528Z` of `20261004T045528Z-58d28c78`, as a time; `nil` for an id that doesn't
  /// start with one.
  public static func startTime(of runID: String) -> Date? {
    let stamp = Array(runID.prefix { $0 != "-" }.utf8)
    guard stamp.count == 16, stamp[8] == UInt8(ascii: "T"), stamp[15] == UInt8(ascii: "Z")
    else { return nil }
    func number(_ range: Range<Int>) -> Int? {
      let digits = stamp[range]
      guard digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
        return nil
      }
      return digits.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
    }
    guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
      let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15)
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
    let parts = DateComponents(
      year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    // A date the calendar had to roll over, such as month 13, is no run's start.
    guard parts.isValidDate(in: calendar) else { return nil }
    return calendar.date(from: parts)
  }
}
