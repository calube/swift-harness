import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("PackageSettings")
struct PackageSettingsTests {
  @Test(
    "default isolation is read from both the setting and unsafe flags — catches a MainActor Core hidden behind either spelling"
  )
  func readsIsolation() throws {
    let settings = try PackageSettings(
      dumpPackageJSON: Fixture.data("SwiftPM/dump-package-main-actor-core.json"))
    #expect(settings.defaultIsolation == ["FeedCore": "MainActor", "FeedUI": "MainActor"])
  }

  @Test("a package setting nothing reports nothing — catches isolation invented for plain targets")
  func plainPackage() throws {
    let settings = try PackageSettings(
      dumpPackageJSON: Fixture.data("SwiftPM/dump-package-GameEngine.json"))
    #expect(settings.defaultIsolation.isEmpty)
  }
}
