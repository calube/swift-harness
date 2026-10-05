import Foundation

/// `plan import`'s check that a task whose own check exercises another task's work waits for
/// that task. Pure: the tasks and the validation table arrive already read.
public enum PlanLintCheckDependencies {
  public static let ruleID = "plan-lint.check-missing-dependency"

  /// A task as the check reads it.
  public struct Task: Sendable, Equatable {
    public let id: String
    public let deps: [String]
    /// Repository-relative paths; a path ending in `/` is a prefix.
    public let writes: [String]
    /// The task's `- Acceptance:` items, as written.
    public let acceptance: [String]

    public init(id: String, deps: [String], writes: [String], acceptance: [String]) {
      self.id = id
      self.deps = deps
      self.writes = writes
      self.acceptance = acceptance
    }
  }

  /// Every finding, each `major`: the validation rows in table order, then each task's
  /// acceptance items in plan order.
  ///
  /// - Parameters:
  ///   - tasks: every task of the plan.
  ///   - table: the plan's validation table; `nil` when it has none.
  ///   - file: the file findings name.
  ///   - rowLines: the line of each of `table.rows`, when the table came from markdown.
  public static func findings(
    tasks: [Task], table: ValidationTable?, file: String, rowLines: [Int] = []
  ) throws(ReportContractViolation) -> [Finding] {
    let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var findings: [Finding] = []
    for (index, row) in (table?.rows ?? []).enumerated() where row.runsAfter.contains(row.writer) {
      for other in row.runsAfter where other != row.writer && byID[other] != nil {
        guard !reaches(row.writer, other, byID) else { continue }
        findings.append(
          try Finding(
            ruleID: ruleID, severity: .major, file: file,
            line: index < rowLines.count ? rowLines[index] : nil,
            message:
              "\(row.requirement)'s \(row.layer.rawValue) row runs after `\(other)`, but its "
              + "writer `\(row.writer)` doesn't depend on `\(other)`; make `\(row.writer)` "
              + "depend on it, or have the contract land what the check needs",
            failureScenario:
              "`\(row.writer)`'s own gates run `\(row.check)` before `\(other)` merges, so it "
              + "reads red on a stub and starts a fixer"))
      }
    }
    for task in tasks {
      for other in tasks where other.id != task.id && !reaches(task.id, other.id, byID) {
        guard
          let (item, path) = task.acceptance.lazy.compactMap({ item in
            named(in: item, by: other, sharedWith: task).map { (item, $0) }
          }).first
        else { continue }
        findings.append(
          try Finding(
            ruleID: ruleID, severity: .major, file: file, line: nil,
            message:
              "`\(task.id)`'s acceptance \"\(item)\" exercises `\(path)`, which `\(other.id)` "
              + "writes, but `\(task.id)` doesn't depend on `\(other.id)`; make it depend on "
              + "`\(other.id)`, or have the contract land what the check needs",
            failureScenario:
              "`\(task.id)`'s gates run that check before `\(other.id)` merges, so it reads red "
              + "on a stub and starts a fixer"))
      }
    }
    return findings
  }

  /// Whether `from` depends on `to`, directly or through other tasks.
  private static func reaches(_ from: String, _ to: String, _ byID: [String: Task]) -> Bool {
    var seen: Set<String> = []
    var stack = byID[from]?.deps ?? []
    while let next = stack.popLast() {
      if next == to { return true }
      guard seen.insert(next).inserted else { continue }
      stack += byID[next]?.deps ?? []
    }
    return false
  }

  /// The path of `other`'s write set `item` names, unless `task` writes it too: a path under 1
  /// of its prefixes, the path of 1 of its files, or that file's name without its extension as a
  /// whole word.
  private static func named(in item: String, by other: Task, sharedWith task: Task) -> String? {
    let words = item.split { !($0.isLetter || $0.isNumber || "_/.-".contains($0)) }.map {
      String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }
    let identifiers = Set(
      item.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
    for write in other.writes where !task.writes.contains(write) {
      if write.hasSuffix("/") {
        if let path = words.first(where: { $0.hasPrefix(write) }), !covered(path, task.writes) {
          return path
        }
        continue
      }
      if words.contains(write) { return write }
      guard let stem = stem(of: write) else { continue }
      if identifiers.contains(stem), !task.writes.contains(where: { Self.stem(of: $0) == stem }) {
        return write
      }
    }
    return nil
  }

  /// Whether `writes` holds `path` or a prefix of it.
  private static func covered(_ path: String, _ writes: [String]) -> Bool {
    writes.contains { $0 == path || ($0.hasSuffix("/") && path.hasPrefix($0)) }
  }

  /// A file path's name up to its first `.`; `nil` for a prefix or a name with none.
  private static func stem(of path: String) -> String? {
    guard let file = path.split(separator: "/").last, let dot = file.firstIndex(of: "."),
      dot != file.startIndex
    else { return nil }
    return String(file[..<dot])
  }
}
