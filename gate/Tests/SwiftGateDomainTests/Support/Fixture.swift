import Foundation

/// Recorded tool output under `gate/Tests/Fixtures/`, located relative to this source file so the
/// test targets need no bundled resources.
enum Fixture {
  /// The repository root that fixture paths were normalized to at capture time.
  static let repositoryRoot = "/REPO"

  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Fixtures", directoryHint: .isDirectory)

  static func data(_ relativePath: String) throws -> Data {
    try Data(contentsOf: directory.appending(path: relativePath))
  }

  static let samplePackages = [
    "APIClient", "CounterFeature", "GameEngine", "HTTPClient", "LogClient",
  ]

  static func describe(_ package: String) throws -> Data {
    try data("SwiftPM/describe-\(package).json")
  }
}
