import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured repository's tracked tree, as discover reads it.
private func captured(_ relative: String) throws -> TrackedTreeSnapshot {
  let directory = Fixture.directory.appending(
    path: "Discover/\(relative)", directoryHint: .isDirectory)
  let listing = try String(contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
  let tree = directory.appending(path: "tree", directoryHint: .isDirectory)
  return TrackedTreeSnapshot(
    paths: listing.split(separator: "\n").map(String.init),
    read: { try? Data(contentsOf: tree.appending(path: $0)) })
}

private func starterAreas() throws -> [ProposedArea] {
  Discover.propose(tree: try captured("timed-build-starter"), head: "abc", dirty: []).areas
}

@Suite("discover gives a local package's unit tests an area of their own")
struct DiscoverPackageTestAreasTests {
  static let packages = ["Packages/APIClient", "Packages/AppFeature", "Packages/LogClient"]

  @Test(
    "each local package whose tests the app's scheme doesn't run becomes a swiftpm area with swift test in its own root — catches an app's unit tests that no gate ever runs"
  )
  func packagesTestedApart() throws {
    let areas = try starterAreas()

    let app = try #require(areas.first { $0.kind == .xcode })
    #expect(app.root == ".")
    let packages = areas.filter { $0.kind == .swiftpm }
    #expect(packages.map(\.root).sorted() == Self.packages)
    for package in packages {
      #expect(package.commands[.test]?.value.hasPrefix("swift test ") == true, "\(package.name)")
      #expect(package.commands[.testFiles]?.value.contains("--filter {tests}") == true)
      #expect(package.testGlobs == ["\(package.root)/Tests/**/*.swift"])
    }
    #expect(
      !app.testGlobs.contains { $0.hasPrefix("Packages/") },
      "the app's whole test would run for a package test it never runs: \(app.testGlobs)")
    #expect(app.xcode?.value.packages == Self.packages)
  }

  @Test(
    "a package whose test targets the app's scheme already runs stays in the app's area — catches its tests run twice, once per area"
  )
  func schemeRunPackageStaysAbsorbed() throws {
    let tree = try captured("WezSieTato-ScanNow")
    let scheme = try #require(
      tree.read("ScanNow.xcodeproj/xcshareddata/xcschemes/ScanNow.xcscheme").map {
        String(decoding: $0, as: UTF8.self)
      })
    #expect(scheme.contains("ReferencedContainer = \"container:App\""))

    #expect(SwiftPMReader().areas(in: tree).isEmpty)
    let app = try #require(XcodeReader().areas(in: tree).first)
    #expect(XcodeReader().areas(in: tree).count == 1)
    #expect(app.testGlobs.contains("App/Tests/**/*.swift"))
    #expect(app.xcode?.value.packages == ["App"])
  }

  @Test(
    "a package that declares iOS and not macOS builds and tests through xcodebuild on a named simulator — catches swift test failing to compile UIKit on the Mac"
  )
  func iOSOnlyPackageUsesXcodebuild() throws {
    let tree = try captured("WezSieTato-ScanNow")
    let manifest = try #require(tree.read("App/Package.swift")).utf8String
    #expect(manifest.contains(".iOS(.v14)") && !manifest.contains(".macOS("))

    let area = try #require(SwiftPMReader.area(manifest: "App/Package.swift", in: tree))
    let flags = " -skipMacroValidation -skipPackagePluginValidation"
    #expect(
      area.commands[.build]?.value
        == "xcodebuild build -scheme ScanNowCore -destination 'generic/platform=iOS Simulator'"
        + flags)
    let test = try #require(area.commands[.test]?.value)
    #expect(
      test
        == "xcodebuild test -scheme ScanNowCore -destination 'platform=iOS Simulator,name=iPhone 17'"
        + flags)
    #expect(area.commands[.testFiles] == nil, "swift test's filter ids don't fit -only-testing")
    #expect(
      XcodeTestDestination.simulator(in: test)?.device == "iPhone 17",
      "the gate runs it on a leased clone of the named simulator")

    let skipped = try #require(
      SwiftPMReader.area(
        manifest: "App/Package.swift", in: tree, runElsewhere: ["ScanNowCoreTests"]))
    #expect(skipped.commands[.test]?.value.contains(" -skip-testing:ScanNowCoreTests") == true)

    let prepared = try #require(
      AreaCommandExpansion.prepare(
        area: BrownfieldArea(proposed: area), step: .test, repositoryRoot: "/clone", files: [],
        tests: [], junitPath: "/clone/.git/swift-harness/junit/App.test.xml",
        deadline: .seconds(60), environment: [:]))
    #expect(
      prepared.request.resultBundlePath == "/clone/.git/swift-harness/junit/App.test.xcresult",
      "its failures read per test from the result bundle")
  }

  @Test(
    "a package test target the app's scheme runs is left out of the package area's swift test — catches the scheme's tests run twice"
  )
  func swiftTestSkipsSchemeRunTargets() throws {
    let tree = try captured("timed-build-starter")
    let area = try #require(
      SwiftPMReader.area(
        manifest: "Packages/AppFeature/Package.swift", in: tree, runElsewhere: ["AppCoreTests"]))
    #expect(area.commands[.test]?.value == "swift test --skip '^AppCoreTests\\.'")
    #expect(area.commands[.testFiles]?.value == "swift test --filter {tests}")
  }

  @Test(
    "a change in a local package gates the app area that builds it as well as its own, and a package test belongs to the package's area alone — catches an app broken by a package change with no gate building it"
  )
  func packageChangeGatesTheApp() throws {
    let areas = try starterAreas().map(BrownfieldArea.init(proposed:))
    let app = try #require(areas.first { $0.kind == .xcode })
    let feature = try #require(areas.first { $0.root == "Packages/AppFeature" })

    #expect(
      AreaGating.touched(by: ["Packages/AppFeature/Sources/AppCore/AppFeature.swift"], in: areas)
        .map(\.name).sorted() == [app.name, feature.name].sorted())
    #expect(
      AreaGating.touched(by: ["UITests/LaunchFlowUITests.swift"], in: areas).map(\.name)
        == [app.name])
    #expect(
      AreaGating.owner(of: "Packages/AppFeature/Sources/AppCore/AppFeature.swift", in: areas)?
        .name == feature.name)

    let test = "Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift"
    #expect(ChangedTestIDs.isTestFile(test, of: feature))
    #expect(!ChangedTestIDs.isTestFile(test, of: app))
  }

  @Test(
    "the packages an Xcode area builds survive the discover record — catches a cached proposal that forgets them and stops gating the app"
  )
  func recordKeepsPackages() throws {
    let proposal = Discover.propose(
      tree: try captured("timed-build-starter"), head: "abc", dirty: [])
    let cache = DiscoverRecord.Cache(key: "k", inputs: [], areas: proposal.areas)
    let encoded = try JSONEncoder().encode(cache)
    let decoded = try JSONDecoder().decode(DiscoverRecord.Cache.self, from: encoded)
    let restored = decoded.proposal(head: "abc", dirty: [])
    #expect(restored == proposal)
    #expect(restored.areas.compactMap(\.xcode).map(\.value.packages) == [Self.packages])
  }
}

extension Data {
  fileprivate var utf8String: String { String(decoding: self, as: UTF8.self) }
}
