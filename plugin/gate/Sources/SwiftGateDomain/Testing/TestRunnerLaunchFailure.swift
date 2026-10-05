/// An `xcodebuild test` run that ended before any test could run because the simulator would not
/// launch the test runner, such as a device busy with another session's launch. It says nothing
/// about the code under test, so a caller retries it and never reads it as a failing test.
public enum TestRunnerLaunchFailure {
  /// Why the runner didn't launch, in 1 line, or `nil` when `output` shows no launch failure.
  public static func reason(in output: String) -> String? {
    nil
  }
}
