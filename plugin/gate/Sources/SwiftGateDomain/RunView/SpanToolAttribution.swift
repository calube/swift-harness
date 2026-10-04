import Foundation

/// Gives each `agent.tools` window to the innermost span of that agent's task open at the
/// window's start, and sums what each span got.
public enum SpanToolAttribution {
  /// Each span's summary, by span id; a span no window reached is absent.
  public static func attribute(windows: [AgentToolsEvent], spans: [RunView.Span]) -> [String:
    RunView.ToolSummary]
  {
    [:]
  }
}
