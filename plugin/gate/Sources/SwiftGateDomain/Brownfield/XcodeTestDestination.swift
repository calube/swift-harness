/// The simulator an area's `xcodebuild test` command names by `-destination ...,name=<device>`.
/// Run as written, every session shares that 1 device; the command is instead pointed at a
/// leased clone of it by ``leased(_:udid:)``.
public struct XcodeTestDestination: Sendable, Hashable {
  /// `iPhone 17` from `name=iPhone 17`.
  public let device: String
  /// `26.2` from `OS=26.2`; `nil` when the destination names no version, or names `latest`.
  public let os: String?

  public init(device: String, os: String?) {
    self.device = device
    self.os = os
  }

  /// The simulator `command`'s test run names; `nil` when it runs no test on a named simulator.
  public static func simulator(in command: String) -> XcodeTestDestination? {
    nil
  }

  /// `command` with each `-destination` naming ``simulator(in:)``'s device replaced by
  /// `id=<udid>`; `nil` when it can't be rewritten exactly as written.
  public static func leased(_ command: String, udid: String) -> String? {
    nil
  }
}
