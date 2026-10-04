import Foundation

/// Gives each `agent.tools` window to the innermost span of that agent's task open at the
/// window's start, and sums what each span got.
public enum SpanToolAttribution {
  /// Each span's summary, by span id; a span no window reached is absent.
  public static func attribute(windows: [AgentToolsEvent], spans: [RunView.Span]) -> [String:
    RunView.ToolSummary]
  {
    let byID = Dictionary(spans.map { ($0.id, $0) }) { first, _ in first }
    func depth(_ span: RunView.Span) -> Int {
      var depth = 0
      var visited: Set<String> = [span.id]
      var parent = span.parent
      while let id = parent, visited.insert(id).inserted, let next = byID[id] {
        depth += 1
        parent = next.parent
      }
      return depth
    }
    var summaries: [String: RunView.ToolSummary] = [:]
    for window in windows {
      let time = window.windowStart
      let open = spans.filter { span in
        span.task == window.task && span.start <= time && span.end.map { time < $0 } ?? true
      }
      guard
        let span = open.max(by: {
          (depth($0), $0.start, $1.id) < (depth($1), $1.start, $0.id)
        })
      else { continue }
      summaries[span.id, default: RunView.ToolSummary()].add(window)
    }
    return summaries
  }
}

extension RunView.ToolSummary {
  fileprivate mutating func add(_ window: AgentToolsEvent) {
    var counts = Dictionary(uniqueKeysWithValues: calls.map { ($0.tool, $0) })
    for call in window.tools {
      let earlier = counts[call.tool]
      counts[call.tool] = ToolCallCount(
        tool: call.tool, count: (earlier?.count ?? 0) + call.count,
        milliseconds: (earlier?.milliseconds ?? 0) + call.milliseconds)
      milliseconds += call.milliseconds
    }
    calls = ToolKind.allCases.compactMap { counts[$0] }
    otherCount += window.otherCount
    droppedPaths += window.droppedPaths
    for file in window.files where files.count < AgentToolsEvent.maxFiles && !files.contains(file) {
      files.append(file)
    }
  }
}
