import Foundation
import SwiftGateDomain
import Testing

@Suite("sim build stamp")
struct SimBuildStampTests {
  static let stamp = SimBuildStamp(
    head: "0123456789abcdef0123456789abcdef01234567", scheme: "App",
    container: SimBuildStamp.containerKey(.project(path: "/repo/App.xcodeproj")),
    changes: ["App/View.swift": "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", "Old.swift": "deleted"])

  @Test(
    "a stamp decodes back to itself — catches a stamp sim up writes but can never match, so every sim up builds again"
  )
  func roundTrip() throws {
    #expect(SimBuildStamp.decode(Self.stamp.encoded()) == Self.stamp)
  }

  @Test(
    "another schema version, a missing key or garbage decodes to nil — catches an old or torn stamp read as a match"
  )
  func refusesOtherShapes() throws {
    let object = try #require(
      try JSONSerialization.jsonObject(with: Self.stamp.encoded()) as? [String: Any])
    var newer = object
    newer["schemaVersion"] = SimBuildStamp.currentSchemaVersion + 1
    var headless = object
    headless.removeValue(forKey: "head")
    for bad in [newer, headless] {
      #expect(SimBuildStamp.decode(try JSONSerialization.data(withJSONObject: bad)) == nil)
    }
    #expect(SimBuildStamp.decode(Data("{\"head\":".utf8)) == nil)
  }

  @Test(
    "build inputs drop the harness's own .harness/ files at any depth and keep everything else — catches a validation worker's flow files forcing a rebuild, or a real source change skipped"
  )
  func buildInputs() {
    #expect(
      SimBuildStamp.buildInputs([
        ".harness/qa/plan/a.flow.json", "App/View.swift", "examples/App/.harness/qa/plan/b.sh",
        "harness/Notes.swift", "App/.harnessrc",
      ]) == ["App/View.swift", "harness/Notes.swift", "App/.harnessrc"])
  }

  @Test(
    "each container kind and path gives its own key — catches a project and a workspace of one name sharing a stamp"
  )
  func containerKeys() {
    let keys = [
      SimBuildStamp.containerKey(.project(path: "/repo/App.xcodeproj")),
      SimBuildStamp.containerKey(.workspace(path: "/repo/App.xcodeproj")),
      SimBuildStamp.containerKey(.package(directory: "/repo/App.xcodeproj")),
      SimBuildStamp.containerKey(.project(path: "/repo/Other.xcodeproj")),
    ]
    #expect(Set(keys).count == keys.count)
    #expect(keys.allSatisfy { !$0.isEmpty })
  }
}
