/// A `diff -u`-style rendering of one file's change, for `bootstrap`'s dry run.
public enum UnifiedDiff {
  /// `old == nil` renders a created file; `new == nil` a removed one. Equal texts render `""`.
  public static func render(path: String, old: String?, new: String?, context: Int = 3) -> String {
    guard old != new else { return "" }
    let before = lines(old ?? "")
    let after = lines(new ?? "")
    let edits = script(before, after)
    var output = [
      old == nil ? "--- /dev/null" : "--- a/\(path)",
      new == nil ? "+++ /dev/null" : "+++ b/\(path)",
    ]
    for hunk in hunks(edits, context: context) {
      output.append(hunk.header)
      output += hunk.lines
    }
    return output.joined(separator: "\n") + "\n"
  }

  private enum Edit {
    case keep(String)
    case remove(String)
    case add(String)

    var isChange: Bool {
      if case .keep = self { return false }
      return true
    }
  }

  private struct Hunk {
    let header: String
    let lines: [String]
  }

  private static func lines(_ text: String) -> [String] {
    var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if parts.last == "" { parts.removeLast() }
    return parts
  }

  /// Longest-common-subsequence edit script. Bootstrap files are a few hundred lines at most, so
  /// the quadratic table stays small.
  private static func script(_ old: [String], _ new: [String]) -> [Edit] {
    let rows = old.count
    let columns = new.count
    var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
    for row in stride(from: rows - 1, through: 0, by: -1) {
      for column in stride(from: columns - 1, through: 0, by: -1) {
        table[row][column] =
          old[row] == new[column]
          ? table[row + 1][column + 1] + 1
          : max(table[row + 1][column], table[row][column + 1])
      }
    }
    var edits: [Edit] = []
    var row = 0
    var column = 0
    while row < rows || column < columns {
      if row < rows, column < columns, old[row] == new[column] {
        edits.append(.keep(old[row]))
        row += 1
        column += 1
      } else if row < rows, column == columns || table[row + 1][column] >= table[row][column + 1] {
        edits.append(.remove(old[row]))
        row += 1
      } else {
        edits.append(.add(new[column]))
        column += 1
      }
    }
    return edits
  }

  private static func hunks(_ edits: [Edit], context: Int) -> [Hunk] {
    let changed = edits.indices.filter { edits[$0].isChange }
    guard let first = changed.first else { return [] }
    var ranges: [ClosedRange<Int>] = []
    var start = max(0, first - context)
    var end = min(edits.count - 1, first + context)
    for index in changed.dropFirst() {
      if index - context <= end + 1 {
        end = min(edits.count - 1, index + context)
      } else {
        ranges.append(start...end)
        start = max(0, index - context)
        end = min(edits.count - 1, index + context)
      }
    }
    ranges.append(start...end)

    return ranges.map { range in
      var oldStart = 1
      var newStart = 1
      for edit in edits[..<range.lowerBound] {
        switch edit {
        case .keep:
          oldStart += 1
          newStart += 1
        case .remove: oldStart += 1
        case .add: newStart += 1
        }
      }
      var oldCount = 0
      var newCount = 0
      var body: [String] = []
      for edit in edits[range] {
        switch edit {
        case .keep(let line):
          oldCount += 1
          newCount += 1
          body.append(" \(line)")
        case .remove(let line):
          oldCount += 1
          body.append("-\(line)")
        case .add(let line):
          newCount += 1
          body.append("+\(line)")
        }
      }
      // An empty side is numbered by the line before it, as `diff -u` does.
      let oldLabel = "\(oldCount == 0 ? oldStart - 1 : oldStart),\(oldCount)"
      let newLabel = "\(newCount == 0 ? newStart - 1 : newStart),\(newCount)"
      return Hunk(header: "@@ -\(oldLabel) +\(newLabel) @@", lines: body)
    }
  }
}
