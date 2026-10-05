import Foundation

/// An `xcodebuild` test run read per test: its result bundle's test tree, as
/// `xcresulttool get test-results tests` prints it, turned into the JUnit the baseline keys on.
public enum XcresultTestReport {
  /// 1 `<testcase>` per case, its classname the test bundle and its name `<Suite>/<method>()`;
  /// `nil` when the tree doesn't parse, holds no case, or holds a failure no test owns, such as
  /// a test runner that couldn't launch. Such a run failed as the whole step.
  public static func junit(fromTests data: Data) -> Data? {
    nil
  }
}
