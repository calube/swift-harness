import Foundation

/// Discover's half of reading test failures per test: an area's `test` and `test_files` commands
/// ask their runner for a report the baseline keys on, so 1 test failing at the merge base can't
/// exempt every other failure in the step. Each request is 1 a captured run proved; a command
/// this recognises nothing in runs as it was, and its failures stay the whole step's.
enum TestReportRequests {
  static func requesting(_ area: ProposedArea, in tree: TrackedTreeSnapshot) -> ProposedArea {
    var commands = area.commands
    for step in [AreaStep.test, .testFiles] {
      guard let command = commands[step] else { continue }
      commands[step] = Sourced(
        value: requesting(command.value, area: area, tree: tree), source: command.source,
        confidence: command.confidence)
    }
    return area.replacing(commands: commands, missing: area.missing)
  }

  static func requesting(_ command: String, area: ProposedArea, tree: TrackedTreeSnapshot)
    -> String
  {
    let command = GoTestReport.requestingJSON(command)
    // A command already naming a report, or chaining several, is the repository's own choice.
    guard !command.contains(AreaCommandExpansion.junitPlaceholder),
      !["&&", "||", ";", "|", "`", "$("].contains(where: command.contains)
    else { return command }
    let words = command.split(separator: " ").map(String.init)
    let start = words.firstIndex { !isAssignment($0) } ?? words.endIndex
    guard start < words.endIndex else { return command }
    let tool = words[start]
    let rewritten =
      pytest(words, start: start) ?? swiftTest(words, start: start)
      ?? cargoTest(words, start: start) ?? rspec(words, start: start, area: area, tree: tree)
      ?? node(words, start: start, area: area, tree: tree)
    if let rewritten { return rewritten.joined(separator: " ") }
    if tool == "gradle" || tool.hasSuffix("gradlew") {
      return gradle(words, start: start).map {
        collecting($0, reports: "*/build/test-results/*", named: "*.xml")
      } ?? command
    }
    if tool == "mvn" || tool.hasSuffix("mvnw"), words.contains("test") {
      return collecting(command, reports: "*/target/surefire-reports/*", named: "TEST-*.xml")
    }
    return command
  }

  /// `pytest`, run directly or through `python -m`, `uv run`, `poetry run` or the like, writes
  /// JUnit with `--junitxml`.
  private static func pytest(_ words: [String], start: Int) -> [String]? {
    guard
      let index = words.indices.first(where: {
        $0 >= start && CICommandMining.basename(words[$0]) == "pytest"
      }),
      index == start || ["-m", "run", "exec"].contains(words[index - 1]),
      !words.contains(where: { $0.hasPrefix("--junitxml") || $0.hasPrefix("--junit-xml") })
    else { return nil }
    return inserting(["--junitxml={junit}"], after: index, in: words)
  }

  /// `swift test` writes XCTest's cases to `--xunit-output` only under `--parallel`, and Swift
  /// Testing's beside it.
  private static func swiftTest(_ words: [String], start: Int) -> [String]? {
    guard words.count > start + 1, words[start] == "swift", words[start + 1] == "test",
      !words.contains(where: { $0.hasPrefix("--xunit-output") || $0 == "--no-parallel" })
    else { return nil }
    let parallel = words.contains("--parallel") ? [] : ["--parallel"]
    return inserting(parallel + ["--xunit-output", "{junit}"], after: start + 1, in: words)
  }

  /// cargo stops at the first test target that fails, so a target failing at the merge base
  /// would hide every target after it; libtest's own output names each result.
  private static func cargoTest(_ words: [String], start: Int) -> [String]? {
    guard words.count > start + 1, words[start] == "cargo", words[start + 1] == "test" else {
      return nil
    }
    return words.contains("--no-fail-fast")
      ? words : inserting(["--no-fail-fast"], after: start + 1, in: words)
  }

  /// RSpec writes JUnit only through `rspec_junit_formatter`, so only an area that bundles it
  /// asks; progress stays on for the output's tail.
  private static func rspec(
    _ words: [String], start: Int, area: ProposedArea, tree: TrackedTreeSnapshot
  ) -> [String]? {
    guard
      let index = words.indices.first(where: {
        $0 >= start && CICommandMining.basename(words[$0]) == "rspec"
      }),
      index == start || words[index - 1] == "exec",
      !words.contains("--out"),
      ["Gemfile.lock", "Gemfile"].contains(where: {
        text(tree, ManifestPaths.join(area.root, $0))?.contains("rspec_junit_formatter") == true
      })
    else { return nil }
    return inserting(
      ["--format", "progress", "--format", "RspecJunitFormatter", "--out", "{junit}"],
      after: index, in: words)
  }

