/// `review-input/diff-numbered.txt`: the review diff with each context and added line prefixed by
/// its line in the new file. A finding's `line` is that number; a reviewer counting lines in
/// `diff.patch` cites a line the verifier can't find.
public enum NumberedDiff {
  public static let legend =
    "# Each context and added line starts with its line in the new file; a finding's `line` is that number. Removed lines have none."

  public struct Malformed: Error, Sendable, Equatable, CustomStringConvertible {
    public let header: String
    public var description: String { "unparseable hunk header: \(header)" }
  }

  /// Numbers `git diff` output. File headers and hunk headers pass through unchanged.
  public static func render(_ diff: String) throws(Malformed) -> String {
    var output = [legend]
    // Lines left in the current hunk, old and new side: a hunk body ends by count, not by
    // content, since an added line may itself start with `+++ ` or `diff --git`.
    var oldLeft = 0
    var newLeft = 0
    var next = 0
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
      if oldLeft > 0 || newLeft > 0, let marker = line.first, "+- ".contains(marker) {
        let text = line.dropFirst()
        switch marker {
        case "-":
          oldLeft -= 1
          output.append("\(blank) - \(text)")
        case "+":
          newLeft -= 1
          output.append("\(number(next)) + \(text)")
          next += 1
        default:
          oldLeft -= 1
          newLeft -= 1
          output.append("\(number(next))   \(text)")
          next += 1
        }
      } else if line.hasPrefix("@@ ") {
        let (old, new) = try ranges(line)
        oldLeft = old.count
        newLeft = new.count
        next = new.start
        output.append(String(line))
      } else {
        output.append(String(line))
      }
    }
    return output.joined(separator: "\n")
  }

  private static let width = 6
  private static let blank = String(repeating: " ", count: width)

  private static func number(_ value: Int) -> String {
    let digits = String(value)
    return String(repeating: " ", count: max(0, width - digits.count)) + digits
  }

  /// `@@ -a[,b] +c[,d] @@`: a missing count is 1.
  private static func ranges(_ header: Substring) throws(Malformed)
    -> (old: (start: Int, count: Int), new: (start: Int, count: Int))
  {
    let fields = header.split(separator: " ")
    guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+"),
      let old = range(fields[1].dropFirst()), let new = range(fields[2].dropFirst())
    else { throw Malformed(header: String(header)) }
    return (old, new)
  }

  private static func range(_ text: Substring) -> (start: Int, count: Int)? {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count <= 2, let start = Int(parts[0]) else { return nil }
    guard parts.count == 2 else { return (start, 1) }
    guard let count = Int(parts[1]) else { return nil }
    return (start, count)
  }
}
