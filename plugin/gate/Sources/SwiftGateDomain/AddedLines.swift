/// Lines a change adds to one file, as 1-based inclusive ranges in the file's new content.
public struct AddedLines: Sendable, Equatable {
  /// Repository-relative path in the new content.
  public let path: String
  /// Ascending, non-overlapping, non-empty ranges.
  public let ranges: [ClosedRange<Int>]

  public init(path: String, ranges: [ClosedRange<Int>]) {
    self.path = path
    self.ranges = ranges
  }

  public func contains(line: Int) -> Bool {
    ranges.contains { $0.contains(line) }
  }
}
