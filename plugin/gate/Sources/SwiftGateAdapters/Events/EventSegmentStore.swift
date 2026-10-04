import Darwin
import Foundation
import SwiftGateDomain

/// The shared streams under the state root's `events/`: each stream's active file, which rotates into
/// numbered segments that are sealed with LZFSE beside an index, plus the store's identity and the
/// guard's drop counts.
///
/// A write is 1 `O_APPEND` write under an exclusive `flock` on the active file. Rotation renames
/// the file under that lock, so a writer that opened the file before the rename sees on locking
/// that the path now names another file, and opens it again.
public struct EventSegmentStore: Sendable {
  /// The worktree root.
  public let root: URL
  public let state: StateRoot
  public let rotationBytes: @Sendable (HarnessEventStream) -> Int

  public init(
    root: URL,
    rotationBytes: @escaping @Sendable (HarnessEventStream) -> Int = { $0.rotationBytes }
  ) {
    self.root = root
    self.state = StateRootResolver.resolve(worktree: root)
    self.rotationBytes = rotationBytes
  }

  public func activePath(_ stream: HarnessEventStream) -> String {
    state.url(RunLayout.eventsFile(stream)).path
  }

  public func sealedDirectory(_ stream: HarnessEventStream) -> URL {
    state.url(EventSegmentLayout.sealedDirectory(stream), directoryHint: .isDirectory)
  }

  /// Appends `lines`, whole lines, in 1 write; then, when the active file has reached its
  /// threshold, rotates it into the next segment and seals every segment still plain.
  public func append(_ lines: Data, to stream: HarnessEventStream) throws(HarnessEventWriteError) {
    let path = activePath(stream)
    let rotated: Bool
    do throws(AppendOnlyFile.Failure) {
      try Self.makeDirectory(URL(filePath: path).deletingLastPathComponent())
      rotated = try appendLocked(lines, to: path, stream: stream)
    } catch {
      throw HarnessEventWriteError(path: path, reason: error.reason)
    }
    guard rotated else { return }
    do throws(HarnessEventWriteError) {
      try sealPending(stream)
    } catch {
      throw HarnessEventWriteError(
        path: error.path, reason: "written, but sealing failed: \(error.reason)")
    }
  }

  /// The write and, past the threshold, the rename, both under the active file's lock. Returns
  /// whether it rotated.
  private func appendLocked(_ lines: Data, to path: String, stream: HarnessEventStream)
    throws(AppendOnlyFile.Failure) -> Bool
  {
    // Each retry follows a rotation that happened while this writer waited for the lock.
    for _ in 0..<1_000 {
      let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
      guard fd >= 0 else { throw AppendOnlyFile.posixFailure("open") }
      defer { close(fd) }
      guard flock(fd, LOCK_EX) == 0 else { throw AppendOnlyFile.posixFailure("flock") }
      defer { flock(fd, LOCK_UN) }
      var opened = stat()
      var named = stat()
      guard fstat(fd, &opened) == 0 else { throw AppendOnlyFile.posixFailure("fstat") }
      guard stat(path, &named) == 0, named.st_ino == opened.st_ino, named.st_dev == opened.st_dev
      else { continue }
      try AppendOnlyFile.writeAll(lines, to: fd)
      var written = stat()
      guard fstat(fd, &written) == 0 else { throw AppendOnlyFile.posixFailure("fstat") }
      guard Int(written.st_size) >= rotationBytes(stream) else { return false }
      try rotate(path, stream: stream)
      return true
    }
    throw AppendOnlyFile.Failure(
      operation: "open", detail: "the file kept rotating away; gave up after 1000 tries")
  }

