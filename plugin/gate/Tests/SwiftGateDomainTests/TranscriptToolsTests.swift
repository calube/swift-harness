import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("transcript tool calls and their windows")
struct TranscriptToolsTests {
  static let session = "39933227-0a3a-4a70-b63e-3cd768834ff9"
  static let subagentID = "a4ad125449ad0c978"
  static let buildRun = "20261001T040911Z-13708165"

  static func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Fixture.directory.appending(path: "Transcripts/\(name)"))
  }

  static var mainData: Data { get throws { try fixture("\(session).jsonl") } }
  static var subagentData: Data {
    get throws { try fixture("\(session)/subagents/agent-\(subagentID).jsonl") }
  }

  /// The captured session and its subagent, tagged as a build worker's would be.
  static func transcripts() throws -> [ToolTranscript] {
    [
      ToolTranscript(
        agent: .main, agentID: nil, role: .buildWorker, task: "greeting",
        calls: try TranscriptTools.calls(in: mainData)),
      ToolTranscript(
        agent: .subagent, agentID: subagentID, role: .buildWorker, task: "greeting",
        calls: try TranscriptTools.calls(in: subagentData)),
    ]
  }

  static func plan(stored: Set<String> = []) throws -> ToolIngestPlan {
    ToolIngest.plan(
      sessionID: session, transcripts: try transcripts(), buildRun: buildRun,
      topLevels: ["/REPO": "/REPO"], stored: stored)
  }

  static func tools(_ plan: ToolIngestPlan) -> [AgentToolsEvent] {
    plan.events.compactMap { if case .agentTools(let tools) = $0.payload { tools } else { nil } }
  }

  /// Every string value at any depth of a `JSONSerialization` object.
  static func strings(in value: Any) -> [String] {
    if let text = value as? String { return [text] }
    if let object = value as? [String: Any] { return object.values.flatMap { strings(in: $0) } }
    if let array = value as? [Any] { return array.flatMap { strings(in: $0) } }
    return []
  }

  /// Every string of every `tool_use` input in a transcript.
  static func inputStrings(_ data: Data) throws -> Set<String> {
    var found: Set<String> = []
    for line in data.split(separator: UInt8(ascii: "\n")) {
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
      for block in content where block["type"] as? String == "tool_use" {
        found.formUnion(strings(in: block["input"] as Any))
      }
    }
    return found
  }

  @Test("tool calls count by kind over the captured session — catches a call dropped or miscounted")
  func countsByKind() throws {
    let windows = Self.tools(try Self.plan())
    var counts: [ToolKind: Int] = [:]
    for window in windows {
      for call in window.tools { counts[call.tool, default: 0] += call.count }
    }
    #expect(
      counts == [.read: 3, .edit: 1, .write: 1, .toolSearch: 1, .bash: 1, .agent: 1])
    #expect(windows.allSatisfy { $0.otherCount == 0 })
    let main = try #require(windows.first { $0.agentID == nil })
    let bash = try #require(main.tools.first { $0.tool == .bash })
    // `ls` ran from 04:51:01.802 to its result at 04:51:04.263.
    #expect(bash.milliseconds == 2461)
  }

  @Test("no tool input but a kept path reaches an event — catches a command or content stored")
  func noToolInputStored() throws {
    let plan = try Self.plan()
    let inputs = try Self.inputStrings(Self.mainData).union(Self.inputStrings(Self.subagentData))
    #expect(inputs.contains("ls"))
    var stored: Set<String> = []
    for event in plan.events {
      let line = try HarnessEventJSON.encodeLine(event)
      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
      stored.formUnion(Self.strings(in: object?["payload"] as Any))
    }
    #expect(!stored.isEmpty)
    #expect(stored.isDisjoint(with: inputs), "\(stored.intersection(inputs))")
  }

  @Test("a path outside the repo is dropped and counted — catches an absolute path kept")
  func pathsAreRepoRelative() throws {
    let windows = Self.tools(try Self.plan())
    let main = try #require(windows.first { $0.agentID == nil })
    #expect(main.files == ["Sources/Greeting.swift", "Sources/Farewell.swift"])
    // `/etc/hosts`.
    #expect(main.droppedPaths == 1)
    for window in windows {
      #expect(window.files.allSatisfy { !$0.hasPrefix("/") && !$0.contains("etc/hosts") })
    }
  }

  @Test("a path with no known top level is dropped — catches a path kept unresolved")
  func unknownTopLevelDrops() throws {
    let plan = ToolIngest.plan(
      sessionID: Self.session, transcripts: try Self.transcripts(), buildRun: nil, topLevels: [:],
      stored: [])
    let windows = Self.tools(plan)
    #expect(windows.allSatisfy { $0.files.isEmpty })
    #expect(windows.map(\.droppedPaths).reduce(0, +) == 5)
  }

  @Test("home, escaping and relative paths resolve against the line's cwd — catches an escape kept")
  func escapesAreDropped() throws {
    let time = Date(timeIntervalSince1970: 1_790_000_000)
    func call(_ id: String, _ path: String, cwd: String = "/R/Sub") -> TranscriptToolCall {
      TranscriptToolCall(id: id, kind: .grep, time: time, milliseconds: 1, path: path, cwd: cwd)
    }
    let calls = [
      call("a", "~/notes.md"), call("b", "../../outside.swift"), call("c", "/R/a/../../x"),
      call("d", "Lib"), call("e", "../Top.swift"), call("f", "/R/./A.swift"),
      call("g", "/Rx/B.swift"), call("h", "A\nB"),
    ]
    let plan = ToolIngest.plan(
      sessionID: Self.session,
      transcripts: [
        ToolTranscript(agent: .main, agentID: nil, role: nil, task: nil, calls: calls)
      ],
      buildRun: nil, topLevels: ["/R/Sub": "/R"], stored: [])
    let window = try #require(Self.tools(plan).first)
    #expect(window.files == ["Sub/Lib", "Top.swift", "A.swift"])
    #expect(window.droppedPaths == 5)
  }

  @Test("the subagent's window carries its agent id — catches a window tagged as the main agent")
  func subagentWindow() throws {
    let windows = Self.tools(try Self.plan())
    let sub = try #require(windows.first { $0.agent == .subagent })
    #expect(sub.agentID == Self.subagentID)
    #expect(sub.files == ["NOTES.md"])
    #expect(sub.tools == [ToolCallCount(tool: .read, count: 1, milliseconds: 13)])
    #expect(windows.allSatisfy { $0.role == .buildWorker && $0.task == "greeting" })
    #expect(windows.allSatisfy { $0.buildRun == Self.buildRun && $0.sessionID == Self.session })
    #expect(windows.filter { $0.agentID == nil }.count == 1)
  }

  @Test("calls more than 60 s apart split into windows — catches 1 window per agent")
  func windowsSplit() throws {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let calls = [0.0, 59.9, 60.0, 200.0].enumerated().map { index, offset in
      TranscriptToolCall(
        id: "t\(index)", kind: .bash, time: start.addingTimeInterval(offset), milliseconds: 5,
        path: nil, cwd: nil)
    }
    let plan = ToolIngest.plan(
      sessionID: Self.session,
      transcripts: [
        ToolTranscript(agent: .main, agentID: nil, role: nil, task: nil, calls: calls)
      ],
      buildRun: nil, topLevels: [:], stored: [])
    let windows = Self.tools(plan)
    #expect(windows.map { $0.tools.first?.count } == [2, 1, 1])
    #expect(windows.map(\.windowStart) == [0, 60, 200].map { start.addingTimeInterval($0) })
    #expect(windows.allSatisfy { $0.windowEnd.timeIntervalSince($0.windowStart) <= 60 })
  }

  @Test("an unknown tool name counts in otherCount and mcp names fold — catches a name kept")
  func kinds() {
    #expect(TranscriptTools.kind(of: "Bash") == .bash)
    #expect(TranscriptTools.kind(of: "mcp__claude-in-chrome__navigate") == .mcp)
    #expect(TranscriptTools.kind(of: "mcp") == nil)
    #expect(TranscriptTools.kind(of: "Task") == nil)
  }

  @Test("a tool use with no result counts with no time — catches a missing result breaking ms")
  func missingResult() throws {
    let lines = [
      #"{"type":"assistant","timestamp":"2026-10-04T04:50:54.449Z","cwd":"/R","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"x"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/R/A.swift"}}]}}"#,
      #"{"type":"user","timestamp":"2026-10-04T04:50:55.449Z","cwd":"/R","message":{"content":[{"type":"tool_result","tool_use_id":"t2"}]}}"#,
    ]
    let calls = try TranscriptTools.calls(in: Data(lines.joined(separator: "\n").utf8))
    #expect(calls.map(\.milliseconds) == [nil, 1000])
    #expect(calls.map(\.path) == [nil, "/R/A.swift"])
  }

  @Test("a tool use with no id fails, naming its line — catches a malformed block skipped")
  func malformedToolUse() {
    let line =
      #"{"type":"assistant","timestamp":"2026-10-04T04:50:54.449Z","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#
    do {
      _ = try TranscriptTools.calls(in: Data(("\n" + line + "\n").utf8))
      Issue.record("a tool_use with no id was read")
    } catch {
      #expect(error.line == 2)
    }
  }

  @Test("ingesting twice writes no duplicate — catches a missing window and agent dedup key")
  func dedup() throws {
    let first = try Self.plan()
    #expect(first.events.count == 2)
    #expect(Set(first.events.map(\.eventID)).count == 2)
    let again = try Self.plan(stored: Set(first.events.map(\.eventID)))
    #expect(again.events.isEmpty)
    #expect(again.alreadyStored == 2)
    #expect(again.callsRead == 8)
  }

  @Test("a call in both a worker file and the session's counts once — catches a doubled call")
  func callInTwoFiles() throws {
    let calls = try TranscriptTools.calls(in: Self.subagentData)
    let plan = ToolIngest.plan(
      sessionID: Self.session,
      transcripts: [
        ToolTranscript(agent: .subagent, agentID: "w", role: nil, task: nil, calls: calls),
        ToolTranscript(agent: .subagent, agentID: "w", role: nil, task: nil, calls: calls),
      ],
      buildRun: nil, topLevels: ["/REPO": "/REPO"], stored: [])
    #expect(
      Self.tools(plan).map(\.tools) == [[ToolCallCount(tool: .read, count: 1, milliseconds: 13)]])
  }
}
