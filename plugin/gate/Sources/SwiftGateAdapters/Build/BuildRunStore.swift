import Darwin
import Foundation
import SwiftGateDomain

public enum BuildRunStoreError: Error, Sendable, Equatable {
  case commonDirectory(String)
  case invalidPlanName(String)
  case invalidRunID(String)
  /// `create` found the run directory already there; nothing was written.
  case runExists(String)
  /// `events.jsonl` doesn't end in a newline, so an append would fuse its event onto a torn line.
  case tornTail(String)
  /// The log has lines that didn't decode; a caller needing the whole history can't trust it.
  case damagedLog([BuildEventLog.Damage])
  case malformedRun(path: String, detail: String)
  case lock(FileLockError)
  case io(operation: String, path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

/// One build run's `run.json` and `events.jsonl` under the git common dir (spec §4), so every
/// linked worktree of the repository reads and appends the same run.
public struct BuildRunStore: Sendable {
  public let layout: BuildRunLayout
  private let lock: any CountingLock
  private let timeout: Duration

  public var runID: String { layout.runID }

  /// - Parameter lock: defaults to a capacity-1 ``FileCountingLock`` inside the run directory, so
  ///   one run's appenders never wait on another run's.
  public init(
    layout: BuildRunLayout, lock: (any CountingLock)? = nil, timeout: Duration = .seconds(30)
  ) {
    self.layout = layout
    self.lock =
      lock
      ?? FileCountingLock(
        directory: URL(filePath: layout.directory, directoryHint: .isDirectory),
        name: "events.lock", capacity: 1, pollInterval: .milliseconds(5))
    self.timeout = timeout
  }

  /// Creates `plans/<plan>/build/<run>/` with a fresh run id and publishes its `run.json` whole.
  /// - Parameters:
  ///   - startedAt: from the caller's clock; the adapter never reads one.
  ///   - suffix: the run id's random part, drawn by the caller as `GateRun` does for gate runs.
  public static func create(
    plan: String, presetName: String, preset: BuildPreset, startedAt: Date, git: any Git,
    suffix: UInt32
  ) async throws(BuildRunStoreError) -> BuildRunStore {
    let runID = RunID.make(startedAt: startedAt, suffix: suffix)
    let layout = try await locate(plan: plan, runID: runID, git: git)
    let buildDirectory = URL(filePath: layout.directory).deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "mkdir", path: buildDirectory.path, reason: error.localizedDescription)
    }
    guard mkdir(layout.directory, 0o755) == 0 else {
      if errno == EEXIST { throw .runExists(layout.directory) }
      throw posixError("mkdir", layout.directory)
    }
    let record = BuildRunRecord(
      runID: runID, plan: plan, startedAt: startedAt, presetName: presetName, preset: preset)
    let data: Data
    do {
      data = try BuildRunJSON.encode(record)
    } catch {
      throw .io(operation: "encode", path: layout.runFile, reason: String(describing: error))
    }
    do {
      // `.atomic` writes a sibling temporary file and renames it over `run.json`.
      try data.write(to: URL(filePath: layout.runFile), options: .atomic)
    } catch {
      throw .io(operation: "write", path: layout.runFile, reason: error.localizedDescription)
    }
    return BuildRunStore(layout: layout)
  }

  /// An existing run of `plan`, located under `git`'s common dir.
  public static func open(plan: String, runID: String, git: any Git)
    async throws(BuildRunStoreError) -> BuildRunStore
  {
    BuildRunStore(layout: try await locate(plan: plan, runID: runID, git: git))
  }

