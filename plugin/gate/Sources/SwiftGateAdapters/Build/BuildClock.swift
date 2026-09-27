import Foundation

/// The wall clock the build commands read. The domain never reads one; tests inject a fixed date
/// so a time-budget phase is reproducible.
public protocol BuildClock: Sendable {
  func now() -> Date
}

public struct LiveBuildClock: BuildClock {
  public init() {}

  public func now() -> Date {
    Date()  // swiftgate:allow det.date-init — the live clock injected at the CLI edge
  }
}
