import Foundation

/// A run's JSON evidence as a report carries it: no string names a machine path. A path inside
/// the run becomes relative to the run's directory; any other absolute path keeps only its last
/// component.
public enum RunEvidenceJSON {
  /// Whether a report rewrites a carried file of this name rather than copying its bytes.
  public static func rewrites(_ fileName: String) -> Bool {
    false
  }

  /// `data`, a JSON or NDJSON file of run `runID`, with every absolute path in its strings
  /// rewritten; `nil` when it doesn't parse, so the caller copies it as it is.
  public static func relativized(_ data: Data, runID: String) -> Data? {
    nil
  }
}
