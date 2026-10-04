import Foundation
import SwiftGateDomain

extension Fixture {
  /// 1 captured `AreaRuns/<ecosystem>/<case>/` run as the live area runner reports it: `stdout`
  /// then `stderr` as the tail, since the runner sends both down 1 stream, and `junit.xml` when
  /// the runner wrote one.
  public static func areaRun(_ relativeCase: String) throws -> AreaCommandOutcome {
    let base = "AreaRuns/\(relativeCase)/"
    let status = try text(base + "exit").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let exit = Int32(status) else {
      throw AreaRunFixtureError(detail: "\(base)exit holds `\(status)`, not a status")
    }
    let tail = try text(base + "stdout") + text(base + "stderr")
    if exit == 0 { return .passed }
    if exit > 128 { return .crashed(signal: exit - 128, tail: tail) }
    return .failed(exit: exit, tail: tail, junit: try? data(base + "junit.xml"))
  }
}

public struct AreaRunFixtureError: Error, Sendable, CustomStringConvertible {
  public let detail: String

  public var description: String { detail }
}
