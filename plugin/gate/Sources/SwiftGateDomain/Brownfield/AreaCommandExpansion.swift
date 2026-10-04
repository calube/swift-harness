import Foundation

/// 1 area command with its placeholders filled, ready to become an ``AreaCommandRequest``.
public struct ExpandedAreaCommand: Sendable, Equatable {
  public let command: String
  /// `true` when the template has no `{tests}`: the command runs every test it covers rather
  /// than the selected ones, and whoever reports its outcome must say so.
  public let runsWhole: Bool
  /// Set exactly when the template held `{junit}`.
  public let junitPath: String?

  public init(command: String, runsWhole: Bool, junitPath: String?) {
    self.command = command
    self.runsWhole = runsWhole
    self.junitPath = junitPath
  }
}

/// An area command expanded into a request, plus whether it narrowed to the selected tests.
public struct PreparedAreaCommand: Sendable, Equatable {
  public let request: AreaCommandRequest
  public let runsWhole: Bool

  public init(request: AreaCommandRequest, runsWhole: Bool) {
    self.request = request
    self.runsWhole = runsWhole
  }
}

/// Fills `{files}`, `{tests}` and `{junit}` in an area's command. Every value is single-quoted
/// for `/bin/sh`, so a path holding a space or a quote stays 1 argument.
public enum AreaCommandExpansion {
  public static let filesPlaceholder = "{files}"
  public static let testsPlaceholder = "{tests}"
  public static let junitPlaceholder = "{junit}"

  /// `argument` as 1 `/bin/sh` word.
  public static func shellQuoted(_ argument: String) -> String {
    "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// - Parameters:
  ///   - files: inserted space-separated, each quoted, in place of `{files}`.
  ///   - tests: inserted the same way in place of `{tests}`.
  ///   - junitPath: inserted quoted in place of `{junit}`.
  public static func expand(
    _ template: String, files: [String], tests: [String], junitPath: String
  ) -> ExpandedAreaCommand {
    let quoted = { (values: [String]) in values.map(shellQuoted).joined(separator: " ") }
    let values = [
      filesPlaceholder: quoted(files), testsPlaceholder: quoted(tests),
      junitPlaceholder: shellQuoted(junitPath),
    ]
    // 1 pass, so a value that itself spells a placeholder is never expanded again.
    var command = ""
    var rest = template[...]
    while let open = rest.firstIndex(of: "{") {
      command += rest[..<open]
      rest = rest[open...]
      if let (placeholder, value) = values.first(where: { rest.hasPrefix($0.key) }) {
        command += value
        rest = rest.dropFirst(placeholder.count)
      } else {
        command.append("{")
        rest = rest.dropFirst()
      }
    }
    command += rest
    let usesJUnit = template.contains(junitPlaceholder)
    return ExpandedAreaCommand(
      command: command, runsWhole: !template.contains(testsPlaceholder),
      junitPath: usesJUnit ? junitPath : nil)
  }

  /// The command `area` configures for `step`. `test_files` falls back to `test`, which then runs
  /// whole. `generate` comes from the area's Xcode inclusion, never from a key, so it is `nil`.
  public static func template(for step: AreaStep, in area: BrownfieldArea) -> String? {
    switch step {
    case .test: area.test
    case .testFiles: area.testFiles ?? area.test
    case .lint: area.lint
    case .build: area.build
    case .e2e: area.e2e
    case .generate: nil
    }
  }

  /// Where `{junit}` points for `area`'s `step`: under the worktree's git dir, so the user's tree
  /// never shows the report.
  public static func junitPath(layout: BrownfieldStateLayout, area: String, step: AreaStep)
    -> String
  {
    layout.worktreeRoot.appending(path: "junit/\(area).\(step.rawValue).xml").path(
      percentEncoded: false)
  }

  /// `nil` when `area` has no command for `step`.
  /// - Parameters:
  ///   - repositoryRoot: absolute; the command runs in `area.root` under it.
  ///   - files: repository-relative; each is passed relative to the area root.
  public static func prepare(
    area: BrownfieldArea, step: AreaStep, repositoryRoot: String, files: [String],
    tests: [String], junitPath: String, deadline: Duration, environment: [String: String]
  ) -> PreparedAreaCommand? {
    guard let template = template(for: step, in: area) else { return nil }
    let areaComponents = components(area.root)
    let expanded = expand(
      template, files: files.map { relative(components($0), to: areaComponents) }, tests: tests,
      junitPath: junitPath)
    let root = ([repositoryRoot] + areaComponents).joined(separator: "/")
    return PreparedAreaCommand(
      request: AreaCommandRequest(
        area: area.name, step: step, command: expanded.command, workingDirectory: root,
        deadline: deadline, environment: environment, junitPath: expanded.junitPath),
      runsWhole: expanded.runsWhole)
  }

  private static func components(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init).filter { $0 != "." }
  }

  private static func relative(_ path: [String], to root: [String]) -> String {
    let shared = zip(path, root).prefix { $0 == $1 }.count
    let parts = Array(repeating: "..", count: root.count - shared) + path.dropFirst(shared)
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }
}
