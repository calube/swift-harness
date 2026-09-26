import Foundation

/// Which lines of one file have code, and which of those ran.
public struct FileLineCoverage: Sendable, Equatable {
  public var executable: Set<Int>
  public var covered: Set<Int>

  public init(executable: Set<Int>, covered: Set<Int>) {
    self.executable = executable
    self.covered = covered
  }
}

public struct CoverageParseError: Error, Sendable, Equatable {
  public let detail: String
}

/// Per-line coverage of repository files, from llvm-cov export JSON (`swift test
/// --enable-code-coverage`).
public struct LineCoverage: Sendable, Equatable {
  /// Repository-relative path → lines.
  public var files: [String: FileLineCoverage]

  public init(files: [String: FileLineCoverage]) {
    self.files = files
  }

  /// Keeps files under `repositoryRoot` and outside `.build/`; dependency checkouts and generated
  /// runners are never changed code.
  public init(llvmExport data: Data, repositoryRoot: String) throws(CoverageParseError) {
    let root = repositoryRoot.hasSuffix("/") ? repositoryRoot : repositoryRoot + "/"
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let exports = object["data"] as? [[String: Any]]
    else { throw CoverageParseError(detail: "not an llvm-cov export (no data array)") }
    var files: [String: FileLineCoverage] = [:]
    for export in exports {
      guard let entries = export["files"] as? [[String: Any]] else {
        throw CoverageParseError(detail: "export without a files array")
      }
      for entry in entries {
        guard let filename = entry["filename"] as? String,
          let rawSegments = entry["segments"] as? [[Any]]
        else { throw CoverageParseError(detail: "file entry without filename or segments") }
        guard filename.hasPrefix(root) else { continue }
        let path = String(filename.dropFirst(root.count))
        if path.hasPrefix(".build/") || path.contains("/.build/") { continue }
        let segments = try rawSegments.map { raw throws(CoverageParseError) in
          try Segment(raw)
        }
        let lines = Self.lines(of: segments)
        files[path] = files[path].map { Self.merge($0, lines) } ?? lines
      }
    }
    self.files = files
  }

  /// A line is covered if any run covered it; executable if any run compiled code on it.
  public func merged(with other: LineCoverage) -> LineCoverage {
    LineCoverage(files: files.merging(other.files, uniquingKeysWith: Self.merge))
  }

  private static func merge(_ a: FileLineCoverage, _ b: FileLineCoverage) -> FileLineCoverage {
    FileLineCoverage(
      executable: a.executable.union(b.executable), covered: a.covered.union(b.covered))
  }

  /// One llvm-cov segment: `[line, column, count, hasCount, isRegionEntry, isGapRegion]`.
  struct Segment {
    let line: Int
    let count: Int
    let hasCount: Bool
    let isRegionEntry: Bool
    let isGapRegion: Bool

    init(_ raw: [Any]) throws(CoverageParseError) {
      guard raw.count >= 6, let line = raw[0] as? Int, let count = raw[2] as? Int,
        let hasCount = raw[3] as? Bool, let isRegionEntry = raw[4] as? Bool,
        let isGapRegion = raw[5] as? Bool
      else { throw CoverageParseError(detail: "malformed segment \(raw)") }
      self.line = line
      self.count = count
      self.hasCount = hasCount
      self.isRegionEntry = isRegionEntry
      self.isGapRegion = isGapRegion
    }
  }

  /// LLVM's line-coverage rule (`LineCoverageStats`): a line is executable when a region starts
  /// on it or a counted region wraps into it, unless it opens a skipped region; its count is the
  /// highest among the wrapping region and the regions starting on it.
  static func lines(of segments: [Segment]) -> FileLineCoverage {
    var executable = Set<Int>()
    var covered = Set<Int>()
    guard let last = segments.map(\.line).max() else {
      return FileLineCoverage(executable: [], covered: [])
    }
    var wrapped: Segment?
    var index = 0
    for line in 1...last {
      var onLine: [Segment] = []
      while index < segments.count, segments[index].line == line {
        onLine.append(segments[index])
        index += 1
      }
      let starts = onLine.filter { !$0.isGapRegion && $0.hasCount && $0.isRegionEntry }
      let opensSkipped = onLine.first.map { !$0.hasCount && $0.isRegionEntry } ?? false
      let mapped = !opensSkipped && ((wrapped?.hasCount ?? false) || !starts.isEmpty)
      if mapped {
        let count = max(wrapped?.count ?? 0, starts.map(\.count).max() ?? 0)
        executable.insert(line)
        if count > 0 { covered.insert(line) }
      }
      if let lastOnLine = onLine.last { wrapped = lastOnLine }
    }
    return FileLineCoverage(executable: executable, covered: covered)
  }
}
