import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// A backstop around every gate run: a hook denies an agent from hand-editing a committed
/// `Package.resolved` (`guard.package-resolved`), so a gate run that rewrites one itself — a
/// SwiftPM or xcodebuild resolve falling back off the committed pins — must never pass quietly.
/// This snapshots every `Package.resolved`'s content hash before the run and compares after; the
/// per-invocation `--only-use-versions-from-resolved-file` /
/// `-onlyUsePackageVersionsFromResolvedFile` flags are the primary defense, so a change here means
/// they missed a path.
enum ResolvedFileGuard {
  static let rewrittenRuleID = "swiftgate.resolved-file-rewritten"

  /// Git blob hash of each `Package.resolved` under `root`'s current working-tree content
  /// (`RepositoryFiles.list` already skips hidden directories, so never `.build/checkouts/*`'s
  /// own copies). Empty (never throws) if git can't hash them, which trades a rare missed
  /// backstop for never blocking a run the flags alone already protect.
  static func snapshot(root: URL, git: any Git) async -> [String: String] {
    let paths = RepositoryFiles.list(root: root, under: "") { $0.hasSuffix("Package.resolved") }
    guard !paths.isEmpty else { return [:] }
    return (try? await git.contentHashes(of: paths)) ?? [:]
  }

  /// A major finding naming every tracked `Package.resolved` this run rewrote or deleted, or `nil`
  /// if none changed.
  static func finding(before: [String: String], after: [String: String])
    throws(ReportContractViolation) -> Finding?
  {
    let changed = before.keys.filter { after[$0] != before[$0] }.sorted()
    guard !changed.isEmpty else { return nil }
    return try Finding(
      ruleID: rewrittenRuleID, severity: .major, file: changed[0], line: nil,
      message:
        "this run rewrote \(changed.joined(separator: ", ")): a gate may only build and test "
        + "against the committed pins, never edit them itself (the same edit is denied by hand, "
        + "rule guard.package-resolved)",
      failureScenario: "Package.resolved commits a revision missing from the remote")
  }
}
