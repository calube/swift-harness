import CryptoKit
import Foundation

/// Where a stream's sealed segments live, relative to the worktree root, and what each file of a
/// segment is called. Segment `seq` of a stream is `<seq>.jsonl` while it waits to be sealed, then
/// `<seq>.jsonl.lzfse` beside `<seq>.index.json`.
public enum EventSegmentLayout {
  public static let storeFile = "\(RunLayout.eventsDirectory)/store.json"
  public static let droppedFile = "\(RunLayout.eventsDirectory)/dropped.json"
  /// Serializes creating ``storeFile`` and counting into ``droppedFile``.
  public static let lockFile = "\(RunLayout.eventsDirectory)/store.lock"

  /// The threshold for a stream of every test result.
  public static let largeRotationBytes = 16 << 20
  public static let standardRotationBytes = 4 << 20

  public static func sealedDirectory(_ stream: HarnessEventStream) -> String {
    ""
  }

  public static func plainName(_ sequence: Int) -> String { "" }
  public static func compressedName(_ sequence: Int) -> String { "" }
  public static func indexName(_ sequence: Int) -> String { "" }

  /// What a file in a sealed directory is, or `nil` for any other name.
  public enum File: Sendable, Equatable {
    case plain(Int)
    case compressed(Int)
    case index(Int)
  }

  public static func file(named name: String) -> File? {
    nil
  }
}

extension HarnessEventStream {
  /// The active file's size at which the write that reached it rotates it into a segment.
  public var rotationBytes: Int {
    0
  }
}

/// `<seq>.index.json`: what 1 sealed segment holds, so a reader can choose segments without
/// decompressing them.
public struct EventSegmentIndex: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let firstTime: Date
  public let lastTime: Date
  public let lines: Int
  /// The uncompressed lines' size.
  public let bytes: Int
  public let compressedBytes: Int
  /// SHA-256 of the uncompressed lines, lowercase hex.
  public let sha256: String
  /// Every run id an event in the segment names, sorted, each once.
  public let runIDs: [String]

  public init(
    firstTime: Date, lastTime: Date, lines: Int, bytes: Int, compressedBytes: Int,
    sha256: String, runIDs: [String]
  ) {
    self.schemaVersion = 0
    self.firstTime = firstTime
    self.lastTime = lastTime
    self.lines = lines
    self.bytes = bytes
    self.compressedBytes = compressedBytes
    self.sha256 = sha256
    self.runIDs = runIDs
  }

  /// The index of `segment`, a sealed segment's uncompressed lines. Fails on a line that doesn't
  /// read, a torn last line, or an empty segment.
  public static func make(segment: Data, compressedBytes: Int) throws(HarnessEventDecodeError)
    -> EventSegmentIndex
  {
    EventSegmentIndex(
      firstTime: .init(), lastTime: .init(), lines: 0, bytes: 0, compressedBytes: 0, sha256: "",
      runIDs: [])
  }

  public func encoded() throws -> Data {
    Data()
  }

  public static func decode(_ data: Data) throws -> EventSegmentIndex {
    EventSegmentIndex(
      firstTime: .init(), lastTime: .init(), lines: 0, bytes: 0, compressedBytes: 0, sha256: "",
      runIDs: [])
  }
}
