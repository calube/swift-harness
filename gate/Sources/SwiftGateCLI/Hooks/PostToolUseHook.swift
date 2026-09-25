import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// PostToolUse on an edited `*.swift` file (spec §8, < 1s): format it in place, then lint that
/// one file. Never builds or tests.
enum PostToolUseHook {
  static let editTools: Set<String> = ["Edit", "Write", "MultiEdit"]

  static func run(_ payload: HookPayload, root: URL, dependencies: HookDependencies) async
    -> String?
  {
    guard let tool = payload.toolName, editTools.contains(tool), let absolute = payload.filePath,
      absolute.hasSuffix(".swift"), let path = relativePath(absolute, root: root)
    else { return nil }
    let config = try? StaticCheckInputs.loadConfig(root: root).get()
    let excluded = config?.exclude ?? []
    guard FileManager.default.fileExists(atPath: root.appending(path: path).path),
      !SwiftSourceCollector(root: root, excluding: excluded).isExcluded(path)
    else { return nil }

    var notes: [String] = []
    do throws(SwiftFormatError) {
      if try await dependencies.formatter.format(path: path) {
        notes.append("swift format reformatted \(path); re-read it before editing again.")
      }
    } catch {
      // Commonly a file mid-edit that does not parse yet; the lint below says what is wrong.
      notes.append("swift format could not format \(path): \(error)")
    }

    let outcome = await LintCheck.run(root: root, paths: [path], swiftPM: dependencies.swiftPM)
    guard
      let report = try? StaticCheckReport.make(
        runID: "hook", durationMilliseconds: 0, outcome: outcome)
    else { return nil }
    let lint =
      report.findings.isEmpty
      ? nil
      : "`swiftgate lint \(path)`: \(report.verdict.rawValue)\n"
        + HookText.findings(report)
    let text = (notes + [lint].compactMap { $0 }).joined(separator: "\n")
    guard !text.isEmpty else { return nil }
    return report.verdict == .red
      ? HookOutput.block(text) : HookOutput.context(.postToolUse, text)
  }

  /// `nil` for a file outside the project: another project's gate owns it.
  static func relativePath(_ absolute: String, root: URL) -> String? {
    let file = CanonicalPath.of(URL(filePath: absolute))
    let base = CanonicalPath.of(root)
    let prefix = base.hasSuffix("/") ? base : base + "/"
    guard file.hasPrefix(prefix) else { return nil }
    return String(file.dropFirst(prefix.count))
  }
}
