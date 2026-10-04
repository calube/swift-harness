import ArgumentParser
import Testing

@testable import SwiftGateCLI

@Suite("sim hold")
struct SimHoldCommandTests {
  @Test(
    "sim hold refuses a run id that is not one file name before taking a slot — catches a lease path built from a run id with a separator"
  )
  func refusesPathRunID() async throws {
    for bad in ["../x", "a/b", ""] {
      do {
        _ = try await SwiftGate.asyncParseAsRoot(["sim", "hold", "--run", bad])
        Issue.record("sim hold --run \(bad.debugDescription) parsed")
      } catch {
        #expect(SwiftGate.message(for: error).contains("run id"), "\(error)")
      }
    }
  }
}
