import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("worker file paths across worktrees")
struct WorkerWorktreePathsTests {
  static let session = "2af0f601-e397-4872-a742-dca067ce9dce"
  /// The scratch root the capture replaced; every transcript `cwd` is its main checkout.
  static let main = "/SCRATCH/app"

  static func transcript(_ agentID: String, task: String) throws -> ToolTranscript {
    let data = try Data(
      contentsOf: Fixture.directory.appending(
        path: "Transcripts/worker-worktrees/agent-\(agentID).jsonl"))
    return ToolTranscript(
      agent: .subagent, agentID: agentID, role: .buildWorker, task: task,
      calls: try TranscriptTools.calls(in: data))
  }

  /// The main checkout and each task worktree the captured run's ledger names, as the adapter
  /// would list them while the workers ran.
  static func worktreeRoots() throws -> [String] {
    let data = try Data(
      contentsOf: Fixture.directory.appending(path: "RunView/build-run-2/ledger.json"))
    let ledger = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let tasks = try #require(ledger["tasks"] as? [[String: Any]])
    let parent = (main as NSString).deletingLastPathComponent
    return [main]
      + tasks.compactMap { $0["worktree"] as? String }.map {
        "\(parent)/\($0.replacingOccurrences(of: "../", with: ""))"
      }
  }

  static func strings(in value: Any) -> [String] {
    if let text = value as? String { return [text] }
    if let object = value as? [String: Any] { return object.values.flatMap { strings(in: $0) } }
    if let array = value as? [Any] { return array.flatMap { strings(in: $0) } }
    return []
  }

  @Test(
    "a worker's path in its own worktree is kept repo-relative — catches worker file paths dropped or stored absolute"
  )
  func workerPathsKept() throws {
    let transcripts = [
      try Self.transcript("a5144c1382233c055", task: "counter-ui-reset-button"),
      try Self.transcript("a1df530e0a9c131c0", task: "counter-core-reset-and-decrement-floor"),
    ]
    let plan = ToolIngest.plan(
      sessionID: Self.session, transcripts: transcripts, buildRun: nil,
      topLevels: [Self.main: Self.main], worktrees: [Self.main: try Self.worktreeRoots()],
      stored: [])
    let windows = plan.events.compactMap {
      if case .agentTools(let tools) = $0.payload { tools } else { nil }
    }
    let files = Dictionary(grouping: windows, by: \.agentID).mapValues { $0.flatMap(\.files) }
    #expect(
      files["a5144c1382233c055"] == ["Packages/CounterFeature/Sources/CounterUI/CounterView.swift"])
    #expect(
      files["a1df530e0a9c131c0"] == [
        ".harness/context-pack/worker-counter-core-reset-and-decrement-floor.md"
      ])
    #expect(windows.map(\.droppedPaths).reduce(0, +) == 0)
    for event in plan.events {
      let line = try HarnessEventJSON.encodeLine(event)
      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
      let leaked = Self.strings(in: object?["payload"] as Any).filter {
        $0.hasPrefix("/") || $0.contains("SCRATCH") || $0.contains("..")
      }
      #expect(leaked.isEmpty, "\(leaked)")
    }
  }

  @Test(
    "a worktree nested in another resolves against the innermost — catches a path kept relative to the outer checkout"
  )
  func innermostWorktreeWins() throws {
    let nested = "/R/.git/swift-harness/plans/p/worktrees/t"
    let time = Date(timeIntervalSince1970: 1_790_000_000)
    let calls = [
      TranscriptToolCall(
        id: "a", kind: .edit, time: time, milliseconds: 1, path: "\(nested)/Sources/A.swift",
        cwd: "/R"),
      TranscriptToolCall(
        id: "b", kind: .read, time: time, milliseconds: 1, path: "/R/Sources/B.swift", cwd: "/R"),
      TranscriptToolCall(
        id: "c", kind: .read, time: time, milliseconds: 1, path: "/Rx/C.swift", cwd: "/R"),
    ]
    let plan = ToolIngest.plan(
      sessionID: Self.session,
      transcripts: [
        ToolTranscript(agent: .main, agentID: nil, role: nil, task: nil, calls: calls)
      ],
      buildRun: nil, topLevels: ["/R": "/R"], worktrees: ["/R": ["/R", nested]], stored: [])
    let window = try #require(
      plan.events.compactMap {
        if case .agentTools(let tools) = $0.payload { tools } else { nil }
      }.first)
    #expect(window.files == ["Sources/A.swift", "Sources/B.swift"])
    #expect(window.droppedPaths == 1)
  }
}
