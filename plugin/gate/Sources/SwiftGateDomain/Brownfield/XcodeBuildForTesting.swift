/// The step a build-only `xcode` area's slice runs in place of its `build`: its `test` command
/// with `build-for-testing` as the action. Its test targets then compile against the scheme and
/// destination they run on at merge, and no test runs.
public enum XcodeBuildForTesting {
  public static let action = "build-for-testing"

  /// `area` with its `build` swapped for ``command(fromTest:)``; `nil` when `area` isn't `xcode`
  /// or its `test` can't be rewritten, so the slice keeps its plain build.
  public static func area(_ area: BrownfieldArea) -> BrownfieldArea? {
    guard area.kind == .xcode, let test = area.test, let command = command(fromTest: test) else {
      return nil
    }
    return BrownfieldArea(
      name: area.name, root: area.root, language: area.language, kind: area.kind,
      test: area.test, testFiles: area.testFiles, lint: area.lint, build: command, e2e: area.e2e,
      testGlobs: area.testGlobs, packs: area.packs, xcode: area.xcode)
  }

  /// `template` with its 1 `test` action replaced; `nil` unless `template` is 1 `xcodebuild`
  /// invocation with exactly 1 `test` action, no placeholder and no option that only a test run
  /// takes.
  public static func command(fromTest template: String) -> String? {
    let commands = ShellSyntax.simpleCommands(in: template)
    guard !template.contains("{"), commands.count == 1, let command = commands.first,
      command.name == "xcodebuild",
      command.redirectTargets.isEmpty,
      !command.arguments.contains(where: isTestRunOption)
    else { return nil }
    let actions = command.arguments.indices.filter { index in
      command.arguments[index] == "test"
        && (index == 0 || !takesValue(command.arguments[index - 1]))
    }
    // The action is matched in the parsed words, then replaced in the text as written, so a
    // quoted argument keeps its quotes; a second bare `test` in the text would make that ambiguous.
    let bare = template.ranges(ofBareWord: "test")
    guard actions.count == 1, bare.count == 1, let range = bare.first else { return nil }
    return template.replacingCharacters(in: range, with: action)
  }

  /// Options that only change how tests run; `build-for-testing` rejects or ignores them, so a
  /// command holding one keeps its plain build.
  private static let testRunOptionPrefixes = [
    "-only-testing", "-skip-testing", "-only-test-configuration", "-skip-test-configuration",
    "-test-iterations", "-retry-tests-on-failure", "-run-tests-until-failure",
    "-test-repetition-relaunch-enabled", "-parallel-testing-", "-maximum-concurrent-test-",
    "-maximum-parallel-testing-workers", "-test-timeouts-enabled",
    "-default-test-execution-time-allowance", "-maximum-test-execution-time-allowance",
    "-collect-test-diagnostics", "-test-enumeration-", "-enumerate-tests", "-testLanguage",
    "-testRegion", "-xctestrun",
  ]

  private static func isTestRunOption(_ word: String) -> Bool {
    testRunOptionPrefixes.contains { word.hasPrefix($0) }
  }

  /// `xcodebuild` flags that take no value, so the word after one can be an action.
  private static let flags: Set<String> = [
    "-quiet", "-verbose", "-json", "-dry-run", "-n", "-skipMacroValidation",
    "-skipPackagePluginValidation", "-skipPackageSignatureValidation", "-skipPackageUpdates",
    "-skipUnavailableActions", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
    "-hideShellScriptEnvironment", "-parallelizeTargets", "-disableAutomaticPackageResolution",
    "-onlyUsePackageVersionsFromResolvedFile", "-disablePackageRepositoryCache",
    "-showBuildTimingSummary",
  ]

  static func takesValue(_ previous: String) -> Bool {
    previous.hasPrefix("-") && !flags.contains(previous)
  }
}

extension String {
  /// Where `word` stands alone, unquoted: between whitespace or the text's ends.
  func ranges(ofBareWord word: String) -> [Range<String.Index>] {
    var found: [Range<String.Index>] = []
    var start = startIndex
    while let range = range(of: word, range: start..<endIndex) {
      let before =
        range.lowerBound == startIndex || self[index(before: range.lowerBound)].isWhitespace
      let after = range.upperBound == endIndex || self[range.upperBound].isWhitespace
      if before && after { found.append(range) }
      start = range.upperBound
    }
    return found
  }
}
