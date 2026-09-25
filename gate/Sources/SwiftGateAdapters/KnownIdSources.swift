import Foundation
import SwiftGateDomain

/// Assembles the known-id feed spec §5.1 requires `comments`, `testlint` and the commit-message
/// check to share: every ledger task id under the shared plan state (spanning every linked
/// worktree via the git common dir), every claim id committed alongside a design doc, and every
/// requirement/test-plan id a design doc declares. Feeds
/// ``KnownIds/build(ledgerTaskIds:claimIds:docIds:)``.
public enum KnownIdSources {
  /// A source that exists but could not be read or parsed: a ledger, claims file or doc found on
  /// disk whose bytes didn't decode. Silently dropping this from the feed would silently narrow
  /// the id-leak check with no signal, so the caller turns each one into a non-gating finding
  /// naming `path`.
  public struct UnreadableSource: Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
      self.path = path
      self.reason = reason
    }
  }

  public struct Loaded: Sendable, Equatable {
    public let ids: Set<String>
    /// Sorted by path, so two loads of the same broken state report findings in the same order.
    public let unreadable: [UnreadableSource]

    public init(ids: Set<String>, unreadable: [UnreadableSource]) {
      self.ids = ids
      self.unreadable = unreadable
    }
  }

  /// A source that is simply absent — no common dir, no plan ever claimed, a plan mid-setup with
  /// no ledger written yet — contributes nothing and is never reported: absence isn't corruption,
  /// and reporting it would make every ordinary repository noisy.
  public static func load(root: URL, git: any Git) async -> Loaded {
    let ledger = await ledgerTaskIds(git: git)
    let claims = claimIds(root: root)
    let docs = docIds(root: root)
    return Loaded(
      ids: KnownIds.build(ledgerTaskIds: ledger.ids, claimIds: claims.ids, docIds: docs.ids),
      unreadable: (ledger.unreadable + claims.unreadable + docs.unreadable)
        .sorted { $0.path < $1.path })
  }

  private struct SourceResult {
    var ids: [String] = []
    var unreadable: [UnreadableSource] = []
  }

  private static func ledgerTaskIds(git: any Git) async -> SourceResult {
    guard let common = try? await git.commonDirectory(),
      let layout = try? PlanStateLayout(commonDirectory: common)
    else { return SourceResult() }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.root)) ?? []
    var result = SourceResult()
    for name in names.sorted() {
      guard let plan = try? layout.plan(name) else {
        result.unreadable.append(
          UnreadableSource(
            path: "\(layout.root)/\(name)", reason: "not a valid plan directory name"))
        continue
      }
      // A plan directory with no ledger yet (claimed but not scheduled) is normal, not corrupt.
      guard FileManager.default.fileExists(atPath: plan.ledgerFile) else { continue }
      guard let data = FileManager.default.contents(atPath: plan.ledgerFile) else {
        result.unreadable.append(
          UnreadableSource(path: plan.ledgerFile, reason: "could not be read"))
        continue
      }
      do {
        result.ids += try LedgerJSON.decode(data).tasks.map(\.id)
      } catch {
        result.unreadable.append(UnreadableSource(path: plan.ledgerFile, reason: "\(error)"))
      }
    }
    return result
  }

  private static func claimIds(root: URL) -> SourceResult {
    var result = SourceResult()
    for path in RepositoryFiles.list(root: root, under: "docs", where: isClaimsFile) {
      guard let data = FileManager.default.contents(atPath: root.appending(path: path).path) else {
        result.unreadable.append(UnreadableSource(path: path, reason: "could not be read"))
        continue
      }
      let decoded = ClaimJSON.decode(data)
      result.ids += decoded.claims.map(\.id)
      if decoded.invalidLines > 0 {
        result.unreadable.append(
          UnreadableSource(
            path: path, reason: "\(decoded.invalidLines) line(s) could not be parsed as JSON"))
      }
    }
    return result
  }

  private static func docIds(root: URL) -> SourceResult {
    var result = SourceResult()
    for path in RepositoryFiles.list(root: root, under: "docs", where: isDesignDoc) {
      do {
        let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
        let design = DesignDocument(markdown: MarkdownDocument.parse(text))
        result.ids += design.requirements.map(\.id) + design.testPlan.map(\.id)
      } catch {
        result.unreadable.append(
          UnreadableSource(path: path, reason: error.localizedDescription))
      }
    }
    return result
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
