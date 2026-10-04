import Foundation
import SwiftGateDomain

/// The merge base a gate compares against.
public struct BaselineBase: Sendable, Equatable {
  public let commit: String
  /// `git rev-parse <commit>^{tree}`: the baseline file's name.
  public let tree: String

  public init(commit: String, tree: String) {
    self.commit = commit
    self.tree = tree
  }
}

/// 1 step a gate ran at the head, and how to run it again in a tree at the merge base.
public struct BaselineQuery: Sendable {
  public let key: BaselineStepKey
  public let head: AreaCommandOutcome
  /// The same step's request with its paths under `scratchToplevel` instead of the worktree.
  public let request: @Sendable (_ scratchToplevel: URL) -> AreaCommandRequest

  public init(
    key: BaselineStepKey, head: AreaCommandOutcome,
    request: @escaping @Sendable (_ scratchToplevel: URL) -> AreaCommandRequest
  ) {
    self.key = key
    self.head = head
    self.request = request
  }
}

public struct BaselineLookup: Sendable, Equatable {
  public let verdict: BaselineVerdict
  /// Non-gating `baseline.summary` findings: what was absorbed, a file that didn't decode, a
  /// rerun that couldn't run, an answer that couldn't be recorded.
  public let notes: [Finding]
  /// The steps rerun at the merge base because no answer was recorded.
  public let reran: [BaselineStepKey]

  public init(verdict: BaselineVerdict, notes: [Finding], reran: [BaselineStepKey]) {
    self.verdict = verdict
    self.notes = notes
    self.reran = reran
  }
}

/// A baseline file's records as read: an unreadable file reads as none and says so in `notes`.
public struct BaselineLoad: Sendable, Equatable {
  public let records: [BaselineRecord]
  public let notes: [Finding]

  public init(records: [BaselineRecord], notes: [Finding]) {
    self.records = records
    self.notes = notes
  }

  public var results: [BaselineStepKey: BaselineStepResult] {
    Dictionary(records.map { ($0.key, $0.result) }, uniquingKeysWith: { _, last in last })
  }
}

public enum BaselineStoreError: Error, Sendable, Equatable {
  case lock(FileLockError)
  case io(operation: String, path: String, reason: String)
}

/// The clone's known failures per base tree, under `<common>/swift-harness/baseline/`.
public struct BaselineStore: Sendable {
  public static let lockName = "baseline.lock"

  public let layout: BrownfieldStateLayout
  private let runner: any AreaCommandRunning
  private let scratch: any ScratchWorktrees
  private let injectedLock: (any CountingLock)?
  private let lockTimeout: Duration

  /// - Parameters:
  ///   - scratch: makes the merge-base trees reruns run in.
  ///   - lock: defaults to a capacity-1 ``FileCountingLock`` in the baseline directory.
  public init(
    layout: BrownfieldStateLayout, runner: any AreaCommandRunning, scratch: any ScratchWorktrees,
    lock: (any CountingLock)? = nil, lockTimeout: Duration = .seconds(30)
  ) {
    self.layout = layout
    self.runner = runner
    self.scratch = scratch
    self.injectedLock = lock
    self.lockTimeout = lockTimeout
  }

