import Darwin
import Foundation
import SwiftGateDomain

/// Reads ``RunLayout`` paths under the state root of the worktree at `root`. An error names the
/// path as ``StateRoot/displayPath(_:)`` does.
public struct LiveEventStoreFiles: EventStoreFileReading {
  public let root: URL
  public let state: StateRoot

  public init(root: URL) {
    self.root = root
    self.state = StateRootResolver.resolve(worktree: root)
  }

  public func displayPath(_ path: String) -> String { state.displayPath(path) }

  public func read(_ path: String) throws(EventStoreFileError) -> Data? {
    do {
      return try Data(contentsOf: state.url(path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw EventStoreFileError(path: state.displayPath(path), reason: error.localizedDescription)
    }
  }

  public func list(_ directory: String) throws(EventStoreFileError) -> [String] {
    do {
      return try FileManager.default.contentsOfDirectory(
        atPath: state.url(directory).path
      ).sorted()
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      throw EventStoreFileError(
        path: state.displayPath(directory), reason: error.localizedDescription)
    }
  }

  public func size(_ path: String) throws(EventStoreFileError) -> Int? {
    var info = stat()
    guard stat(state.url(path).path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw EventStoreFileError(
        path: state.displayPath(path), reason: String(cString: strerror(errno)))
    }
    return Int(info.st_size)
  }
}

/// What every store under a worktree held for a query.
public struct EventStoreRead: Sendable, Equatable {
  /// Deduplicated by `eventID`, oldest first.
  public let events: [StoredEvent]
  public let damage: [EventDamage]
  public let facts: EventStoreFacts

  public init(events: [StoredEvent], damage: [EventDamage], facts: EventStoreFacts) {
    self.events = events
    self.damage = damage
    self.facts = facts
  }
}

/// Reads the state root's `events/` and every `imported/<storeID>/` and `unkept/<storeID>/` below it: each stream's sealed
/// segments, then its active file. A segment whose index rules it out of the query is never
/// opened. Takes no lock: writers only append and rename.
public struct EventStoreReader: Sendable {
  public let files: any EventStoreFileReading

  public init(files: any EventStoreFileReading) {
    self.files = files
  }

  /// How the reader treats a sealed `test.result` segment.
  public enum SealedTests: Sendable, Equatable {
    /// Decode its lines, like any other segment's.
    case lines
    /// When its rollup and index are there, count it from its index without opening it, for a
    /// reader whose only per-result consumer reads rollups.
    case indexesWhereRolledUp
  }

  public func read(_ query: EventQuery, sealedTests: SealedTests = .lines) -> EventStoreRead {
    var damage: [EventDamage] = []
    func unreadable(_ error: EventStoreFileError) {
      damage.append(
        EventDamage(file: error.path, line: nil, kind: .unreadableFile, detail: error.reason))
    }
    var stores = [RunLayout.eventsDirectory]
    for parent in ["imported", "unkept"].map({ "\(RunLayout.eventsDirectory)/\($0)" }) {
      do throws(EventStoreFileError) {
        stores += try files.list(parent).filter { !$0.hasPrefix(".") }.map { "\(parent)/\($0)" }
      } catch {
        unreadable(error)
      }
    }
    var batches: [[StoredEvent]] = []
    var streams: [HarnessEventStream: EventStoreFacts.Stream] = [:]
    var dropped: [HarnessEventKind: [EventPayloadGuard.Reason: Int]] = [:]
    var rolledUp: EventStoreFacts.RolledUpTests?
    for store in stores {
      do throws(EventStoreFileError) {
        for (kind, reasons) in try droppedCounts(store).dropped {
          dropped[kind, default: [:]].merge(reasons, uniquingKeysWith: +)
        }
      } catch {
        unreadable(error)
      }
      for stream in HarnessEventStream.allCases {
        let read = read(stream, in: store, query: query, sealedTests: sealedTests)
        damage += read.damage
        if let counted = read.rolledUp {
          rolledUp = EventStoreFacts.RolledUpTests(
            segments: (rolledUp?.segments ?? 0) + counted.segments,
            lines: (rolledUp?.lines ?? 0) + counted.lines,
            bytes: (rolledUp?.bytes ?? 0) + counted.bytes)
        }
        batches.append(read.events.filter { query.keeps($0.event) })
        let total = streams[stream]
        streams[stream] = EventStoreFacts.Stream(
          stream: stream, activeBytes: (total?.activeBytes ?? 0) + read.facts.activeBytes,
          sealedSegments: (total?.sealedSegments ?? 0) + read.facts.sealedSegments,
          sealedBytes: (total?.sealedBytes ?? 0) + read.facts.sealedBytes)
      }
    }
    return EventStoreRead(
      events: EventQuery.merge(batches), damage: damage,
      facts: EventStoreFacts(
        streams: HarnessEventStream.allCases.compactMap { streams[$0] },
        dropped: EventDropCounts(dropped: dropped), stores: stores.count, rolledUpTests: rolledUp))
  }

  private struct StreamRead {
    var events: [StoredEvent] = []
    var damage: [EventDamage] = []
    var facts: EventStoreFacts.Stream
    var rolledUp: EventStoreFacts.RolledUpTests?
  }

  /// 1 store's `stream`: its size whatever the query, and the events of every segment the query
  /// may match, then of the active file.
  private func read(
    _ stream: HarnessEventStream, in store: String, query: EventQuery, sealedTests: SealedTests
  ) -> StreamRead {
    let active = "\(store)/\(stream.fileName)"
    let sealed = "\(store)/sealed/\(stream.rawValue)"
    var result = StreamRead(
      facts: EventStoreFacts.Stream(
        stream: stream, activeBytes: 0, sealedSegments: 0, sealedBytes: 0))
    func unreadable(_ error: EventStoreFileError, _ kind: EventDamage.Kind = .unreadableFile) {
      result.damage.append(
        EventDamage(file: error.path, line: nil, kind: kind, detail: error.reason))
    }
    let wanted = query.streams.contains(stream)
    var segments: [Int: Set<String>] = [:]
    var rollups = Set<String>()
    do throws(EventStoreFileError) {
      for name in try files.list(sealed) {
        if name.hasSuffix(".rollup.json") { rollups.insert(name) }
        guard let file = EventSegmentLayout.file(named: name) else { continue }
        switch file {
        case .plain(let sequence), .compressed(let sequence), .index(let sequence):
          segments[sequence, default: []].insert(name)
        }
      }
    } catch {
      unreadable(error)
    }
    var sealedBytes = 0
    for (sequence, names) in segments.sorted(by: { $0.key < $1.key }) {
      let plain = "\(sealed)/\(EventSegmentLayout.plainName(sequence))"
      let compressed = "\(sealed)/\(EventSegmentLayout.compressedName(sequence))"
      do throws(EventStoreFileError) {
        let onDisk =
          names.contains(EventSegmentLayout.compressedName(sequence)) ? compressed : plain
        sealedBytes += try files.size(onDisk) ?? 0
      } catch {
        unreadable(error)
      }
      guard wanted else { continue }
      var index: EventSegmentIndex?
      if names.contains(EventSegmentLayout.indexName(sequence)) {
        let indexPath = "\(sealed)/\(EventSegmentLayout.indexName(sequence))"
        do throws(EventStoreFileError) {
          if let data = try files.read(indexPath) {
            do {
              index = try EventSegmentIndex.decode(data)
            } catch {
              throw EventStoreFileError(path: files.displayPath(indexPath), reason: "\(error)")
            }
          }
          if let index, !query.mayMatch(index) { continue }
        } catch {
          // Without its index the segment is read whole, so nothing it holds is lost.
          unreadable(error, .unreadableIndex)
        }
      }
      // The flaky and slow-test section reads the rollup; the store needs only the index's counts.
      if sealedTests == .indexesWhereRolledUp, stream == .test, let index,
        rollups.contains(EventSegmentLayout.rollupName(sequence))
      {
        result.rolledUp = EventStoreFacts.RolledUpTests(
          segments: (result.rolledUp?.segments ?? 0) + 1,
          lines: (result.rolledUp?.lines ?? 0) + index.lines,
          bytes: (result.rolledUp?.bytes ?? 0) + index.bytes)
        continue
      }
      do throws(EventStoreFileError) {
        guard
          let (path, data) = try segment(
            plain: names.contains(EventSegmentLayout.plainName(sequence)) ? plain : nil,
            compressed: compressed)
        else {
          continue
        }
        let lines = EventLines.decode(data, file: files.displayPath(path))
        result.events += lines.events
        result.damage += lines.damage
      } catch {
        unreadable(error)
      }
    }
    var activeBytes = 0
    do throws(EventStoreFileError) {
      activeBytes = try files.size(active) ?? 0
      if wanted, let data = try files.read(active) {
        let lines = EventLines.decode(data, file: files.displayPath(active))
        result.events += lines.events
        result.damage += lines.damage
      }
    } catch {
      unreadable(error)
    }
    result.facts = EventStoreFacts.Stream(
      stream: stream, activeBytes: activeBytes, sealedSegments: segments.count,
      sealedBytes: sealedBytes)
    return result
  }

  /// A segment's lines and the file they came from: the plain file while it's there, since a
  /// sealer may have been stopped before removing it, else the decompressed one.
  private func segment(plain: String?, compressed: String) throws(EventStoreFileError)
    -> (String, Data)?
  {
    // A listed plain file can be sealed and removed before it's read.
    if let plain, let data = try files.read(plain) { return (plain, data) }
    guard let packed = try files.read(compressed) else { return nil }
    do {
      return (compressed, try (packed as NSData).decompressed(using: .lzfse) as Data)
    } catch {
      throw EventStoreFileError(
        path: files.displayPath(compressed), reason: "decompress: \(error)")
    }
  }

  private func droppedCounts(_ store: String) throws(EventStoreFileError) -> EventDropCounts {
    let path = "\(store)/dropped.json"
    guard let data = try files.read(path) else { return EventDropCounts() }
    do {
      return try JSONDecoder().decode(EventDropCounts.self, from: data)
    } catch {
      throw EventStoreFileError(path: files.displayPath(path), reason: "\(error)")
    }
  }
}
