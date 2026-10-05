/// The step a build-only `xcode` area's slice runs in place of its `build`: its `test` command
/// with `build-for-testing` as the action. Its test targets then compile against the scheme and
/// destination they run on at merge, and no test runs.
public enum XcodeBuildForTesting {
  /// `area` with its `build` swapped for ``command(fromTest:)``; `nil` when `area` isn't `xcode`
  /// or its `test` can't be rewritten, so the slice keeps its plain build.
  public static func area(_ area: BrownfieldArea) -> BrownfieldArea? {
    nil
  }

  /// `template` with its 1 `test` action replaced; `nil` unless `template` is 1 `xcodebuild`
  /// invocation with exactly 1 `test` action, no placeholder and no option that only a test run
  /// takes.
  public static func command(fromTest template: String) -> String? {
    nil
  }
}
