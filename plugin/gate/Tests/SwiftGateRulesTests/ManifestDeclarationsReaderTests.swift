import Foundation
import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("manifest declarations reader")
struct ManifestDeclarationsReaderTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/sprint-manifests", directoryHint: .isDirectory)

  static func manifest(_ side: String, _ package: String) throws -> String {
    try String(
      contentsOf: fixturesRoot.appending(path: "\(side)/Packages/\(package)/Package.swift.txt"),
      encoding: .utf8)
  }

  static func declared(_ targets: Set<String>, _ products: Set<String>) -> ManifestReading {
    .declared(ManifestDeclarations(targets: targets, products: products))
  }

  @Test(
    "the rehearsal's slice declares its Live target and product beside the surface's, without its test targets — catches a new target the reader never sees"
  )
  func rehearsalManifestsReadTheirDeclarations() throws {
    #expect(
      ManifestDeclarationsReader.read(try Self.manifest("surface", "ProfileClient"))
        == Self.declared(["ProfileClient"], ["ProfileClient"]))
    #expect(
      ManifestDeclarationsReader.read(try Self.manifest("slice", "ProfileClient"))
        == Self.declared(
          ["ProfileClient", "ProfileClientLive"], ["ProfileClient", "ProfileClientLive"]))
    #expect(
      ManifestDeclarationsReader.read(try Self.manifest("slice", "ProfileFeature"))
        == Self.declared(["ProfileCore"], ["ProfileCore"]))
    #expect(
      ManifestDeclarationsReader.read(try Self.manifest("slice", "AppFeature"))
        == ManifestDeclarationsReader.read(try Self.manifest("surface", "AppFeature")))
  }

  @Test(
    "every non-test target factory counts as a target and every product factory as a product — catches an executable, macro or plugin target slipping past"
  )
  func everyFactoryCounts() {
    let text = """
      // swift-tools-version: 6.2
      import PackageDescription

      let package = Package(
        name: "Tools",
        products: [
          .library(name: "Lib", targets: ["Lib"]),
          .executable(name: "tool", targets: ["Tool"]),
          .plugin(name: "Gen", targets: ["Gen"]),
        ],
        targets: [
          .target(name: "Lib"),
          .executableTarget(name: "Tool"),
          .macro(name: "Macros"),
          .plugin(name: "Gen", capability: .buildTool()),
          .binaryTarget(name: "Blob", path: "Blob.xcframework"),
          .systemLibrary(name: "CZlib"),
          .testTarget(name: "LibTests", dependencies: ["Lib"]),
        ]
      )
      """
    #expect(
      ManifestDeclarationsReader.read(text)
        == Self.declared(
          ["Lib", "Tool", "Macros", "Gen", "Blob", "CZlib"], ["Lib", "tool", "Gen"]))
  }

  @Test(
    "a manifest whose declarations can't be read names why — catches a syntax error, a computed list or a list changed after Package read as declaring nothing"
  )
  func unreadableManifestsNameWhy() {
    let header = "// swift-tools-version: 6.2\nimport PackageDescription\n\n"
    let cases: [(String, String)] = [
      ("syntax error", "let package = Package(name: \"A\", targets: [.target(name: \"A\")]"),
      ("no Package call", "let name = \"A\"\n"),
      (
        "computed list",
        "let all = [Target.target(name: \"A\")]\nlet package = Package(name: \"A\", targets: all)\n"
      ),
      (
        "interpolated name",
        "let n = \"A\"\nlet package = Package(name: \"A\", targets: [.target(name: \"\\(n)\")])\n"
      ),
      (
        "appended later",
        "let package = Package(name: \"A\", targets: [.target(name: \"A\")])\npackage.targets.append(.target(name: \"B\"))\n"
      ),
    ]
    for (label, body) in cases {
      let reading = ManifestDeclarationsReader.read(header + body)
      guard case .unreadable(let reason) = reading else {
        Issue.record("\(label): read as \(reading)")
        continue
      }
      #expect(!reason.isEmpty, "\(label)")
    }
  }
}
