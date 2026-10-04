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

  /// The opaque cursor a live page polls after.
  public var cursor: String { "" }
}

/// The part of a ``RunView`` that changed after a cursor: each array holds only its new or
/// changed rows, and an absent key means nothing changed there. The page merges it by id.
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
  public var damage: [RunView.Damage]?

  public init(cursor: String) {
    self.cursor = cursor
  }

  /// The rows of `new` that `old` lacks or holds differently, keyed as the page merges them.
  public static func between(_ old: RunView, _ new: RunView) -> RunViewChanges {
    RunViewChanges(cursor: new.cursor ?? "")
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

  public init() {}

  /// What a poll after `cursor` gets, with `snapshot` taken now and before `build` reads.
  /// `build` runs only when the snapshot moved past the cursor.
  public mutating func answer(
    after cursor: String?, snapshot: RunViewSnapshot, build: () throws -> RunView
  ) rethrows -> Answer {
    .changes(RunViewChanges(cursor: snapshot.cursor))
  }
}
