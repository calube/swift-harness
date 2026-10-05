/// The build prove runs in its scratch tree before an area's changed tests, timed on its own so a
/// slow prove says whether building or testing took the time. A build that fails proves every
/// changed test at once, as each run alone would only fail the same build again.
public enum ProveBuild {
  /// The command that builds what `template`, an area's `test_files`, would build before it runs
  /// tests; `nil` when the area's kind has no such build, or `template` holds anything the
  /// rewrite can't carry over, so prove runs its tests as before.
  public static func command(fromTestFiles template: String, kind: AreaKind) -> String? {
    guard kind == .swiftpm else { return nil }
    return swiftPM(template)
  }

  /// `swift test` options that only pick, run or report tests: `swift build` takes none of them,
  /// and leaving them out changes nothing the test run then builds.
  private static let testOnlyWithValue: Set<String> = [
    "--filter", "--skip", "--xunit-output", "--num-workers", "--attachments-path",
  ]
  private static let testOnlyFlags: Set<String> = ["--parallel", "--no-parallel"]
  /// `swift test` options that change what it builds or replace the run, so a build without them
  /// would be another build than the test run's.
  private static let changesTheBuild: Set<String> = [
    "--enable-code-coverage", "--disable-code-coverage", "--enable-testable-imports",
    "--disable-testable-imports", "--skip-build", "--list-tests", "-l", "--show-codecov-path",
    "--show-code-coverage-path", "--enable-xctest", "--disable-xctest", "--enable-swift-testing",
    "--disable-swift-testing",
  ]

  /// `swift test …` as `swift build --build-tests` with every option kept that isn't test-only.
  private static func swiftPM(_ template: String) -> String? {
    let commands = ShellSyntax.simpleCommands(in: template)
    guard template.drop(while: \.isWhitespace).hasPrefix("swift test"), commands.count == 1,
      let command = commands.first, command.name == "swift", command.assignments.isEmpty,
      command.redirectTargets.isEmpty, command.arguments.first == "test"
    else { return nil }
    var kept: [String] = []
    var words = command.arguments.dropFirst()
    while let word = words.popFirst() {
      let option = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
      if testOnlyWithValue.contains(option) {
        if option == word { _ = words.popFirst() }
        continue
      }
      if testOnlyFlags.contains(word) { continue }
      guard !changesTheBuild.contains(option), !word.contains("{") else { return nil }
      kept.append(word)
    }
    return (["swift", "build", "--build-tests"] + kept.map(quotedIfNeeded)).joined(separator: " ")
  }

  private static func quotedIfNeeded(_ word: String) -> String {
    let plain =
      !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "_./:=@%+,-".contains($0) }
    return plain ? word : AreaCommandExpansion.shellQuoted(word)
  }
}
