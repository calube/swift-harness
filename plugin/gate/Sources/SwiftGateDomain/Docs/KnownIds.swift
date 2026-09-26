import Foundation

/// Every id spec §5.1 says must stay inside the ledger and evidence, never leak into committed
/// code: free-form ledger task ids and the `req-`/`test-`/`ev-` ids docs and claims commit (see
/// ``IdPolicy``). `comments` and `testlint` flag any of these ids — or a codename-shaped token —
/// found in a comment or test name.
///
/// This type only merges already-read ids into one set; reading them off disk (every common-dir
/// ledger, `claims.jsonl`, and design docs) is the adapter layer's job, wired in by whichever
/// caller assembles the check's `RuleContext`.
public enum KnownIds {
  /// Blank entries are dropped: a missing or malformed source line must never turn into an id
  /// that matches empty text everywhere.
  public static func build(
    ledgerTaskIds: [String] = [], claimIds: [String] = [], docIds: [String] = []
  ) -> Set<String> {
    Set(
      (ledgerTaskIds + claimIds + docIds)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty })
  }
}