  /// `npm run test` or `pnpm run test` whose script is 1 vitest or jest run. vitest keeps its
  /// default reporter beside JUnit; jest writes JUnit only through `jest-junit`, so only an area
  /// that depends on it asks, and its suites that fail to load are reported too.
  private static func node(
    _ words: [String], start: Int, area: ProposedArea, tree: TrackedTreeSnapshot
  ) -> [String]? {
    let manager = words[start]
    guard area.kind == .node, ["npm", "pnpm"].contains(manager) else { return nil }
    let scriptAt: Int
    if words.count > start + 2, words[start + 1] == "run", words[start + 2] == "test" {
      scriptAt = start + 2
    } else if words.count > start + 1, words[start + 1] == "test" {
      scriptAt = start + 1
    } else {
      return nil
    }
    let manifest = ManifestPaths.join(area.root, "package.json")
    guard let data = tree.read(manifest),
      let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let script = (package["scripts"] as? [String: Any])?["test"] as? String,
      NodeReader.takesFiles(script)
    else { return nil }
    let runners = Set(
      script.split(separator: " ").map { word in
        var name = CICommandMining.basename(String(word))
        if name.hasSuffix(".js") { name.removeLast(3) }
        return name
      })
    // npm hands the script only the arguments after `--`.
    var at = scriptAt
    var separator: [String] = []
    if manager == "npm" {
      if words.count > scriptAt + 1, words[scriptAt + 1] == "--" {
        at = scriptAt + 1
      } else {
        separator = ["--"]
      }
    }
    if runners.contains("vitest") {
      let flags = ["--reporter=default", "--reporter=junit", "--outputFile.junit={junit}"]
      return inserting(separator + flags, after: at, in: words)
    }
    guard runners.contains("jest"), dependsOnJestJUnit(area: area, tree: tree) else { return nil }
    let environment = [
      "JEST_JUNIT_OUTPUT_FILE={junit}", "JEST_JUNIT_REPORT_TEST_SUITE_ERRORS=true",
    ]
    let flags = inserting(
      separator + ["--reporters=default", "--reporters=jest-junit"], after: at, in: words)
    return Array(flags[..<start]) + environment + Array(flags[start...])
  }

  /// Whether the area's `package.json`, or 1 above it such as a workspace root's, lists
  /// `jest-junit`.
  private static func dependsOnJestJUnit(area: ProposedArea, tree: TrackedTreeSnapshot) -> Bool {
    ManifestPaths.ancestors(area.root).contains { directory in
      guard let data = tree.read(ManifestPaths.join(directory, "package.json")),
        let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return false }
      return ["dependencies", "devDependencies"].contains {
        (package[$0] as? [String: Any])?["jest-junit"] != nil
      }
    }
  }

  /// A Gradle command running a test task, with `--continue` so a module whose tests fail
  /// doesn't keep the next module's tests from running.
  private static func gradle(_ words: [String], start: Int) -> String? {
    let runsTests = words[(start + 1)...].contains { word in
      guard !word.hasPrefix("-"), let task = word.split(separator: ":").last else { return false }
      return task == "test" || task.hasSuffix("Test") || task.hasSuffix("Tests")
    }
    guard runsTests else { return nil }
    return (words.contains("--continue") ? words : words + ["--continue"])
      .joined(separator: " ")
  }

  /// Gradle and Maven write 1 report per test class into each module's build directory, and
  /// neither takes a flag that moves it. So `{junit}` becomes a directory, and the reports
  /// this run wrote, newer than that directory, are copied into it; an older report is a
  /// test task that didn't run.
  private static func collecting(_ command: String, reports path: String, named name: String)
    -> String
  {
    "mkdir -p {junit} && \(command); status=$?; find . -path '\(path)' -name '\(name)'"
      + " -newer {junit} -exec cp {} {junit} ';'; exit $status"
  }

  private static func inserting(_ inserted: [String], after index: Int, in words: [String])
    -> [String]
  {
    Array(words[...index]) + inserted + Array(words[(index + 1)...])
  }

  private static func isAssignment(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
  }

  private static func text(_ tree: TrackedTreeSnapshot, _ path: String) -> String? {
    tree.read(path).map { String(decoding: $0, as: UTF8.self) }
  }
}
