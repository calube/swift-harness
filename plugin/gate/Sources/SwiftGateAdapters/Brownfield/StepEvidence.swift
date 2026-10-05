import Foundation
import SwiftGateDomain

/// Keeps 1 failing area step's output tail and its report, JUnit or a result bundle, in a
/// folder, before a later run of the same step overwrites them.
public enum StepEvidence {
  /// Writes `<name>.txt` with the outcome's tail into `directory`, copies the request's JUnit
  /// files beside it and moves its result bundle there. Returns the absolute paths kept; empty
  /// for a passing outcome.
  @discardableResult
  public static func keep(
    _ outcome: AreaCommandOutcome, of request: AreaCommandRequest, named name: String,
    in directory: URL
  ) -> [String] {
    let tail: String
    switch outcome {
    case .passed: return []
    case .failed(let exit, let text, _): tail = "exit \(exit)\n\(text)"
    case .crashed(let signal, let text):
      tail = "crashed" + (signal.map { " with signal \($0)" } ?? "") + "\n\(text)"
    case .timedOut(let text): tail = "timed out\n\(text)"
    }
    let files = FileManager.default
    do {
      try files.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      return []
    }
    var kept: [String] = []
    let text = directory.appending(path: "\(name).txt")
    if (try? Data((request.command + "\n" + tail + "\n").utf8).write(to: text, options: .atomic))
      != nil
    {
      kept.append(text.path(percentEncoded: false))
    }
    if let junitPath = request.junitPath {
      for (index, report) in JUnitReportFiles.files(at: junitPath).enumerated() {
        // A Gradle or Maven area's `{junit}` is a directory of reports.
        var isDirectory: ObjCBool = false
        let suffix =
          files.fileExists(atPath: report, isDirectory: &isDirectory) && isDirectory.boolValue
          ? "-junit" : ".xml"
        let copy = directory.appending(path: name + (index == 0 ? "" : "-\(index)") + suffix)
        try? files.removeItem(at: copy)
        if (try? files.copyItem(atPath: report, toPath: copy.path(percentEncoded: false))) != nil {
          kept.append(copy.path(percentEncoded: false))
        }
      }
    }
    if let bundle = request.resultBundlePath, files.fileExists(atPath: bundle) {
      let moved = directory.appending(path: "\(name).xcresult")
      try? files.removeItem(at: moved)
      if (try? files.moveItem(atPath: bundle, toPath: moved.path(percentEncoded: false))) != nil {
        kept.append(moved.path(percentEncoded: false))
      }
    }
    return kept
  }
}
