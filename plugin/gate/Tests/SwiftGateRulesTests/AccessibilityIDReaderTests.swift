import Foundation
import SwiftGateRules
import Testing

/// Reading the identifiers an app's typed accessibility-id enum declares.
@Suite("accessibility id reader")
struct AccessibilityIDReaderTests {
  static let sampleFile = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(
      path: "examples/SampleApp/Packages/AccessibilityIDs/Sources/AccessibilityIDs/AccessibilityID.swift"
    )

  @Test(
    "SampleApp's AccessibilityID enum yields its raw values, not its case names — catches a flow checked against Swift names"
  )
  func readsSampleApp() throws {
    let source = try String(contentsOf: Self.sampleFile, encoding: .utf8)

    let ids = try AccessibilityIDReader.read(source: source, path: "AccessibilityID.swift")

    #expect(ids.contains("counter.value"))
    #expect(ids.contains("counter.increment"))
    #expect(!ids.contains("counterValue"))
  }

  @Test(
    "a case with no raw value counts as its name, and cases inside #if count in every branch — catches an id the app sets reported unknown"
  )
  func implicitAndConditional() throws {
    let source = """
      enum AccessibilityID: String {
        case save
        case list = "drafts.list", edit = "drafts.edit"
        #if DEBUG
        case debugMenu = "debug.menu"
        #endif
      }
      enum Other: String { case unrelated = "x.y" }
      """

    let ids = try AccessibilityIDReader.read(source: source, path: "IDs.swift")

    #expect(ids == ["save", "drafts.list", "drafts.edit", "debug.menu"])
  }

  @Test(
    "no AccessibilityID enum, 2 of them, an interpolated raw value or a syntax error each fail naming the file — catches an unreadable module read as no ids"
  )
  func refusals() {
    let cases = [
      "enum Other: String { case a }",
      "enum AccessibilityID: String { case a }\nenum AccessibilityID: String { case b }",
      "enum AccessibilityID: String { case a = \"x.\\(1)\" }",
      "enum AccessibilityID: String { case a = ",
      "enum AccessibilityID: Int { case a = 1 }",
    ]
    for source in cases {
      let error = #expect(throws: AccessibilityIDReaderError.self, "\(source)") {
        _ = try AccessibilityIDReader.read(source: source, path: "IDs.swift")
      }
      #expect(error?.path == "IDs.swift")
    }
  }
}
