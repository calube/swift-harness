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

  /// What `swiftgate test-only` takes as its test: a bare id, `<area>: <id>`, or the acceptance
  /// row's `test <area>: <id>`; `area` is the `--area` it was given, which the text's own wins
  /// over only when `area` is `nil`.
  public static func testOnly(_ text: String, area: String?) -> AcceptanceTestReference {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let row = parse(trimmed) {
      return AcceptanceTestReference(area: area ?? row.area, id: row.id)
    }
    if let colon = trimmed.firstIndex(of: ":") {
      let head = String(trimmed[..<colon])
      if let first = head.first, first.isLetter,
        head.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
      {
        return AcceptanceTestReference(
          area: area ?? head,
          id: trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
      }
    }
    return AcceptanceTestReference(area: area, id: trimmed)
  }

  /// The areas that run tests and hold a test target named as `id`'s first component: a
  /// directory of that name under a test glob's fixed prefix, or under a `swiftpm` area's
  /// `Tests/`. `directoryExists` takes a repository-relative path.
  public static func owningAreas(
    of id: String, in areas: [BrownfieldArea], directoryExists: (String) -> Bool
  ) -> [String] {
    guard let target = id.split(separator: "/").first.map(String.init), !target.isEmpty,
      id.contains("/")
    else { return [] }
    return areas.filter { area in
      guard area.test != nil || area.testFiles != nil else { return false }
      var parents = area.testGlobs.map { glob in
        glob.split(separator: "/").prefix { !$0.contains("*") }.joined(separator: "/")
      }
      if area.kind == .swiftpm {
        parents.append(area.root == "." ? "Tests" : "\(area.root)/Tests")
      }
      return parents.contains { parent in
        directoryExists(parent.isEmpty ? target : "\(parent)/\(target)")
      }
    }.map(\.name)
  }

  /// This reference with its id in the form `area`'s filter matches: a `swiftpm` area's
  /// `--filter` reads `<Target>.<Suite>[/<test>]`, an `xcode` area's `-only-testing:`
  /// `<Target>/<Class>[/<method>]`. The id's first separator is swapped only when the text before
  /// it names a test target `area` holds, so `<Suite>/<test>` keeps its slash.
  public func filterForm(in area: BrownfieldArea, directoryExists: (String) -> Bool)
    -> AcceptanceTestReference
  {
    self
  }

  /// The command that runs only this test, from the area it names or the 1 area that runs tests.
  ///
  /// - Parameters:
  ///   - junitPath: what `{junit}` expands to when the area's command takes it.
  ///   - resultBundlePath: where an `xcode` area's `-only-testing:` command writes its result
  ///     bundle, since `xcodebuild` writes no JUnit report.
  ///   - spelling: how a refusal tells the caller to name the test.
  public func resolve(
    in areas: [BrownfieldArea], junitPath: String?, resultBundlePath: String? = nil,
    spelling: Spelling = .check
  ) -> Result<AcceptanceTestCommand, AcceptanceTestUnresolved> {
    func unresolved(_ reason: String) -> Result<AcceptanceTestCommand, AcceptanceTestUnresolved> {
      .failure(AcceptanceTestUnresolved(reason: reason))
    }
    guard !id.isEmpty, !id.contains(where: \.isWhitespace) else {
      switch spelling {
      case .check:
        return unresolved(
          "`\(Self.keyword):` names no test: write 1 id with no spaces, such as "
            + "`test: <Target>/<Class>/<method>`")
      case .testOnly:
        return unresolved(
          "`\(id)` isn't 1 test id: run 1 test as "
            + "`\(Self.testOnlyCommand(area: "<area>", id: "<Target>/<Class>[/<method>]"))`")
      }
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
        let names = running.map { "`\($0.name)`" }.joined(separator: ", ")
        switch spelling {
        case .check:
          return unresolved(
            "\(running.count) areas run tests (\(names)); name 1 as "
              + "`\(Self.keyword) <area>: \(id)`")
        case .testOnly:
          return unresolved(
            "\(running.count) areas run tests (\(names)), and no 1 of them alone holds the test "
              + "target `\(id.split(separator: "/").first.map(String.init) ?? id)`; run "
              + "`\(Self.testOnlyCommand(area: "<area>", id: id))` with `<area>` the 1 that "
              + "runs it")
        }
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

  /// The `swiftgate test-only` command line that runs `id` in `area`.
  public static func testOnlyCommand(area: String, id: String) -> String {
    "\"$SG\" test-only --area \(area) \(id)"
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

extension AcceptanceTestReference {
  /// Where the reference was written, which sets the form a refusal names.
  public enum Spelling: Sendable, Equatable {
    /// An acceptance row's `test <area>: <id>` check.
    case check
    /// A `swiftgate test-only` command line.
    case testOnly
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
