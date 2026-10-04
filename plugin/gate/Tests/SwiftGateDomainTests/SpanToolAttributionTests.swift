import Foundation
import SwiftGateDomain
import Testing

@Suite("tool windows attributed to spans")
struct SpanToolAttributionTests {
  static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

  static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

  static func window(
    task: String?, start: Double,
    tools: [ToolCallCount] = [ToolCallCount(tool: .edit, count: 1, milliseconds: 10)],
    otherCount: Int = 0, files: [String] = [], dropped: Int = 0, agentID: String? = nil
  ) -> AgentToolsEvent {
    AgentToolsEvent(
      sessionID: "s", agent: agentID == nil ? .main : .subagent, agentID: agentID,
      role: .buildWorker, task: task, buildRun: nil, windowStart: at(start),
      windowEnd: at(start + 60), tools: tools, otherCount: otherCount, files: files,
      droppedPaths: dropped)
  }

  /// A run, task `a` inside it with a worker then a review span, and task `b` beside it.
  static let spans: [RunView.Span] = [
    RunView.Span(id: "run", phase: .run, start: at(0), end: at(1000)),
    RunView.Span(id: "a", parent: "run", phase: .task, task: "a", start: at(0), end: at(900)),
    RunView.Span(
      id: "a-worker", parent: "a", phase: .worker, task: "a", start: at(10), end: at(100)),
    RunView.Span(
      id: "a-review", parent: "a", phase: .review, task: "a", start: at(100), end: at(200)),
    RunView.Span(id: "b", parent: "run", phase: .task, task: "b", start: at(0), end: nil),
  ]

  @Test("a window straddling 2 spans goes to the span open at its start — catches its end used")
  func straddle() {
    let summaries = SpanToolAttribution.attribute(
      windows: [Self.window(task: "a", start: 70)], spans: Self.spans)
    #expect(
      summaries["a-worker"]?.calls == [ToolCallCount(tool: .edit, count: 1, milliseconds: 10)])
    #expect(summaries["a-review"] == nil)
    #expect(summaries["a"] == nil)
  }

  @Test("a window goes to its own task's innermost span — catches another task's span chosen")
  func ownTask() {
    let summaries = SpanToolAttribution.attribute(
      windows: [Self.window(task: "b", start: 50), Self.window(task: "a", start: 300)],
      spans: Self.spans)
    #expect(summaries["b"]?.calls.first?.count == 1)
    #expect(summaries["a"]?.calls.first?.count == 1)
    #expect(summaries["a-worker"] == nil)
    #expect(summaries["run"] == nil)
  }

  @Test("windows in 1 span sum counts, time and files — catches a later window replacing one")
  func sums() {
    let windows = [
      Self.window(
        task: "a", start: 10,
        tools: [
          ToolCallCount(tool: .read, count: 2, milliseconds: 5),
          ToolCallCount(tool: .bash, count: 1, milliseconds: 100),
        ],
        otherCount: 1, files: ["A.swift", "B.swift"], dropped: 1),
      Self.window(
        task: "a", start: 70, tools: [ToolCallCount(tool: .read, count: 1, milliseconds: 7)],
        files: ["B.swift", "C.swift"], dropped: 2, agentID: "sub"),
    ]
    let summary = SpanToolAttribution.attribute(windows: windows, spans: Self.spans)["a-worker"]
    #expect(
      summary
        == RunView.ToolSummary(
          calls: [
            ToolCallCount(tool: .read, count: 3, milliseconds: 12),
            ToolCallCount(tool: .bash, count: 1, milliseconds: 100),
          ],
          otherCount: 1, milliseconds: 112, files: ["A.swift", "B.swift", "C.swift"],
          droppedPaths: 3))
  }

  @Test("a span's files stop at 50 — catches an unbounded file list")
  func filesCapped() {
    let windows = (0..<3).map { part in
      Self.window(task: "a", start: 300 + Double(part), files: (0..<30).map { "F\(part)-\($0)" })
    }
    let files = SpanToolAttribution.attribute(windows: windows, spans: Self.spans)["a"]?.files
    #expect(files?.count == AgentToolsEvent.maxFiles)
    #expect(files?.first == "F0-0")
  }

  @Test("a window no span of its task holds is not attributed — catches a window forced onto 1")
  func noSpan() {
    let summaries = SpanToolAttribution.attribute(
      windows: [
        Self.window(task: "a", start: 950), Self.window(task: "c", start: 50),
        Self.window(task: "a", start: 300, files: ["Kept.swift"]),
      ],
      spans: Self.spans)
    #expect(Array(summaries.keys) == ["a"])
    #expect(summaries["a"]?.files == ["Kept.swift"])
    #expect(summaries["a"]?.calls.first?.count == 1)
  }

  @Test("a window with no task goes to the innermost task-less span — catches it dropped")
  func noTask() {
    let summaries = SpanToolAttribution.attribute(
      windows: [Self.window(task: nil, start: 50)], spans: Self.spans)
    #expect(Array(summaries.keys) == ["run"])
  }
}
