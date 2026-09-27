import Foundation

/// The new-file lines a review diff adds or changes, per file: what "introduced by the diff" means
/// for a finding. Read from `diff-numbered.txt`, never from an agent's opinion.
public struct ChangedLines: Sendable, Equatable {
  public let byFile: [String: Set<Int>]

  public init(byFile: [String: Set<Int>]) {
    self.byFile = byFile
  }

  /// Added lines count as changed, and so do the numbered lines on either side of a removal: a
  /// deleted guard leaves no added line, but its defect shows on the lines around the gap.
  public static func parse(numberedDiff: String) -> ChangedLines {
    var byFile: [String: Set<Int>] = [:]
    var file: String?
    var previous: Int?
    var afterRemoval = false
    for line in numberedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+++ ") {
        let path = line.dropFirst(4)
        file = path.hasPrefix("b/") ? String(path.dropFirst(2)) : nil
        previous = nil
        afterRemoval = false
        continue
      }
      if line.hasPrefix("@@ ") {
        previous = nil
        afterRemoval = false
        continue
      }
      guard let file, let (number, marker) = body(line) else { continue }
      switch marker {
      case "-":
        if let previous { byFile[file, default: []].insert(previous) }
        afterRemoval = true
      case "+":
        if let number { byFile[file, default: []].insert(number) }
      default:
        if afterRemoval, let number { byFile[file, default: []].insert(number) }
      }
      if let number { previous = number }
      if marker != "-" { afterRemoval = false }
    }
    return ChangedLines(byFile: byFile)
  }

  /// Whether any line in `lines` of `file` is one the diff added or changed. A file the diff
  /// never touches introduces nothing.
  public func introduces(file: String, lines: ClosedRange<Int>) -> Bool {
    guard let changed = byFile[file] else { return false }
    return lines.contains { changed.contains($0) }
  }

  /// `NumberedDiff` body lines: a 6-column number (blank on a removal), a space, then the marker.
  private static func body(_ line: Substring) -> (Int?, Character)? {
    let characters = Array(line.prefix(8))
    guard characters.count == 8, characters[6] == " ", "+- ".contains(characters[7]) else {
      return nil
    }
    let column = String(characters[0..<6]).trimmingCharacters(in: .whitespaces)
    if column.isEmpty { return characters[7] == "-" ? (nil, "-") : nil }
    guard let number = Int(column), characters[7] != "-" else { return nil }
    return (number, characters[7])
  }
}

/// Where synthesis learns which findings the diff introduced.
public enum ReviewBaseline: Sendable, Equatable {
  case diff(ChangedLines)
  /// Every finding counts toward the verdict, and the report says why the check didn't run.
  case unavailable(reason: String)
}

/// The review contract's severity rules, by id. The verifier records the one it applied, so a
/// test can check the judgement and synthesis can enforce the severity it implies.
public enum SeverityRule: String, Sendable, Codable, CaseIterable {
  /// A defect users or callers hit through ordinary use, such as a race a tap sequence triggers.
  case defectUsersHit = "defect-users-hit"
  case defectNarrowTrigger = "defect-narrow-trigger"
  /// An architecture violation whose fix moves logic across a module boundary or changes a
  /// module's kind.
  case structuralFix = "structural-fix"
  case doViolation = "do-violation"
  case noHarmYet = "no-harm-yet"
  case taste

  /// The least severity the rule allows; synthesis raises a finding below it and never lowers.
  public var severity: Severity {
    switch self {
    case .defectUsersHit, .structuralFix: .blocker
    case .defectNarrowTrigger, .doViolation: .major
    case .noHarmYet: .minor
    case .taste: .nit
    }
  }

  /// The finding kinds the contract states the rule for.
  public func applies(to kind: ReviewFinding.Kind) -> Bool {
    switch self {
    case .defectUsersHit, .defectNarrowTrigger: kind == .defect
    case .structuralFix, .doViolation: kind == .standardsViolation
    case .noHarmYet, .taste: true
    }
  }
}
