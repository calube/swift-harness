import Foundation
import SwiftGateDomain

/// One plan's `orchestrator.lock`: the file holds the claiming session's id and a newline, and the
/// edit guard compares its trimmed contents with the writing session's id. `swiftgate plan claim`
/// and `plan release` are its only writers.
public struct PlanLock: Sendable {
  public enum ClaimOutcome: Sendable, Equatable {
    case claimed
    case alreadyHeld
    case heldByOther(holder: String)
  }

  public enum ReleaseOutcome: Sendable, Equatable {
    case released
    case notClaimed
    case heldByOther(holder: String)
  }

  public enum ForcedReleaseOutcome: Sendable, Equatable {
    case overrode(holder: String)
    case notClaimed
  }

  public let plan: PlanStateLayout.Plan

  public init(plan: PlanStateLayout.Plan) {
    self.plan = plan
  }

  /// A session id the guard's trimmed comparison can match: non-empty, no whitespace, no NUL.
  public static func isValidSession(_ session: String) -> Bool {
    !session.isEmpty && !session.contains { $0.isWhitespace || $0 == "\0" }
  }

  public static func fileContents(session: String) -> String { session + "\n" }

  /// The holder's session id, or `nil` when the plan is unclaimed.
  public func holder() throws(PlanLockError) -> String? {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: plan.orchestratorLock))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    } catch {
      throw .io("reading \(plan.orchestratorLock): \(error.localizedDescription)")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The lock appears complete or not at all: the id is written to a private file, which is then
  /// hard-linked into place. `link(2)` fails with `EEXIST` when a lock exists, so of any number of
  /// racing claimers exactly one wins, and no reader ever sees an empty lock.
  public func claim(session: String) throws(PlanLockError) -> ClaimOutcome {
    guard Self.isValidSession(session) else { throw .invalidSession(session) }
    if let holder = try holder() {
      return holder == session ? .alreadyHeld : .heldByOther(holder: holder)
    }
    do {
      try FileManager.default.createDirectory(
        atPath: plan.directory, withIntermediateDirectories: true)
    } catch {
      throw .io("creating \(plan.directory): \(error.localizedDescription)")
    }
    let staging = try stage(Self.fileContents(session: session))
    defer { unlink(staging) }
    if link(staging, plan.orchestratorLock) == 0 { return .claimed }
    let code = errno
    guard code == EEXIST else {
      throw .io("linking \(plan.orchestratorLock): \(String(cString: strerror(code)))")
    }
    let holder = try holder() ?? ""
    return holder == session ? .alreadyHeld : .heldByOther(holder: holder)
  }

  /// Only the holder releases. The read and the removal aren't one step, but the lock only changes
  /// hands by being removed, which a non-holder can't do without `--force`.
  public func release(session: String) throws(PlanLockError) -> ReleaseOutcome {
    guard Self.isValidSession(session) else { throw .invalidSession(session) }
    guard let holder = try holder() else { return .notClaimed }
    guard holder == session else { return .heldByOther(holder: holder) }
    try remove()
    return .released
  }

  /// The user's takeover of an abandoned lock: removes it whoever holds it.
  public func forceRelease() throws(PlanLockError) -> ForcedReleaseOutcome {
    guard let holder = try holder() else { return .notClaimed }
    try remove()
    return .overrode(holder: holder)
  }

  /// A uniquely named private file in the plan directory holding `contents`; `mkstemp` picks the
  /// name so racing claimers never share one.
  private func stage(_ contents: String) throws(PlanLockError) -> String {
    var template = Array((plan.directory + "/.orchestrator.lock.XXXXXX").utf8CString)
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
      buffer.baseAddress.map { mkstemp($0) } ?? -1
    }
    guard descriptor >= 0 else {
      throw .io("staging in \(plan.directory): \(String(cString: strerror(errno)))")
    }
    let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: Data(contents.utf8))
      try handle.close()
    } catch {
      unlink(path)
      throw .io("writing \(path): \(error.localizedDescription)")
    }
    return path
  }

  private func remove() throws(PlanLockError) {
    guard unlink(plan.orchestratorLock) == 0 || errno == ENOENT else {
      throw .io("removing \(plan.orchestratorLock): \(String(cString: strerror(errno)))")
    }
  }
}

public enum PlanLockError: Error, Sendable, Equatable {
  case invalidSession(String)
  case io(String)
}
