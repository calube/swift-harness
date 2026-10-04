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
  ///
  /// An empty id still parses, so `test:` reads unresolved instead of going to `/bin/sh`, whose
  /// `test` builtin would exit 0.
  public static func parse(_ check: String) -> AcceptanceTestReference? {
    let text = check.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix(keyword), let colon = text.firstIndex(of: ":") else { return nil }
    let head = text[text.index(text.startIndex, offsetBy: keyword.count)..<colon]
    let area: String?
    if head.isEmpty {
      area = nil
    } else {
      guard head.first?.isWhitespace == true else { return nil }
      let name = head.trimmingCharacters(in: .whitespaces)
      guard let first = name.first, first.isLetter,
        name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
      else { return nil }
      area = name
    }
    let id = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    return AcceptanceTestReference(area: area, id: id)
  }

  /// The command that runs only this test, from the area it names or the 1 area that runs tests.
  ///
  /// - Parameters:
  ///   - junitPath: what `{junit}` expands to when the area's command takes it.
  ///   - resultBundlePath: where an `xcode` area's `-only-testing:` command writes its result
  ///     bundle, since `xcodebuild` writes no JUnit report.
  public func resolve(
    in areas: [BrownfieldArea], junitPath: String?, resultBundlePath: String? = nil
  ) -> Result<AcceptanceTestCommand, AcceptanceTestUnresolved> {
    func unresolved(_ reason: String) -> Result<AcceptanceTestCommand, AcceptanceTestUnresolved> {
      .failure(AcceptanceTestUnresolved(reason: reason))
    }
    guard !id.isEmpty, !id.contains(where: \.isWhitespace) else {
      return unresolved(
        "`\(Self.keyword):` names no test: write 1 id with no spaces, such as "
          + "`test: <Target>/<Class>/<method>`")
    }
    let area: BrownfieldArea
    if let name = self.area {
      guard let named = areas.first(where: { $0.name == name }) else {
        return unresolved(
          "`\(name)` is no area in the config; the areas are "
            + areas.map { "`\($0.name)`" }.joined(separator: ", "))
      }
      area = named
    } else {
      let running = areas.filter { $0.test != nil || $0.testFiles != nil }
      switch running.count {
      case 0:
        return unresolved("no area in the config has a test command to run `\(id)` with")
      case 1:
        area = running[0]
      default:
        return unresolved(
          "\(running.count) areas run tests ("
            + running.map { "`\($0.name)`" }.joined(separator: ", ")
            + "); name 1 as `\(Self.keyword) <area>: \(id)`")
      }
    }
    guard let (command, bundle) = command(for: area, junitPath: junitPath, resultBundlePath)
    else {
      return unresolved(
        "area `\(area.name)` can't run 1 test: "
          + (area.kind == .xcode
            ? "it has no test command to add `-only-testing:` to"
            : "its test_files has no `{tests}` or `{files}` to narrow its tests to `\(id)`"))
    }
    return .success(
      AcceptanceTestCommand(
        area: area.name, root: area.root, command: command, resultBundlePath: bundle))
  }

  /// `test_files` with `{tests}`, then an `xcode` area's `test` with `-only-testing:` and any
  /// `-resultBundlePath`, then `test_files` with `{files}`; with the bundle the command writes.
  private func command(
    for area: BrownfieldArea, junitPath: String?, _ resultBundlePath: String?
  ) -> (String, String?)? {
    let quoted = ChangedTestIDs.shellQuoted(id)
    let junit = junitPath.map(ChangedTestIDs.shellQuoted)
    if let template = area.testFiles, template.contains("{tests}") {
      let selector = AreaTestID(name: id, selector: id, file: id, line: 1)
      return (
        ChangedTestIDs.expand(
          template, tests: ChangedTestIDs.testsArgument(kind: area.kind, ids: [selector]),
          files: quoted, junit: junit), nil
      )
    }
    if area.kind == .xcode, let test = area.test {
      let command =
        ChangedTestIDs.expand(test, tests: nil, files: nil, junit: junit)
        + " -only-testing:\(quoted)"
      guard let resultBundlePath else { return (command, nil) }
      return (
        command + " -resultBundlePath \(ChangedTestIDs.shellQuoted(resultBundlePath))",
        resultBundlePath
      )
    }
    if let template = area.testFiles, template.contains("{files}") {
      return (ChangedTestIDs.expand(template, tests: quoted, files: quoted, junit: junit), nil)
    }
    return nil
  }
}

/// 1 test's command, expanded and ready for `/bin/sh -c`.
public struct AcceptanceTestCommand: Sendable, Equatable {
  public let area: String
  /// The area's root, repository-relative; the command runs there.
  public let root: String
  public let command: String
  /// The result bundle the command writes, whose test tree shows whether a test ran; `nil` when
  /// it writes none.
  public let resultBundlePath: String?

  public init(area: String, root: String, command: String, resultBundlePath: String? = nil) {
    self.area = area
    self.root = root
    self.command = command
    self.resultBundlePath = resultBundlePath
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
