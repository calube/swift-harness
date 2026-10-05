/// An `xcodebuild test` run that ended before any test could run because the simulator would not
/// launch the test runner, such as a device busy with another session's launch. It says nothing
/// about the code under test, so a caller retries it and never reads it as a failing test.
public enum TestRunnerLaunchFailure {
  /// What `xcodebuild` prints when the simulator refuses the runner: its own summary, then the
  /// simulator's error.
  static let markers = [
    "Failed to install or launch the test runner", "Simulator device failed to launch",
  ]
  /// SpringBoard's reason when the device is still busy with an earlier launch.
  static let busyMarkers = ["for reason: Busy", "BSErrorCodeDescription = Busy"]

  /// Why the runner didn't launch, in 1 line, or `nil` when `output` shows no launch failure.
  public static func reason(in output: String) -> String? {
    guard markers.contains(where: output.contains) else { return nil }
    return busyMarkers.contains(where: output.contains)
      ? "the test runner failed to launch: the simulator was busy"
      : "the test runner failed to launch"
  }
}
