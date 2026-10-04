import Foundation

/// cargo writes no JUnit, but libtest names every test's result, so a cargo area's failures can
/// be read per test rather than as the whole step.
public enum CargoTestReport {
  /// A JUnit document of the tests `output`'s libtest results name.
  public static func junit(fromOutput output: String) -> Data? {
    nil
  }
}
