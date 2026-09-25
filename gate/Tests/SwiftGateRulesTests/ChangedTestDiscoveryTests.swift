import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("Changed test discovery")
struct ChangedTestDiscoveryTests {
  private static let source = """
    import Lib
    import Testing
    import XCTest

    @Test("free") func freeFunction() { #expect(double(1) == 2) }

    @Suite struct Outer {
      @Suite struct Inner {
        @Test("nested")
        func nested() {
          #expect(triple(1) == 3)
        }
      }

      @Test("param", arguments: [1, 2]) func param(value: Int) { #expect(double(value) == value * 2) }

      func helper() -> Int { 1 }
    }

    extension Outer.Inner {
      @Test func inExtension(_ first: Int = 1, label second: Int = 2) { #expect(first < second) }
    }

    final class XC: XCTestCase {
      func testDouble() { XCTAssertEqual(double(2), 4) }
    }
    """

  private func discover(_ ranges: [ClosedRange<Int>]) -> [ChangedTest] {
    let unit = SourceUnit(
      input: SourceInput(path: "Tests/LibTests/T.swift", text: Self.source), scope: nil)
    return ChangedTestDiscovery.tests(
      in: unit, target: "LibTests", added: AddedLines(path: unit.path, ranges: ranges))
  }

  @Test(
    "only tests whose declaration intersects an added line are selected, with ids as swift test lists them — catches unchanged tests stressed and changed ones missed"
  )
  func intersectsAddedLines() {
    let found = discover([11...11, 21...21])

    #expect(
      found.map(\.id) == [
        "LibTests.Outer/Inner/nested()", "LibTests.Outer/Inner/inExtension(_:label:)",
      ])
    #expect(found.map(\.line) == [9, 21])
    #expect(found.map(\.lastLine) == [12, 21])
    #expect(found.first?.displayName == "nested")
    #expect(found.first?.framework == .swiftTesting)
  }

  @Test(
    "free functions, parameterized tests and XCTest methods are discovered; helpers are not — catches a test kind prove never sees"
  )
  func everyKind() {
    let found = discover([1...30])

    #expect(
      found.map(\.id) == [
        "LibTests.freeFunction()", "LibTests.Outer/Inner/nested()", "LibTests.Outer/param(value:)",
        "LibTests.Outer/Inner/inExtension(_:label:)", "LibTests.XC/testDouble",
      ])
    #expect(found.last?.framework == .xcTest)
  }

  @Test(
    "a change outside every test selects nothing — catches helper edits proving unrelated tests")
  func noTestTouched() {
    #expect(discover([17...17, 1...3]).isEmpty)
  }
}
