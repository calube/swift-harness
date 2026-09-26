import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("OutputOptions")
struct OutputOptionsTests {
  @Test("--json selects the full JSON report, default is human — catches hooks parsing capped text")
  func jsonFlag() throws {
    #expect(try OutputOptions.parse(["--json"]).format == .json)
    #expect(try OutputOptions.parse([]).format == .human)
  }
}
