import Foundation

/// Whether a `test`/`check` tier that builds or runs Swift (T1's `swift build`/`swift test`,
/// T2/T3's `xcodebuild`) should end BLOCKED under the selected Xcode, so a build under the wrong
/// toolchain fails for a named machine reason instead of failing every test in it as if the code
/// were wrong. T0 parses source with SwiftSyntax and never touches the toolchain, so it never
/// calls this.
public enum XcodePinGate {
  /// The message a `doctor.xcode-pin` finding should carry, or `nil` when the tier may proceed.
  /// Reuses ``Doctor/matchesPin(installed:pin:)`` exactly, never a second matcher. An unreadable
  /// `installed` version is BLOCKED, the same choice `Doctor.evaluate` makes for a machine it
  /// can't inspect. `pin` blank (an unset pin) never blocks; `Config` never constructs one blank,
  /// but this checks it the way `doctor` would if it fielded one.
  public static func message(installed: String?, pin: String) -> String? {
    guard !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    switch installed {
    case nil:
      return
        "xcodebuild -version could not be read; is Xcode installed and selected (xcode-select -p)?"
    case let installed? where !Doctor.matchesPin(installed: installed, pin: pin):
      return
        "Xcode \(installed) is selected but \(Config.fileName) pins \(pin); select Xcode \(pin) "
        + "(xcode-select -s) or move the pin deliberately"
    default:
      return nil
    }
  }
}
