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

  /// The plugin directory that ships to consumers: `templates/`, `bin/`, `docs/`, `agents/`.
  public static let pluginRoot = gateDirectory.deletingLastPathComponent()

  /// The contributor checkout around the plugin, for tests that read `examples/` or `tests/`.
  public static let checkoutRoot = pluginRoot.deletingLastPathComponent()

  public static func data(_ relativePath: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: relativePath))
  }

  public static func text(_ relativePath: String) throws -> String {
    String(decoding: try data(relativePath), as: UTF8.self)
  }

  public static let samplePackages = [
    "APIClient", "CounterFeature", "GameEngine", "HTTPClient", "LogClient",
  ]

  public static func describe(_ package: String) throws -> Data {
    try data("SwiftPM/describe-\(package).json")
  }
}
