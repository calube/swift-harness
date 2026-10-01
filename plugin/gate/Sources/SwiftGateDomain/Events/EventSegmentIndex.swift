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
    "\(RunLayout.eventsDirectory)/sealed/\(stream.rawValue)"
  }

  public static func plainName(_ sequence: Int) -> String { "\(sequence).jsonl" }
  public static func compressedName(_ sequence: Int) -> String { "\(sequence).jsonl.lzfse" }
  public static func indexName(_ sequence: Int) -> String { "\(sequence).index.json" }

  /// What a file in a sealed directory is, or `nil` for any other name.
  public enum File: Sendable, Equatable {
    case plain(Int)
    case compressed(Int)
    case index(Int)
  }

  public static func file(named name: String) -> File? {
    for (suffix, make) in [
      (".jsonl", File.plain), (".jsonl.lzfse", File.compressed), (".index.json", File.index),
    ] where name.hasSuffix(suffix) {
      let digits = name.dropLast(suffix.count)
      guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
        let sequence = Int(digits)
      else { return nil }
      return make(sequence)
    }
    return nil
  }
}

extension HarnessEventStream {
  /// The active file's size at which the write that reached it rotates it into a segment.
  public var rotationBytes: Int {
    switch self {
    case .judge, .gate: EventSegmentLayout.standardRotationBytes
    case .hook: EventSegmentLayout.standardRotationBytes
    case .cache: EventSegmentLayout.standardRotationBytes
    }
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
    self.schemaVersion = Self.schemaVersion
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
    let read = try HarnessEventJSON.decode(segment)
    if read.tornLastLine {
      let lines = segment.split(separator: UInt8(ascii: "\n")).count
      throw HarnessEventDecodeError(line: lines, reason: .invalid("torn last line"))
    }
    guard let first = read.events.first, let last = read.events.last else {
      throw HarnessEventDecodeError(line: 1, reason: .invalid("empty segment"))
    }
    let times = read.events.map(\.time)
    return EventSegmentIndex(
      firstTime: times.min() ?? first.time, lastTime: times.max() ?? last.time,
      lines: read.events.count, bytes: segment.count, compressedBytes: compressedBytes,
      sha256: SHA256.hash(data: segment).map { String(format: "%02x", $0) }.joined(),
      runIDs: Set(read.events.compactMap(\.runID)).sorted())
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(HarnessEventJSON.timeFormat))
    }
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data) throws -> EventSegmentIndex {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = try? Date(text, strategy: HarnessEventJSON.timeFormat) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "`\(text)` isn't an ISO 8601 time")
      }
      return date
    }
    let index = try decoder.decode(EventSegmentIndex.self, from: data)
    guard index.schemaVersion == schemaVersion else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: [], debugDescription: "unsupported schemaVersion \(index.schemaVersion)"))
    }
    return index
  }
}
