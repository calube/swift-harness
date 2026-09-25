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

extension Fixture {
  static func text(_ relativePath: String) throws -> String {
    String(decoding: try data(relativePath), as: UTF8.self)
  }

  /// This checkout's root, for tests that run real tools against `examples/`.
  static let checkoutRoot =
    directory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
