import Foundation
import SwiftGateDomain

/// Assembles the known-id feed spec §5.1 requires `comments`, `testlint` and the commit-message
/// check to share: every ledger task id under the shared plan state (spanning every linked
/// worktree via the git common dir), every claim id committed alongside a design doc, and every
/// requirement/test-plan id a design doc declares. Feeds
/// ``KnownIds/build(ledgerTaskIds:claimIds:docIds:)``.
public enum KnownIdSources {
  /// A source this build can't read (no common dir, no git repository, a malformed ledger, claims
  /// file, or design doc) contributes nothing rather than blocking the caller: a check whose
  /// known-id feed can't be fully built must still run, with whatever ids it could read, since
  /// skipping the whole check would be defeated by exactly the failure it exists to catch.
  public static func load(root: URL, git: any Git) async -> Set<String> {
    KnownIds.build(
      ledgerTaskIds: await ledgerTaskIds(git: git), claimIds: claimIds(root: root),
      docIds: docIds(root: root))
  }

  static func ledgerTaskIds(git: any Git) async -> [String] {
    guard let common = try? await git.commonDirectory(),
      let layout = try? PlanStateLayout(commonDirectory: common)
    else { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.root)) ?? []
    return names.sorted().flatMap { name -> [String] in
      guard let plan = try? layout.plan(name),
        let data = FileManager.default.contents(atPath: plan.ledgerFile),
        let ledger = try? LedgerJSON.decode(data)
      else { return [] }
      return ledger.tasks.map(\.id)
    }
  }

  static func claimIds(root: URL) -> [String] {
    RepositoryFiles.list(root: root, under: "docs", where: isClaimsFile).flatMap {
      path -> [String] in
      guard let data = FileManager.default.contents(atPath: root.appending(path: path).path)
      else { return [] }
      return ClaimJSON.decode(data).claims.map(\.id)
    }
  }

  static func docIds(root: URL) -> [String] {
    RepositoryFiles.list(root: root, under: "docs", where: isDesignDoc).flatMap {
      path -> [String] in
      guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else {
        return []
      }
      let design = DesignDocument(markdown: MarkdownDocument.parse(text))
      return design.requirements.map(\.id) + design.testPlan.map(\.id)
    }
  }

  /// `path` is relative to the `docs` directory (``RepositoryFiles/list(root:under:where:)``'s
  /// contract), so this only inspects the trailing components, not the `docs/` prefix.
  private static func isClaimsFile(_ path: String) -> Bool {
    let components = path.split(separator: "/")
    guard components.count >= 2, components.last == "claims.jsonl" else { return false }
    return components[components.count - 2].hasSuffix(".evidence")
  }

  private static func isDesignDoc(_ path: String) -> Bool {
    guard path.hasSuffix(".md") else { return false }
    let components = path.split(separator: "/")
    guard components.count >= 2 else { return false }
    return components[components.count - 2] == "designs"
  }
}