  /// Compares the queries' head failures with the base tree's answers, rerunning at
  /// `base.commit` each failing step that has none and recording what the rerun gives.
  /// A step with no answer, because its rerun couldn't run, stays gating.
  public func lookupOrRerun(_ queries: [BaselineQuery], base: BaselineBase) async
    -> BaselineLookup
  {
    var head: [BaselineStepKey: BaselineStepResult] = [:]
    var failing: [BaselineQuery] = []
    for query in queries {
      let result = BaselineStepResult.of(query.head)
      guard result != .passed else { continue }
      head[query.key] = result
      failing.append(query)
    }
    guard !failing.isEmpty else {
      return BaselineLookup(
        verdict: BaselineVerdict(), notes: [], reran: [])
    }

    let loaded = load(tree: base.tree)
    var notes = loaded.notes
    var known = loaded.results
    var seen = Set<BaselineStepKey>()
    let missing = failing.filter { known[$0.key] == nil && seen.insert($0.key).inserted }
    var fresh: [BaselineRecord] = []
    if !missing.isEmpty {
      let tree = ScratchTreeRequest(
        revision: base.commit, revertTo: base.commit, copiedPaths: [], revertedPaths: [])
      do {
        fresh = try await scratch.withScratchTree(tree) { root in
          var records: [BaselineRecord] = []
          for query in missing {
            let outcome = await runner.run(query.request(root))
            records.append(BaselineRecord(key: query.key, result: BaselineStepResult.of(outcome)))
          }
          return records
        }
      } catch {
        notes += note(
          tree: base.tree,
          "couldn't make a tree at the merge base \(base.commit) to rerun "
            + "\(missing.map(\.key.area).joined(separator: ", ")), so their failures gate: \(error)"
        )
      }
    }
    if !fresh.isEmpty {
      for record in fresh { known[record.key] = record.result }
      do {
        // A file that didn't decode was already named when it was loaded.
        let recorded = try await record(fresh, tree: base.tree)
        notes += recorded.filter { !notes.contains($0) }
      } catch {
        notes += note(
          tree: base.tree,
          "couldn't record the merge base's answers, so the next gate reruns: \(error)")
      }
    }

    let verdict = Baseline.compare(head: head, base: known)
    let file = layout.baseline(tree: base.tree).path
    if let summary = verdict.summary(file: file) {
      notes.append(summary)
    }
    notes += verdict.notInstalledFindings(file: file)
    return BaselineLookup(verdict: verdict, notes: notes, reran: fresh.map(\.key))
  }

  /// Adds answers to `tree`'s file under the lock, by atomic rename. Returns a note when the
  /// file it replaced didn't decode.
  @discardableResult
  public func record(_ records: [BaselineRecord], tree: String)
    async throws(BaselineStoreError) -> [Finding]
  {
    let directory = layout.baselineDirectory
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw .io(operation: "create", path: directory.path, reason: "\(error)")
    }
    let lease: LockLease
    do {
      let lock =
        injectedLock
        ?? FileCountingLock(directory: directory, name: Self.lockName, capacity: 1)
      lease = try await lock.acquire(timeout: lockTimeout)
    } catch {
      throw .lock(error)
    }
    defer { lease.release() }
    let current = load(tree: tree)
    let path = layout.baseline(tree: tree)
    do {
      // `.atomic` writes a sibling temporary file and renames it over the old one.
      var file = BaselineFile(tree: tree, records: current.records)
      file.merge(records)
      try file.encoded().write(to: path, options: .atomic)
    } catch {
      throw .io(operation: "write", path: path.path, reason: "\(error)")
    }
    return current.notes
  }

  /// A missing file is an empty baseline: nothing was recorded at that tree yet.
  public func load(tree: String) -> BaselineLoad {
    let path = layout.baseline(tree: tree)
    let data: Data
    do {
      data = try Data(contentsOf: path)
    } catch CocoaError.fileReadNoSuchFile {
      return BaselineLoad(records: [], notes: [])
    } catch {
      return BaselineLoad(
        records: [],
        notes: note(tree: tree, "couldn't read the baseline, so its failures are rerun: \(error)"))
    }
    do {
      return BaselineLoad(records: try BaselineFile.decode(data, tree: tree).records, notes: [])
    } catch {
      return BaselineLoad(
        records: [],
        notes: note(
          tree: tree,
          "the baseline doesn't decode (\(error.detail)), so its failures are rerun and it is replaced"
        ))
    }
  }

  private func note(tree: String, _ message: String) -> [Finding] {
    let finding = try? Finding(
      ruleID: BrownfieldRuleID.baselineSummary.rawValue, severity: .nit,
      file: layout.baseline(tree: tree).path, line: nil, message: message, failureScenario: nil)
    return finding.map { [$0] } ?? []
  }
}
