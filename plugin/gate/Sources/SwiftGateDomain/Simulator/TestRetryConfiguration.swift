/// A scheme or test plan file, as text.
public struct ConfigurationFile: Sendable, Equatable {
  /// Repository-relative.
  public let path: String
  public let contents: String

  public init(path: String, contents: String) {
    self.path = path
    self.contents = contents
  }
}

/// Spec §7.2 rule 3: retrying failed tests hides flakes. `swiftgate` never passes a retry flag,
/// but Xcode also stores "retry on failure" inside schemes (`testRepetitionMode` on the test
/// action) and test plans (`"testRepetitionMode" : "retryOnFailure"`); both use the token matched
/// here, so either form is RED.
public enum TestRetryConfiguration {
  public static let ruleID = "sim.retry-configured"
  static let retryToken = "retryOnFailure"

  public static func findings(in files: [ConfigurationFile]) -> [Finding] {
    files.filter { $0.contents.contains(retryToken) }.compactMap { file in
      // The path and message are never empty, so the report contract cannot reject this.
      try? Finding(
        ruleID: ruleID, severity: .major, file: file.path, line: nil,
        message:
          "\(file.path) retries failed tests (\(retryToken)); a retry turns a flake into a pass. "
          + "Set test repetition to none",
        failureScenario: nil)
    }
  }
}
