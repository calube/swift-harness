import Testing
@testable import SwiftGateCLI

@Suite("swiftgate --version")
struct VersionTests {
  @Test("--version reports the CLI's semver, so hooks can detect a stale cached binary")
  func versionCommandPrintsSemver() throws {
    let version = try #require(SwiftGate.configuration.version)
    #expect(version == SwiftGateVersion.current)
    #expect(version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
  }
}
