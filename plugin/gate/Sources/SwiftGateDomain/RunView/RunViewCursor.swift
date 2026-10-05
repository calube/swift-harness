import Foundation

/// What every file a run view reads held at 1 moment: each stream file's byte length and the
/// ledger log's, plus the files a run rewrites in place. 2 equal snapshots build the same view.
public struct RunViewSnapshot: Sendable, Equatable {
  /// 1 file's length and modification time.
  public struct Stamp: Sendable, Equatable, Hashable {
    public var bytes: Int
    /// Catches a file rewritten in place to the same length.
    public var modifiedNanoseconds: Int

    public init(bytes: Int, modifiedNanoseconds: Int = 0) {
      self.bytes = bytes
      self.modifiedNanoseconds = modifiedNanoseconds
    }
  }

  /// By path, as the reader names it.
  public var files: [String: Stamp]

  public init(files: [String: Stamp] = [:]) {
    self.files = files
  }

  /// The opaque cursor a live page polls after: a digest of every path and stamp, since the
  /// offsets themselves outgrow the payload guard's string cap once a run has a few stores.
  public var cursor: String {
    // FNV-1a over a canonical listing: stable across processes, unlike `Hasher`.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for path in files.keys.sorted() {
      let stamp = files[path] ?? Stamp(bytes: 0)
      for byte in "\(path)\t\(stamp.bytes)\t\(stamp.modifiedNanoseconds)\n".utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
      }
    }
    let hex = String(hash, radix: 16)
    return "c1-" + String(repeating: "0", count: 16 - hex.count) + hex
  }
}

/// The part of a ``RunView`` that changed after a cursor: each array holds only its new or
/// changed rows, but `damage` and `unwritten` come whole, and an absent key means nothing changed
/// there. The page merges the rest by id.
public struct RunViewChanges: Sendable, Equatable, Encodable {
  public var cursor: String
  public var run: RunView.Run?
  public var spec: [RunView.SpecRow]?
  public var tasks: [RunView.Task]?
  public var roles: [RunView.Role]?
  public var spans: [RunView.Span]?
  public var gates: [RunView.Gate]?
  public var proofs: [RunView.Proof]?
  public var halts: [RunView.Halt]?
  /// The whole validation section when any of it changed: the page replaces it.
  public var validation: RunViewValidation?
  /// The whole list when it changed: the page replaces it.
  public var damage: [RunView.Damage]?
  /// The whole list when it changed, so a file written since drops out: the page replaces it.
  public var unwritten: [RunView.Damage]?

  public init(cursor: String) {
    self.cursor = cursor
  }

  /// The rows of `new` that `old` lacks or holds differently, keyed as the page merges them.
  public static func between(_ old: RunView, _ new: RunView) -> RunViewChanges {
    var changes = RunViewChanges(cursor: new.cursor ?? "")
    if old.run != new.run { changes.run = new.run }
    changes.spec = changed(old.spec, new.spec) { $0.id }
    changes.tasks = changed(old.tasks, new.tasks) { $0.id }
    changes.roles = changed(old.roles, new.roles) { $0.role.rawValue }
    changes.spans = changed(old.spans, new.spans) { $0.id }
    changes.gates = changed(old.gates, new.gates) { $0.runID }
    changes.proofs = changed(old.proofs, new.proofs) { "\($0.gateRun)\u{0}\($0.test)" }
    changes.halts = changed(old.halts, new.halts) {
      "\($0.task ?? "")\u{0}\($0.at.timeIntervalSinceReferenceDate)"
    }
    if old.validation != new.validation { changes.validation = new.validation }
    // Whole, not merged by row: a torn line that healed or a late file must leave the footer.
    if old.damage != new.damage { changes.damage = new.damage }
    if old.unwritten != new.unwritten { changes.unwritten = new.unwritten }
    return changes
  }

  /// `new`'s rows whose key `old` lacks or holds a different row under; `nil` when none. A row
  /// `old` has and `new` lacks stays out: the page merges and never removes.
  private static func changed<Row: Equatable>(
    _ old: [Row], _ new: [Row], key: (Row) -> String
  ) -> [Row]? {
    var before: [String: Row] = [:]
    for row in old { before[key(row)] = row }
    let rows = new.filter { before[key($0)] != $0 }
    return rows.isEmpty ? nil : rows
  }
}

/// The views a live server answered, by cursor, so a poll gets only what changed since its own.
public struct RunViewCursorBook: Sendable {
  /// How many answered views it keeps: 1 per open page is plenty.
  public static let capacity = 8

  public enum Answer: Sendable, Equatable {
    /// The cursor names no view kept here: stale, from another server, or malformed.
    case full(RunView)
    case changes(RunViewChanges)
  }

  /// Oldest first.
  private var answered: [(cursor: String, view: RunView)] = []

  public init() {}

  /// What a poll after `cursor` gets, with `snapshot` taken now and before `build` reads.
  /// `build` runs only when the snapshot moved past the cursor.
  public mutating func answer(
    after cursor: String?, snapshot: RunViewSnapshot, build: () throws -> RunView
  ) rethrows -> Answer {
    let now = snapshot.cursor
    if let cursor, cursor == now, answered.contains(where: { $0.cursor == now }) {
      return .changes(RunViewChanges(cursor: now))
    }
    var view = try build()
    view.cursor = now
    let held = cursor.flatMap { cursor in answered.last { $0.cursor == cursor }?.view }
    answered.removeAll { $0.cursor == now }
    answered.append((now, view))
    if answered.count > Self.capacity { answered.removeFirst(answered.count - Self.capacity) }
    guard let held else { return .full(view) }
    return .changes(RunViewChanges.between(held, view))
  }
}
