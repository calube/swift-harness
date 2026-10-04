import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("run view reader")
struct RunViewReaderStubTests {
  @Test(
    "a reader that reads no store yet returns a damage row naming the run — catches an empty view passing for a run with no events"
  )
  func unreadRunIsDamage() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "run-view-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
    let reader: any RunViewReading = RunViewReader(
      commonDirectory: directory, stateRoot: .tree(directory))
    let input = try reader.read(buildRun: "20261003T120000Z-1a2b3c4d")
    #expect(input.buildRun == "20261003T120000Z-1a2b3c4d")
    #expect(input.events.isEmpty)
    #expect(input.damage.map(\.source) == ["20261003T120000Z-1a2b3c4d"])
  }
}
