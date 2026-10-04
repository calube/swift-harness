import Foundation

/// Recorded tool output under `gate/Tests/Fixtures/`, located relative to this source file so the
/// test targets need no bundled resources.
public enum Fixture {
  /// The repository root that fixture paths were normalized to at capture time.
  public static let repositoryRoot = "/REPO"

  /// The `gate/` package directory.
  public static let gateDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  public static let directory = gateDirectory.appending(
    path: "Tests/Fixtures", directoryHint: .isDirectory)

  /// This checkout's root, for tests that run real tools against `examples/`.
  public static let checkoutRoot = gateDirectory.deletingLastPathComponent()

  public static func data(_ relativePath: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: relativePath))
  }

  public static func text(_ relativePath: String) throws -> String {
    String(decoding: try data(relativePath), as: UTF8.self)
  }

  public static let samplePackages = [
    "APIClient", "AccessibilityIDs", "CounterFeature", "GameEngine", "HTTPClient", "LogClient",
  ]

  public static func describe(_ package: String) throws -> Data {
    try data("SwiftPM/describe-\(package).json")
  }
}
