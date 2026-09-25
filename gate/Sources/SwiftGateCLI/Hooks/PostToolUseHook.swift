import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// PostToolUse on an edited `*.swift` file (spec §8, < 1s): format it in place, then lint that
/// one file. Never builds or tests. A `*.md` write instead runs `LocalPathRule` on that one file
/// (spec §6.2, D25): a fast, pure text scan, not the formatter/lint pass Swift gets.
enum PostToolUseHook {
  static let editTools: Set<String> = ["Edit", "Write", "MultiEdit"]

  static func run(_ payload: HookPayload, root: URL, dependencies: HookDependencies) async
    -> String?
  {
    guard let tool = payload.toolName, editTools.contains(tool), let absolute = payload.filePath,
      let path = relativePath(absolute, root: root)
    else { return nil }
    if path.hasSuffix(".md") { return markdownLocalPaths(path: path, root: root) }
    guard absolute.hasSuffix(".swift") else { return nil }
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

  /// Reads the file the tool just wrote — PostToolUse fires after the write lands, and the
  /// payload carries no content, so the file on disk is the only source of truth. `nil` when the
  /// file can't be read (mid-edit rename, a tool that only touched metadata) or has no findings.
  private static func markdownLocalPaths(path: String, root: URL) -> String? {
    guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    else { return nil }
    let findings = LocalPathRule.scan(text, file: path)
    guard !findings.isEmpty,
      let report = try? StaticCheckReport.make(
        runID: "hook", durationMilliseconds: 0,
        outcome: .checked(RuleRunResult(findings: findings, allowances: [])))
    else { return nil }
    let message =
      "`swiftgate docs-lint` \(path): \(report.verdict.rawValue)\n" + HookText.findings(report)
    return report.verdict == .red
      ? HookOutput.block(message) : HookOutput.context(.postToolUse, message)
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
