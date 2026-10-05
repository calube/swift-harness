import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

@Suite("workflow records")
struct WorkflowRecordsTests {
  static let session = "cb039a0d-04f4-428a-b575-e73a1e11d628"

  @Test(
    "a captured session's completed and killed Workflow records read as ended, each with its task, and a session with no workflows directory reads as none — catches a gate wait that never sees a worker return"
  )
  func capturedRecordsReadAsEnded() throws {
    let transcript = Fixture.gateDirectory.appending(
      path: "Tests/Fixtures/Transcripts/\(Self.session).jsonl")
    let directory = WorkflowRecords.directory(transcriptPath: transcript.path)
    #expect(directory.lastPathComponent == "workflows")
    #expect(directory.deletingLastPathComponent().lastPathComponent == Self.session)
    #expect(
      WorkflowRecords.ended(in: directory) == [
        "wf_b303df48-6fa": "detail-screen", "wf_c9484d68-757": "watchlist-screen",
        "wf_f9943c40-68e": "coingecko-client",
      ])
    #expect(
      WorkflowRecords.ended(in: directory.appending(path: "none", directoryHint: .isDirectory))
        .isEmpty)
  }
}
