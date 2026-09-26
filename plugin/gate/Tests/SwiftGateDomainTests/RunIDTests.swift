import Foundation
import SwiftGateDomain
import Testing

@Suite("RunID")
struct RunIDTests {
  @Test("run ID is UTC-stamped and zero-padded — catches IDs that don't sort by start time")
  func format() {
    let date = Date(timeIntervalSince1970: 1_790_236_800)  // 2026-09-24T08:00:00Z
    #expect(RunID.make(startedAt: date, suffix: 0xab) == "20260924T080000Z-000000ab")
    #expect(RunID.isValid(RunID.make(startedAt: date, suffix: .max)))
  }
}
