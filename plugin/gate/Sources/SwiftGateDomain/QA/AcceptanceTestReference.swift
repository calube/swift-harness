/// An acceptance row's `test: <id>` check: 1 test the row runs through an area's own test
/// command, narrowed to `id`, rather than a command line of its own. `test <area>: <id>` names
/// the area when more than 1 runs tests.
///
/// `id` is what the area's filter takes: `<Target>/<Class>[/<method>]` for an `xcode` area's
/// `-only-testing:`, and whatever the area's `test_files` places in `{tests}` or `{files}`
/// otherwise.
public struct AcceptanceTestReference: Sendable, Equatable {
  public static let keyword = "test"

  /// `nil` when the check names no area.
  public let area: String?
  public let id: String

  public init(area: String?, id: String) {
    self.area = area
    self.id = id
  }

  /// The reference `check` spells, or `nil` when it is not in the test form.
  public static func parse(_ check: String) -> AcceptanceTestReference? {
    nil
  }

  /// The command that runs only this test, from the area it names or the 1 area that runs tests.
  ///
  /// - Parameter junitPath: what `{junit}` expands to when the area's command takes it.
  public func resolve(in areas: [BrownfieldArea], junitPath: String?)
    -> Result<AcceptanceTestCommand, AcceptanceTestUnresolved>
  {
    .failure(AcceptanceTestUnresolved(reason: "not resolved"))
  }
}

/// 1 test's command, expanded and ready for `/bin/sh -c`.
public struct AcceptanceTestCommand: Sendable, Equatable {
  public let area: String
  /// The area's root, repository-relative; the command runs there.
  public let root: String
  public let command: String

  public init(area: String, root: String, command: String) {
    self.area = area
    self.root = root
    self.command = command
  }
}

/// Why no area's command can run a `test:` check.
public struct AcceptanceTestUnresolved: Error, Sendable, Equatable, CustomStringConvertible {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }

  public var description: String { reason }
}
