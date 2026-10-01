import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("transcript reader")
struct TranscriptReaderTests {
  static let subagentSession = "a9349a9c-0ea7-41a9-bd3a-8792745db8b1"

  /// A copy of the captured transcripts in Claude Code's layout.
  static func copy() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
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
