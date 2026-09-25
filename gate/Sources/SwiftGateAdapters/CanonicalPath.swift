import Foundation

/// The one spelling of a filesystem path the gate compares paths in: `realpath(3)`, which is how
/// `swift package describe`, the compiler and llvm-cov report them. Foundation's
/// `resolvingSymlinksInPath()` is not interchangeable: it maps `/private/tmp` and `/private/var`
/// back to `/tmp` and `/var`, so a root resolved that way never prefixes a tool-reported path in a
/// repository under either. Every root or file compared against tool output goes through here.
public enum CanonicalPath {
  /// `url` standardized with its symlinks resolved. A path that does not exist yet keeps its
  /// missing components under its deepest existing ancestor, resolved.
  public static func of(_ url: URL) -> String {
    let standardized = url.standardizedFileURL.path
    var existing = standardized
    var missing: [String] = []
    while true {
      if let resolved = realpath(existing, nil) {
        defer { free(resolved) }
        let base = String(cString: resolved)
        guard !missing.isEmpty else { return base }
        return (base == "/" ? "" : base) + "/" + missing.joined(separator: "/")
      }
      let parent = (existing as NSString).deletingLastPathComponent
      guard parent != existing, !parent.isEmpty else { return standardized }
      missing.insert((existing as NSString).lastPathComponent, at: 0)
      existing = parent
    }
  }

  /// ``of(_:)`` as a file URL, keeping whether `url` names a directory.
  public static func url(_ url: URL) -> URL {
    URL(filePath: of(url), directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
  }
}
