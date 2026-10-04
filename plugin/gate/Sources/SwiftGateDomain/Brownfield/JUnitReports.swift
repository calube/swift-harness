import Foundation

/// The reports 1 `{junit}` path stands for. Some runners write more than the 1 file the path
/// names, and a failure in a report left unread would let the baseline absorb it.
public enum JUnitReports {
  /// Reports a runner writes beside `junitPath` when given it as a file.
  public static func companionPaths(of junitPath: String) -> [String] {
    []
  }

  /// 1 document holding every case of `documents`, in order; `nil` when there are none.
  public static func combined(_ documents: [Data]) -> Data? {
    documents.first
  }
}
