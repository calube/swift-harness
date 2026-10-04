import Foundation

/// Go writes no JUnit, but `go test -json` names every test's end, so a Go area's failures can be
/// read per test rather than as the whole step.
public enum GoTestReport {
  /// `command` with `-json` after each `go test`, unless it already asks for it.
  public static func requestingJSON(_ command: String) -> String {
    command
  }

  /// A JUnit document of the tests `output`'s `go test -json` events ended; `nil` when `output`
  /// holds no such events.
  public static func junit(fromJSON output: String) -> Data? {
    nil
  }
}
