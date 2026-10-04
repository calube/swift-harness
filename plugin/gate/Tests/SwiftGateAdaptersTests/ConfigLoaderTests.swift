import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("ConfigLoader")
struct ConfigLoaderTests {
  let loader = ConfigLoader()

  func makeRepository() throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-config-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("repository without .swiftgate.toml loads nil — catches hooks running in non-harness repos")
  func missingFileIsNil() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try loader.load(repositoryRoot: root) == nil)
  }

  @Test("config file is read from the repository root — catches loading from the wrong directory")
  func loadsFromRoot() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(TOMLConfigDecoderTests.minimal.utf8)
      .write(to: root.appending(path: ".swiftgate.toml"))
    let config = try #require(try loader.load(repositoryRoot: root))
    #expect(config.appScheme == "App")
  }

  @Test(
    "unreadable config is BLOCKED, invalid config is RED — catches env faults sent to code fixes")
  func verdicts() throws {
    let root = try makeRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appending(path: ".swiftgate.toml"), withIntermediateDirectories: false)
    #expect {
      _ = try loader.load(repositoryRoot: root)
    } throws: { error in
      guard let error = error as? ConfigLoadError, case .unreadable = error else { return false }
      return error.verdict == .blocked
    }
    let invalid = ConfigLoadError.invalid(
      ConfigValidationError(issues: [.missingKey(path: "xcode")]))
    #expect(invalid.verdict == .red)
  }
}
