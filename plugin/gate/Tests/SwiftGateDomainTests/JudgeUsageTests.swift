import SwiftGateDomain
import Testing

@Suite("judge usage")
struct JudgeUsageTests {
  @Test("a duration converts to whole milliseconds — catches a unit slip in wall time")
  func millisecondsConversion() {
    #expect(JudgeUsage.milliseconds(.milliseconds(1234)) == 1234)
    #expect(JudgeUsage.milliseconds(.seconds(2) + .microseconds(999)) == 2000)
  }
}
