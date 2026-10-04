import Foundation
import SwiftGateDomain

/// The JUnit or xUnit reports 1 `{junit}` path stands for, on disk.
public enum JUnitReportFiles {
  /// Removes what an earlier run left at `junitPath` and its companions, so it is never read as
  /// this run's, and makes the directory it sits in, which not every runner creates.
  public static func clear(at junitPath: String) {
    for path in [junitPath] + JUnitReports.companionPaths(of: junitPath) {
      try? FileManager.default.removeItem(atPath: path)
    }
    try? FileManager.default.createDirectory(
      atPath: (junitPath as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true)
  }

  /// The file at `junitPath` and its companions, or every `.xml` file in it when a command made
  /// it a directory of reports, as Gradle and Maven areas do; `nil` when there are none. A report
  /// that is listed but can't be read leaves no report at all, so a caller never judges a run
  /// without that report's cases.
  public static func read(at junitPath: String) -> Data? {
    let files = FileManager.default
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: junitPath, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      return JUnitReports.combined(
        ([junitPath] + JUnitReports.companionPaths(of: junitPath)).compactMap {
          files.contents(atPath: $0)
        })
    }
    guard let names = try? files.contentsOfDirectory(atPath: junitPath) else { return nil }
    var documents: [Data] = []
    for name in names.sorted() where name.hasSuffix(".xml") {
      guard let data = files.contents(atPath: (junitPath as NSString).appendingPathComponent(name))
      else { return nil }
      documents.append(data)
    }
    return JUnitReports.combined(documents)
  }
}
