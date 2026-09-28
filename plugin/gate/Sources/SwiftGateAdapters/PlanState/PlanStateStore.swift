import Foundation
import SwiftGateDomain

/// Reads one plan's shared state (`plan.json`, `ledger.json`) from under the git common dir, so
/// every linked worktree of the repository reads the same files. Read-only: `plan claim` and the
/// orchestrator are the writers.
public struct PlanStateStore: Sendable {
  public let plan: PlanStateLayout.Plan

  public init(plan: PlanStateLayout.Plan) {
    self.plan = plan
  }

  /// Places `slug` under `git`'s common dir.
  public static func locate(slug: String, git: any Git) async throws(PlanStateStoreError)
    -> PlanStateStore
  {
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      throw .commonDirectory("\(error)")
    }
    do {
      return PlanStateStore(plan: try PlanStateLayout(commonDirectory: common).plan(slug))
    } catch {
      throw .invalidPlanName(slug)
    }
  }

  public func planFile() throws(PlanStateStoreError) -> PlanFile {
    let data = try read(plan.planFile)
    do {
      return try PlanFileJSON.decode(data)
    } catch {
      throw .malformed(path: plan.planFile, detail: "\(error)")
    }
  }

  /// The absolute path of a spec-page plan's page, inside this plan's directory.
  public func specPageFile(_ source: PlanFile.SpecPageSource) -> String {
    plan.directory + "/" + source.path
  }

  public func ledger() throws(PlanStateStoreError) -> Ledger {
    let data = try read(plan.ledgerFile)
    do {
      return try LedgerJSON.decode(data)
    } catch {
      throw .malformed(path: plan.ledgerFile, detail: "\(error)")
    }
  }

  private func read(_ path: String) throws(PlanStateStoreError) -> Data {
    guard FileManager.default.fileExists(atPath: path) else { throw .missing(path: path) }
    do {
      return try Data(contentsOf: URL(filePath: path))
    } catch {
      throw .unreadable(path: path, detail: error.localizedDescription)
    }
  }
}

/// Every case means the plan's state can't be read, so nothing can be said about the plan.
public enum PlanStateStoreError: Error, Sendable, Equatable {
  case commonDirectory(String)
  case invalidPlanName(String)
  case missing(path: String)
  case unreadable(path: String, detail: String)
  case malformed(path: String, detail: String)

  public var verdict: Verdict { .blocked }
}

/// The committed revision of a design doc whose ``DesignSha`` is `designSha` (spec §5.4). The
/// stripped content a `designSha` hashes is never stored in git, so this walks the doc's history
/// newest first, strips each revision's status line and hashes it in process, stopping at the
/// first match. The working tree is never read: an unapproved edit must not reach the lint.
public enum DesignAtSha {
  public struct Found: Sendable, Equatable {
    public let commit: String
    public let text: String
  }

  /// - Returns: `nil` when no committed revision of `path` hashes to `designSha`.
  public static func find(designSha: String, path: String, git: any Git)
    async throws(GitError) -> Found?
  {
    for commit in try await git.revisions(of: path) {
      // A commit from before a rename holds the doc under another path; it can't match.
      guard let text = try await git.contents(of: [path], at: commit)[path] else { continue }
      if GitBlobID.of(DesignSha.strippingStatus(text)) == designSha {
        return Found(commit: commit, text: text)
      }
    }
    return nil
  }
}
