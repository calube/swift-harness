import Darwin
import Foundation
import SwiftGateDomain

/// The shared streams under `.harness/events/`: each stream's active file, which rotates into
/// numbered segments that are sealed with LZFSE beside an index, plus the store's identity and the
/// guard's drop counts.
///
/// A write is 1 `O_APPEND` write under an exclusive `flock` on the active file. Rotation renames
/// the file under that lock, so a writer that opened the file before the rename sees on locking
/// that the path now names another file, and opens it again.
public struct EventSegmentStore: Sendable {
  /// The worktree root.
  public let root: URL
  public let rotationBytes: @Sendable (HarnessEventStream) -> Int

  public init(
    root: URL,
    rotationBytes: @escaping @Sendable (HarnessEventStream) -> Int = { $0.rotationBytes }
  ) {
    self.root = root
    self.rotationBytes = rotationBytes
  }

  public func activePath(_ stream: HarnessEventStream) -> String {
    ""
  }

  public func sealedDirectory(_ stream: HarnessEventStream) -> URL {
    root
  }

  /// Appends `lines`, whole lines, in 1 write; then, when the active file has reached its
  /// threshold, rotates it into the next segment and seals every segment still plain.
  public func append(_ lines: Data, to stream: HarnessEventStream) throws(HarnessEventWriteError) {
  }

  /// Compresses each plain segment, writes its index, and removes the plain file. Each file
  /// appears by an exclusive create, so 2 sealers of 1 segment leave 1 of each.
  public func sealPending(_ stream: HarnessEventStream) throws(HarnessEventWriteError) {
  }

  /// The sequence numbers of the stream's segments, ascending.
  public func segments(_ stream: HarnessEventStream) throws(HarnessEventReadError) -> [Int] {
    []
  }

  /// Segment `sequence`'s uncompressed lines: the plain file while it exists, else the
  /// decompressed one.
  public func segment(_ stream: HarnessEventStream, sequence: Int) throws(HarnessEventReadError)
    -> Data
  {
    Data()
  }

  /// Segment `sequence`'s index; `nil` until it's written.
  public func index(_ stream: HarnessEventStream, sequence: Int) throws(HarnessEventReadError)
    -> EventSegmentIndex?
  {
    nil
  }

  /// Every segment's lines in order, then the active file's; `nil` when the stream has none.
  public func read(_ stream: HarnessEventStream) throws(HarnessEventReadError) -> Data? {
    nil
  }

  /// The store's identity, created with a random id and salt by the first caller.
  public func identity() throws(HarnessEventWriteError) -> EventStoreIdentity {
    throw HarnessEventWriteError(path: "", reason: "")
  }

  /// Adds 1 to `dropped.json`'s count for `kind` and `reason`.
  public func countDropped(_ kind: HarnessEventKind, _ reason: EventPayloadGuard.Reason)
    throws(HarnessEventWriteError)
  {
  }

  /// What `dropped.json` holds; empty when nothing was dropped.
  public func dropped() throws(HarnessEventReadError) -> EventDropCounts {
    EventDropCounts()
  }
}
