import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("transcript reader")
struct TranscriptReaderTests {
  static let subagentSession = "a9349a9c-0ea7-41a9-bd3a-8792745db8b1"
  /// A brownfield run's orchestrator, with 1 Agent-tool subagent and 2 Workflows' agents.
  static let runSession = "b9ba71e8-b19d-4ef9-8629-bbce3c641242"

  /// A copy of the captured transcripts in Claude Code's layout.
  static func copy() throws -> URL {
    let directory = TestTemporaryDirectory.root
      .appending(
        path: "swiftgate-transcript-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: Fixture.directory.appending(path: "Transcripts", directoryHint: .isDirectory),
      to: directory)
    return directory
  }

  @Test(
    "a session's transcript comes with each agent-*.jsonl in the subagents directory beside it, as subagents with their ids — catches a session's own subagents left out of its usage"
  )
  func sessionIncludesItsSubagents() throws {
    let directory = try Self.copy()
    defer { try? FileManager.default.removeItem(at: directory) }
    let subagents = directory.appending(path: "\(Self.subagentSession)/subagents")
    try Data("{}\n".utf8).write(to: subagents.appending(path: "agent-a705c5b0d3c2b4f5b.meta.json"))
    try Data("{}\n".utf8).write(to: subagents.appending(path: "agent-bad id.jsonl"))

    let files = try TranscriptReader().session(
      at: directory.appending(path: "\(Self.subagentSession).jsonl"))
    try #require(files.count == 3)
    #expect(files.map(\.agent) == [.main, .subagent, .subagent])
    #expect(files.map(\.agentID) == [nil, "a705c5b0d3c2b4f5b", nil])
    #expect(
      files.map(\.label) == [
        "the session transcript", "agent-a705c5b0d3c2b4f5b.jsonl", "agent-bad id.jsonl",
      ])
    #expect(
      files[1].data
        == (try Data(
          contentsOf: subagents.appending(path: "agent-a705c5b0d3c2b4f5b.jsonl"))))

    let plain = try TranscriptReader().session(
      at: directory.appending(path: "5812f394-1a00-4182-a6ec-fa7944ec92fb.jsonl"))
    #expect(plain.map(\.agent) == [.main])
  }

  @Test(
    "a session's transcript comes with its Agent-tool subagent and every Workflow's agents under subagents/workflows, each Workflow agent marked so — catches a run's workers, reviewers and verifiers left out of the session's usage"
  )
  func sessionIncludesItsWorkflowAgents() throws {
    let directory = try Self.copy()
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = try TranscriptReader().session(
      at: directory.appending(path: "\(Self.runSession).jsonl"))
    #expect(files.map(\.agent) == [.main] + Array(repeating: .subagent, count: 10))
    #expect(
      files.filter { !$0.workflow }.map(\.agentID) == [nil, "a9f3bfd905ad90faa"])
    #expect(
      Set(files.filter(\.workflow).compactMap(\.agentID)) == [
        "a09e55ce434f4267b", "a7a05ca41f8e78a93", "a43763b88c0d65738", "a5c3fcc7cd83081d6",
        "a78ff7e20d283513a", "a7bd71f238bd3abfc", "adfffa0a1fdad2145", "ae1ef7f1d411186f7",
        "af220b3b8bf4753bb",
      ])
    #expect(files.filter(\.workflow).count == 9)
    #expect(files.allSatisfy { !$0.label.contains("/") }, "\(files.map(\.label))")
  }

  @Test(
    "each subagent carries the agent type its .meta.json names, and a Workflow agent the task of its Workflow once the Workflow's record says it ended, whether completed or killed — catches a fixer or a killed worker the session's ingest can't tag"
  )
  func subagentsCarryTheirTypeAndEndedWorkflowTask() throws {
    let directory = try Self.copy()
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = "cb039a0d-04f4-428a-b575-e73a1e11d628"
    let workflow = directory.appending(path: "\(session)/workflows/wf_b303df48-6fa.json")

    let files = try TranscriptReader().session(at: directory.appending(path: "\(session).jsonl"))
    func file(_ id: String) throws -> TranscriptFile {
      try #require(files.first { $0.agentID == id })
    }

    #expect(try file("ac257d99cb5b5a4ef").agentType == "swift-harness:build-fixer")
    #expect(try file("ac257d99cb5b5a4ef").endedWorkflowTask == nil)
    #expect(try file("a5db10195f7f6c10e").agentType == "general-purpose")
    #expect(try file("a441498174c3ea0c9").agentType == "swift-harness:build-worker")
    #expect(try file("a441498174c3ea0c9").endedWorkflowTask == "detail-screen")
    #expect(try file("a9be2609f6cf3af37").endedWorkflowTask == "watchlist-screen")

    let running = try String(contentsOf: workflow, encoding: .utf8)
      .replacingOccurrences(of: "\"killed\"", with: "\"running\"")
    try Data(running.utf8).write(to: workflow)
    let live = try TranscriptReader().session(at: directory.appending(path: "\(session).jsonl"))
    #expect(live.first { $0.agentID == "a441498174c3ea0c9" }?.endedWorkflowTask == nil)
  }

  @Test(
    "a missing transcript or directory fails without naming its path — catches a path leaking into a message"
  )
  func missingFilesFailWithoutPaths() throws {
    let directory = try Self.copy()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      _ = try TranscriptReader().session(at: directory.appending(path: "missing.jsonl"))
      Issue.record("a missing transcript was read")
    } catch {
      #expect(error.description.contains("no such file"), "\(error)")
      #expect(!error.description.contains(directory.path))
    }
    do {
      _ = try TranscriptReader().workflow(in: directory.appending(path: "missing"))
      Issue.record("a missing directory was listed")
    } catch {
      #expect(!error.description.contains(directory.path), "\(error)")
    }
    let workflow = try TranscriptReader().workflow(
      in: directory.appending(path: "\(Self.subagentSession)/subagents"))
    #expect(workflow.map(\.agentID) == ["a705c5b0d3c2b4f5b"])
  }
}
