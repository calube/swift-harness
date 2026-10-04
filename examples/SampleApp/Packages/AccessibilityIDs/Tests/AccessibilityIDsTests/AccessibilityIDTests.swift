import AccessibilityIDs
import Testing

@Suite("AccessibilityID")
struct AccessibilityIDTests {
  /// Regression: a case left with its implicit raw value (the case name) or a value a flow
  /// selector can't quote, so QA flow lint, which reads the raw values from source, misses it.
  @Test("every raw value is a dotted <screen>.<element> identifier")
  func everyRawValueIsDottedScreenAndElement() {
    for id in AccessibilityID.allCases {
      let parts = id.rawValue.split(separator: ".", omittingEmptySubsequences: false)
      let wellFormed =
        parts.count == 2
        && parts.allSatisfy { part in
          guard let first = part.first, first.isLetter, first.isASCII else { return false }
          return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
      #expect(wellFormed, "\(id) has raw value \"\(id.rawValue)\"")
    }
  }
}
