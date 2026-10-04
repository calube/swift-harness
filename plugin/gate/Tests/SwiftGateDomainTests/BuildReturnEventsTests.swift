import Foundation
import SwiftGateDomain
import Testing

@Suite("build.return-checked")
struct BuildReturnEventsTests {
  private static let root = "/Users/someone/Developer/trials/memos-4-spec"

  private static func event(_ findings: [TaskReturnFinding], message: String = "task `t`: RED")
    -> BuildReturnCheckedEvent
  {
    .scrubbed(
      buildRun: "20261004T141445Z-85d15f09", task: "share-view-limit-web", fix: false,
      verdict: .red, findings: findings, message: message, roots: [root])
  }

  @Test(
    "past 10 findings the rest are counted, and each rule is named once in report order — catches an event that grows with the findings or loses a rule past the cap"
  )
  func capsFindingsAndNamesEachRule() {
    let findings = (0..<12).map { index in
      TaskReturnFinding(
        rule: index.isMultiple(of: 2) ? .commitMissing : .surfaceCommitOffBranch,
        message: "commit \(index) isn't on branch spec/share-view-limit-web")
    }
    let event = Self.event(findings + [TaskReturnFinding(rule: .reviewMissing, message: "no")])

    #expect(event.rules == [.commitMissing, .surfaceCommitOffBranch, .reviewMissing])
    #expect(event.findings.count == RunView.maxFailureFindings)
    #expect(event.moreFindings == 3)
    #expect(event.findings.map(\.rule) == findings.prefix(10).map(\.rule))
  }

  @Test(
    "a message goes on 1 line, a path under a checkout turns repo-relative, any other machine path becomes <path>, and a long one is cut and marked — catches an event the payload guard drops or one carrying a local path"
  )
  func scrubsAndCutsMessages() throws {
    let event = Self.event(
      [
        TaskReturnFinding(
          rule: .gateRunMissing,
          message: "gate run r1 isn't in \(Self.root)/.harness/runs/history.jsonl\n"
            + "nor in /private/var/folders/x/history.jsonl"),
        TaskReturnFinding(
          rule: .outsideWriteSet, message: String(repeating: "web/src/a.ts ", count: 60)),
      ],
      message: "can't read \(Self.root)/.harness/task-status.json")

    let first = try #require(event.findings.first)
    #expect(first.message == "gate run r1 isn't in .harness/runs/history.jsonl nor in <path>")
    #expect(first.truncated == false)
    let long = try #require(event.findings.last)
    #expect(long.truncated)
    #expect(long.message.utf8.count <= RunView.maxFailureMessageBytes)
    #expect(event.message == "can't read .harness/task-status.json")
    let wrapped = HarnessEvent(
      eventID: "E1", time: Date(timeIntervalSince1970: 1_791_000_000),
      source: HarnessEventSource(route: nil), payload: .buildReturnChecked(event))
    #expect(try EventPayloadGuard.rejection(of: wrapped) == nil)
    let decoded = try HarnessEventJSON.decode(try HarnessEventJSON.encodeLine(wrapped)).events
    #expect(decoded == [wrapped])
    #expect(wrapped.kind.stream == .build)
  }
}