  /// The plan's newest run: run ids start with their UTC start time at a fixed width, so the
  /// greatest sorts last. Entries under `build/` that aren't directories named by a valid run id
  /// are skipped. `nil` when no run has started.
  public static func latest(plan: String, git: any Git) async throws(BuildRunStoreError)
    -> BuildRunStore?
  {
    let planLayout = try await locate(plan: plan, git: git)
    let buildDirectory = planLayout.buildDirectory
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: buildDirectory)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .io(operation: "list", path: buildDirectory, reason: error.localizedDescription)
    }
    let runs = names.compactMap { name -> BuildRunLayout? in
      guard let run = try? planLayout.buildRun(name) else { return nil }
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: run.directory, isDirectory: &isDirectory)
      return exists && isDirectory.boolValue ? run : nil
    }
    return runs.max { $0.runID < $1.runID }.map { BuildRunStore(layout: $0) }
  }

  private static func locate(plan: String, runID: String, git: any Git)
    async throws(BuildRunStoreError) -> BuildRunLayout
  {
    let planLayout = try await locate(plan: plan, git: git)
    do {
      return try planLayout.buildRun(runID)
    } catch {
      throw .invalidRunID(runID)
    }
  }

  private static func locate(plan: String, git: any Git)
    async throws(BuildRunStoreError) -> PlanStateLayout.Plan
  {
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      throw .commonDirectory("\(error)")
    }
    do {
      return try PlanStateLayout(commonDirectory: common).plan(plan)
    } catch {
      throw .invalidPlanName(plan)
    }
  }

  public func record() throws(BuildRunStoreError) -> BuildRunRecord {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: layout.runFile))
    } catch {
      throw .io(operation: "read", path: layout.runFile, reason: error.localizedDescription)
    }
    do {
      return try BuildRunJSON.decode(data)
    } catch {
      throw .malformedRun(path: layout.runFile, detail: String(describing: error))
    }
  }

  /// Appends one line to `events.jsonl`. The tail check and the write happen under the run's lock
  /// and the write lands at the size read under it, so racing appenders, in any process or
  /// worktree, each get their own offset.
  public func append(_ event: BuildEvent) async throws(BuildRunStoreError) {
    let line: Data
    do {
      line = try BuildEventJSON.encodeLine(event)
    } catch {
      throw .io(operation: "encode", path: layout.eventsFile, reason: String(describing: error))
    }
    let lease: LockLease
    do {
      lease = try await lock.acquire(timeout: timeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }
    try writeAtEnd(line)
  }

  private func writeAtEnd(_ line: Data) throws(BuildRunStoreError) {
    let path = layout.eventsFile
    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw Self.posixError("open", path) }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0 else { throw Self.posixError("fstat", path) }
    let end = status.st_size
    if end > 0 {
      var last: UInt8 = 0
      guard pread(fd, &last, 1, end - 1) == 1 else { throw Self.posixError("pread", path) }
      guard last == UInt8(ascii: "\n") else { throw .tornTail(path) }
    }
    var written = 0
    while written < line.count {
      let count = line.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return pwrite(fd, base + written, buffer.count - written, end + off_t(written))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw Self.posixError("write", path)
      }
      written += count
    }
  }

  /// Every event in file order, with each torn or undecodable line reported. A missing log is an
  /// empty one: a run has no events until its first transition.
  public func events() throws(BuildRunStoreError) -> BuildEventLog {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: layout.eventsFile))
    } catch CocoaError.fileReadNoSuchFile {
      return BuildEventLog(events: [], damage: [])
    } catch {
      throw .io(operation: "read", path: layout.eventsFile, reason: error.localizedDescription)
    }
    return BuildEventJSON.decode(data)
  }

  /// Where `main` should be: the newest merge's post commit, or `nil` before the first merge.
  /// - Throws: ``BuildRunStoreError/damagedLog(_:)`` when any line is torn or undecodable, since
  ///   the lost line could be a later merge.
  public func lastMergePostCommit() throws(BuildRunStoreError) -> String? {
    let log = try events()
    guard log.damage.isEmpty else { throw .damagedLog(log.damage) }
    return log.lastMergePostCommit
  }

  private static func posixError(_ operation: String, _ path: String) -> BuildRunStoreError {
    .io(operation: operation, path: path, reason: String(cString: strerror(errno)))
  }
}
