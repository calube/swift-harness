/// The committed evidence layout that travels with a design doc (spec §4 storage model):
/// `docs/<area>/designs/<slug>.evidence/{claims.jsonl, amendments.jsonl, snapshots/, captures/,
/// probes/}`. Pure path arithmetic — no filesystem access, so it can't drift into an adapter.
public struct EvidenceLayout: Sendable, Equatable {
  /// `docs/<area>/designs/<slug>.evidence`.
  public let root: String

  /// `designDocPath` is the design doc's own path, e.g.
  /// `docs/ordering/designs/offline-order-queue.md`.
  public init(designDocPath: String) {
    let stem = designDocPath.hasSuffix(".md") ? String(designDocPath.dropLast(3)) : designDocPath
    self.root = stem + ".evidence"
  }

  public var claimsFile: String { root + "/claims.jsonl" }
  public var amendmentsFile: String { root + "/amendments.jsonl" }
  public var snapshotsDirectory: String { root + "/snapshots" }
  public var capturesDirectory: String { root + "/captures" }
  public var probesDirectory: String { root + "/probes" }
}
