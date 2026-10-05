import Foundation

/// 1 `flow row:` line of a fixer's notes: a flow row 1 or 2 `qa run`s left red, and whether the
/// fixer showed the app correct there.
public struct FlowRowVerdict: Sendable, Equatable, Codable {
  public let requirement: String
  /// The `qa run`s the line names the row red in.
  public let runs: [String]
  /// `flow-side: yes`, or `flow-side: no` for a contract gap: the frames and the fixer's
  /// reproduction test showed the app correct, so the flow can't read the state reliably.
  public let appShownCorrect: Bool

  public init(requirement: String, runs: [String], appShownCorrect: Bool) {
    self.requirement = requirement
    self.runs = runs
    self.appShownCorrect = appShownCorrect
  }

  /// Every `flow row: <requirement> <check>: … (qa runs <id>, <id>); flow-side: yes|no: <why>`
  /// line of `notes`, in order; a line missing its runs or its `flow-side` is passed over.
  public static func parse(notes: String) -> [FlowRowVerdict] {
    notes.split(whereSeparator: \.isNewline).compactMap { raw in
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("flow row:"),
        let requirement = line.dropFirst("flow row:".count).split(separator: " ").first,
        let opened = line.range(of: "(qa runs "),
        let side = line.range(of: "flow-side: ", range: opened.upperBound..<line.endIndex)
      else { return nil }
      let runs = line[opened.upperBound...].prefix { $0 != ")" }.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      let answer = line[side.upperBound...]
      let shownCorrect: Bool
      if answer.hasPrefix("yes") {
        shownCorrect = true
      } else if answer.hasPrefix("no") {
        shownCorrect = answer.dropFirst(2).trimmingCharacters(in: .whitespaces)
          .hasPrefix(": contract gap")
      } else {
        return nil
      }
      guard !runs.isEmpty else { return nil }
      return FlowRowVerdict(
        requirement: String(requirement), runs: runs, appShownCorrect: shownCorrect)
    }
  }
}
