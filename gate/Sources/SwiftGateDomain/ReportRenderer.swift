import Foundation

public enum OutputFormat: Sendable, Equatable {
  /// Capped summary for people and for Claude's context window.
  case human
  /// The full, versioned report (``RunReportJSON``).
  case json
}

/// Renders a ``RunReport``. Human output never exceeds ``maxHumanLines`` however many findings
/// there are, because hooks inject it into a model's context; the full report is on disk.
public enum ReportRenderer {
  public static let maxHumanLines = 30

  public static func render(_ report: RunReport, format: OutputFormat) throws -> String {
    switch format {
    case .human: human(report)
    case .json: String(decoding: try RunReportJSON.encode(report), as: UTF8.self)
    }
  }

  /// Longest rendered finding message; the rest is in the full report.
  static let maxMessageCharacters = 160

  public static func human(_ report: RunReport) -> String {
    var header = [
      "swiftgate \(report.verdict.rawValue) · run \(report.runID) · "
        + duration(report.durationMilliseconds)
    ]
    for tier in report.tiers {
      var line =
        "  \(tier.tier.rawValue) \(tier.verdict.rawValue) \(duration(tier.durationMilliseconds))"
      if let counts = tier.testCounts {
        line += " · \(counts.passed) passed, \(counts.failed) failed, \(counts.skipped) skipped"
      }
      header.append(line)
    }
    let footer = "details: \(RunLayout.runDirectory(for: report.runID))"

    guard !report.findings.isEmpty else { return (header + [footer]).joined(separator: "\n") }

    let ordered = report.findings.enumerated()
      .sorted { ($0.element.severity.rank, $0.offset) < ($1.element.severity.rank, $1.offset) }
      .map(\.element)
    let gatingCount = ordered.count { $0.severity.failsGate }
    header.append("findings: \(ordered.count) (\(gatingCount) gating)")

    var room = maxHumanLines - header.count - 1
    if ordered.count > room { room -= 1 }
    let shown = ordered.prefix(max(room, 0))
    var lines = header + shown.map(findingLine)
    let hidden = ordered.dropFirst(shown.count)
    if !hidden.isEmpty {
      let hiddenGating = hidden.count { $0.severity.failsGate }
      lines.append("  … \(hidden.count) more findings (\(hiddenGating) gating) in details")
    }
    lines.append(footer)
    return lines.joined(separator: "\n")
  }

  private static func findingLine(_ finding: Finding) -> String {
    let severity = finding.severity.rawValue
    let padding = String(repeating: " ", count: max(0, severityWidth - severity.count))
    let location = finding.line.map { "\(finding.file):\($0)" } ?? finding.file
    return "  \(severity)\(padding)  \(location)  \(finding.ruleID): \(oneLine(finding.message))"
  }

  private static let severityWidth = Severity.allCases.map(\.rawValue.count).max() ?? 0

  private static func oneLine(_ text: String) -> String {
    let collapsed = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard collapsed.count > maxMessageCharacters else { return collapsed }
    return collapsed.prefix(maxMessageCharacters - 1) + "…"
  }

  /// Locale-independent so output is byte-stable across machines.
  static func duration(_ milliseconds: Int) -> String {
    guard milliseconds >= 1000 else { return "\(milliseconds)ms" }
    return "\(milliseconds / 1000).\(milliseconds % 1000 / 100)s"
  }
}

extension Severity {
  /// Display order: most severe first.
  fileprivate var rank: Int {
    switch self {
    case .blocker: 0
    case .major: 1
    case .minor: 2
    case .nit: 3
    }
  }
}