  /// Renames the active file to the next free segment number. Called under the active file's
  /// lock, so no other writer rotates at the same time.
  private func rotate(_ path: String, stream: HarnessEventStream) throws(AppendOnlyFile.Failure) {
    let directory = sealedDirectory(stream)
    try Self.makeDirectory(directory)
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw AppendOnlyFile.Failure(operation: "list", detail: error.localizedDescription)
    }
    var sequence =
      (names.compactMap { Self.sequence(EventSegmentLayout.file(named: $0)) }.max() ?? 0) + 1
    while true {
      let target = directory.appending(path: EventSegmentLayout.plainName(sequence)).path
      if renamex_np(path, target, UInt32(RENAME_EXCL)) == 0 { return }
      guard errno == EEXIST else { throw AppendOnlyFile.posixFailure("rename") }
      sequence += 1
    }
  }

  /// Compresses each plain segment, writes its index (and a `test.result` segment's rollup), and
  /// removes the plain file. Each file appears by an exclusive create, so 2 sealers of 1 segment
  /// leave 1 of each.
  public func sealPending(_ stream: HarnessEventStream) throws(HarnessEventWriteError) {
    let directory = sealedDirectory(stream)
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch CocoaError.fileReadNoSuchFile {
      return
    } catch {
      throw HarnessEventWriteError(path: directory.path, reason: error.localizedDescription)
    }
    let plain = names.compactMap { name -> Int? in
      guard case .plain(let sequence) = EventSegmentLayout.file(named: name) else { return nil }
      return sequence
    }
    for sequence in plain.sorted() { try seal(stream, sequence: sequence) }
  }

  private func seal(_ stream: HarnessEventStream, sequence: Int) throws(HarnessEventWriteError) {
    let directory = sealedDirectory(stream)
    let plain = directory.appending(path: EventSegmentLayout.plainName(sequence))
    let compressed = directory.appending(path: EventSegmentLayout.compressedName(sequence))
    let indexFile = directory.appending(path: EventSegmentLayout.indexName(sequence))
    let lines: Data
    do {
      lines = try Data(contentsOf: plain)
    } catch CocoaError.fileReadNoSuchFile {
      // Another sealer finished it.
      return
    } catch {
      throw HarnessEventWriteError(path: plain.path, reason: error.localizedDescription)
    }
    func failing(_ url: URL, _ error: any Error) -> HarnessEventWriteError {
      HarnessEventWriteError(path: url.path, reason: "\(error)")
    }
    if !FileManager.default.fileExists(atPath: compressed.path) {
      do {
        let packed = try (lines as NSData).compressed(using: .lzfse) as Data
        try Self.createExclusively(packed, at: compressed)
      } catch {
        throw failing(compressed, error)
      }
    }
    if !FileManager.default.fileExists(atPath: indexFile.path) {
      do {
        let size = try FileManager.default.attributesOfItem(atPath: compressed.path)[.size]
        let index = try EventSegmentIndex.make(
          segment: lines, compressedBytes: (size as? Int) ?? 0)
        try Self.createExclusively(try index.encoded(), at: indexFile)
      } catch {
        throw failing(indexFile, error)
      }
    }
    let rollupFile = directory.appending(path: EventSegmentLayout.rollupName(sequence))
    if stream == .test, !FileManager.default.fileExists(atPath: rollupFile.path) {
      do {
        try Self.createExclusively(try TestRollup.make(segment: lines).encoded(), at: rollupFile)
      } catch {
        throw failing(rollupFile, error)
      }
    }
    guard unlink(plain.path) == 0 || errno == ENOENT else {
      throw HarnessEventWriteError(
        path: plain.path, reason: "unlink: \(String(cString: strerror(errno)))")
    }
  }

  /// The sequence numbers of the stream's segments, ascending.
  public func segments(_ stream: HarnessEventStream) throws(HarnessEventReadError) -> [Int] {
    let directory = sealedDirectory(stream)
    do {
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      return Set(names.compactMap { Self.sequence(EventSegmentLayout.file(named: $0)) }).sorted()
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      throw HarnessEventReadError(path: directory.path, reason: error.localizedDescription)
    }
  }

  /// Segment `sequence`'s uncompressed lines: the plain file while it exists, else the
  /// decompressed one.
  public func segment(_ stream: HarnessEventStream, sequence: Int) throws(HarnessEventReadError)
    -> Data
  {
    let directory = sealedDirectory(stream)
    let plain = directory.appending(path: EventSegmentLayout.plainName(sequence))
    do {
      return try Data(contentsOf: plain)
    } catch CocoaError.fileReadNoSuchFile {
      // Sealed since it was listed, or never left plain.
    } catch {
      throw HarnessEventReadError(path: plain.path, reason: error.localizedDescription)
    }
    let compressed = directory.appending(path: EventSegmentLayout.compressedName(sequence))
    do {
      return try (Data(contentsOf: compressed) as NSData).decompressed(using: .lzfse) as Data
    } catch {
      throw HarnessEventReadError(path: compressed.path, reason: error.localizedDescription)
    }
  }

  /// Segment `sequence`'s index; `nil` until it's written.
  public func index(_ stream: HarnessEventStream, sequence: Int) throws(HarnessEventReadError)
    -> EventSegmentIndex?
  {
    let file = sealedDirectory(stream).appending(path: EventSegmentLayout.indexName(sequence))
    do {
      return try EventSegmentIndex.decode(try Data(contentsOf: file))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw HarnessEventReadError(path: file.path, reason: "\(error)")
    }
  }

  /// Every segment's lines in order, then the active file's; `nil` when the stream has none.
  public func read(_ stream: HarnessEventStream) throws(HarnessEventReadError) -> Data? {
    let sequences = try segments(stream)
    var data = Data()
    for sequence in sequences {
      data.append(try segment(stream, sequence: sequence))
      // A segment always ends a whole line; a missing newline would join 2 lines.
      if data.last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
    }
    let path = activePath(stream)
    do {
      data.append(try Data(contentsOf: URL(filePath: path)))
    } catch CocoaError.fileReadNoSuchFile {
      if sequences.isEmpty { return nil }
    } catch {
      throw HarnessEventReadError(path: path, reason: error.localizedDescription)
    }
    return data
  }

  /// The store's identity, created with a random id and salt by the first caller.
  public func identity() throws(HarnessEventWriteError) -> EventStoreIdentity {
    let file = state.url(EventSegmentLayout.storeFile)
    if let existing = try Self.readIdentity(file) { return existing }
    return try withStoreLock { () throws(HarnessEventWriteError) -> EventStoreIdentity in
      if let existing = try Self.readIdentity(file) { return existing }
      var salt = [UInt8](repeating: 0, count: EventStoreIdentity.saltBytes)
      arc4random_buf(&salt, salt.count)  // swiftgate:allow det.random — the salt must be secret
      let id = UUID()  // swiftgate:allow det.uuid-init — a store's id need only be unique
      guard let identity = EventStoreIdentity(storeID: id, salt: salt) else {
        throw HarnessEventWriteError(path: file.path, reason: "salt is not 32 bytes")
      }
      do {
        try Self.replace(file, with: try Self.encoder.encode(identity))
      } catch {
        throw HarnessEventWriteError(path: file.path, reason: "\(error)")
      }
      return identity
    }
  }

  /// Adds 1 to `dropped.json`'s count for `kind` and `reason`.
  public func countDropped(_ kind: HarnessEventKind, _ reason: EventPayloadGuard.Reason)
    throws(HarnessEventWriteError)
  {
    let file = state.url(EventSegmentLayout.droppedFile)
    try withStoreLock { () throws(HarnessEventWriteError) in
      var counts: EventDropCounts
      do throws(HarnessEventReadError) {
        counts = try dropped()
      } catch {
        throw HarnessEventWriteError(path: error.path, reason: error.reason)
      }
      counts.count(kind, reason)
      do {
        try Self.replace(file, with: try Self.encoder.encode(counts))
      } catch {
        throw HarnessEventWriteError(path: file.path, reason: "\(error)")
      }
    }
  }

  /// What `dropped.json` holds; empty when nothing was dropped.
  public func dropped() throws(HarnessEventReadError) -> EventDropCounts {
    let file = state.url(EventSegmentLayout.droppedFile)
    do {
      return try JSONDecoder().decode(EventDropCounts.self, from: try Data(contentsOf: file))
    } catch CocoaError.fileReadNoSuchFile {
      return EventDropCounts()
    } catch {
      throw HarnessEventReadError(path: file.path, reason: "\(error)")
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static func readIdentity(_ file: URL) throws(HarnessEventWriteError)
    -> EventStoreIdentity?
  {
    do {
      return try JSONDecoder().decode(EventStoreIdentity.self, from: try Data(contentsOf: file))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw HarnessEventWriteError(path: file.path, reason: "\(error)")
    }
  }

  /// Runs `body` holding the store's lock, which guards `store.json` and `dropped.json`.
  private func withStoreLock<T>(_ body: () throws(HarnessEventWriteError) -> T)
    throws(HarnessEventWriteError) -> T
  {
    let path = state.url(EventSegmentLayout.lockFile).path
    let fd: Int32
    do throws(AppendOnlyFile.Failure) {
      try Self.makeDirectory(URL(filePath: path).deletingLastPathComponent())
      fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
      guard fd >= 0 else { throw AppendOnlyFile.posixFailure("open") }
    } catch {
      throw HarnessEventWriteError(path: path, reason: error.reason)
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else {
      throw HarnessEventWriteError(path: path, reason: AppendOnlyFile.posixFailure("flock").reason)
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  private static func sequence(_ file: EventSegmentLayout.File?) -> Int? {
    switch file {
    case .plain(let sequence), .compressed(let sequence), .index(let sequence): sequence
    case nil: nil
    }
  }

  private static func makeDirectory(_ url: URL) throws(AppendOnlyFile.Failure) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw AppendOnlyFile.Failure(operation: "mkdir", detail: error.localizedDescription)
    }
  }

  /// A temporary file in `url`'s directory, named so no segment parser reads it.
  private static func temporary(beside url: URL) -> URL {
    let unique = UUID().uuidString  // swiftgate:allow det.uuid-init — a temporary name
    return url.deletingLastPathComponent().appending(
      path: ".\(url.lastPathComponent).\(unique).tmp")
  }

  /// Writes `data` to `url` whole, unless `url` already exists: the first of 2 racing creators
  /// wins and the other's copy is discarded.
  private static func createExclusively(_ data: Data, at url: URL) throws {
    let temporary = temporary(beside: url)
    try data.write(to: temporary, options: .withoutOverwriting)
    defer { unlink(temporary.path) }
    guard link(temporary.path, url.path) == 0 || errno == EEXIST else {
      throw AppendOnlyFile.posixFailure("link")
    }
  }

  /// Replaces `url` with `data` in 1 rename, so a reader sees the old file or the new one.
  private static func replace(_ url: URL, with data: Data) throws {
    let temporary = temporary(beside: url)
    try data.write(to: temporary, options: .withoutOverwriting)
    guard rename(temporary.path, url.path) == 0 else {
      let failure = AppendOnlyFile.posixFailure("rename")
      unlink(temporary.path)
      throw failure
    }
  }
}
