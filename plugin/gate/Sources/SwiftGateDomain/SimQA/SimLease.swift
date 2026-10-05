import Foundation

/// The machine-wide record that one worktree holds one simulator for one `sim up` run. It is
/// written by the `sim hold` process that owns the device, and removing it is how `sim down` asks
/// that process to give the device back.
///
/// Encoded as one JSON object with exactly the keys `runID`, `worktree`, `udid`, `holderPID` and,
/// once `sim up` has opened the app, `session`. Any other key, or an empty value, fails decoding:
/// several processes read and rewrite this file, so a value nobody understands must stop them.
public struct SimLease: Sendable, Equatable {
  public var runID: String
  /// The canonical root of the worktree that started the run.
  public var worktree: String
  public var udid: String
  public var holderPID: Int32
  /// The `agent-device` session; `nil` until `sim up` records it.
  public var session: String?

  public init(runID: String, worktree: String, udid: String, holderPID: Int32, session: String?) {
    self.runID = runID
    self.worktree = worktree
    self.udid = udid
    self.holderPID = holderPID
    self.session = session
  }

  /// Whether a caller in `callerWorktree` (a canonical root) may act on `lease`. A lease covers
  /// the worktree that took it and no other, so `sim snap`, `verify` and `down` from a sibling
  /// worktree are refused.
  public static func owner(of lease: SimLease, callerWorktree: String) -> SimLeaseOwnership {
    trimmed(callerWorktree) == trimmed(lease.worktree)
      ? .owner : .otherWorktree(leaseWorktree: lease.worktree)
  }

  private static func trimmed(_ path: String) -> Substring {
    var path = Substring(path)
    while path.count > 1 && path.hasSuffix("/") { path = path.dropLast() }
    return path
  }

  /// A run id names a file, so it is letters, digits, `-`, `_` and `.`, and does not start with `.`.
  public static func isValidRunID(_ runID: String) -> Bool {
    guard let first = runID.unicodeScalars.first, first != "." else { return false }
    return runID.unicodeScalars.allSatisfy { scalar in
      ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        || ("0"..."9").contains(scalar) || "-_.".unicodeScalars.contains(scalar)
    }
  }

  static let keys: Set<String> = ["runID", "worktree", "udid", "holderPID", "session"]

  public static func decode(_ data: Data) throws(SimLeaseDecodingError) -> SimLease {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw .malformed("not JSON")
    }
    guard let object = parsed as? [String: Any] else { throw .malformed("not a JSON object") }
    if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
      throw .unknownKey(unknown)
    }
    func text(_ key: String) throws(SimLeaseDecodingError) -> String? {
      guard let value = object[key] else { return nil }
      guard let string = value as? String else { throw .malformed("\"\(key)\" is not a string") }
      guard !string.isEmpty else { throw .invalidValue(key: key, value: string) }
      return string
    }
    func required(_ key: String) throws(SimLeaseDecodingError) -> String {
      guard let value = try text(key) else { throw .missingKey(key) }
      return value
    }
    let runID = try required("runID")
    let worktree = try required("worktree")
    let udid = try required("udid")
    guard let pidValue = object["holderPID"] else { throw .missingKey("holderPID") }
    guard let number = pidValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let pid = Int32(exactly: number.doubleValue)
    else { throw .malformed("\"holderPID\" is not an integer") }
    guard pid > 0 else { throw .invalidValue(key: "holderPID", value: "\(pid)") }
    return SimLease(
      runID: runID, worktree: worktree, udid: udid, holderPID: pid, session: try text("session"))
  }

  public func encoded() -> Data {
    var object: [String: Any] = [
      "runID": runID, "worktree": worktree, "udid": udid, "holderPID": Int(holderPID),
    ]
    if let session { object["session"] = session }
    // Every value is a string or an integer, which JSONSerialization always encodes.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }
}

public enum SimLeaseOwnership: Sendable, Equatable {
  case owner
  /// The lease belongs to `leaseWorktree`, not the caller's.
  case otherWorktree(leaseWorktree: String)
}

public enum SimLeaseDecodingError: Error, Sendable, Equatable {
  /// Not a JSON object, or a key holds the wrong type.
  case malformed(String)
  case missingKey(String)
  case unknownKey(String)
  /// A key holds an empty string or a non-positive PID.
  case invalidValue(key: String, value: String)

  public var message: String {
    switch self {
    case .malformed(let detail): "sim lease is not a lease object: \(detail)"
    case .missingKey(let key): "sim lease has no \"\(key)\""
    case .unknownKey(let key): "sim lease has an unknown key \"\(key)\""
    case .invalidValue(let key, let value): "sim lease \"\(key)\" is invalid: \"\(value)\""
    }
  }
}

/// Why a `sim hold` gave its device back.
public enum SimHoldEnd: Sendable, Equatable {
  /// The lease file was removed, which is how `sim down` releases the device.
  case released
  /// The recorded `agent-device` session is no longer listed.
  case sessionGone(session: String)
  /// `[qa] session_timeout_minutes` passed.
  case timedOut(after: Duration)
  /// The process the hold was started for, a `qa run` holding 1 device for all its flow rows,
  /// exited.
  case ownerGone(pid: Int32)

  public var message: String {
    switch self {
    case .released: "the lease was removed"
    case .sessionGone(let session): "agent-device session \"\(session)\" is gone"
    case .timedOut(let after): "the session timeout of \(after.components.seconds / 60) min passed"
    case .ownerGone(let pid): "its owner, PID \(pid), exited"
    }
  }
}

/// The holder's decision each time it looks: keep the device, or give it back and why.
public enum SimHoldWatch {
  /// - Parameters:
  ///   - lease: the lease as read now; `nil` once removed.
  ///   - liveSessions: session names `agent-device` lists now; `nil` when not asked this round
  ///     or the listing failed, which never ends the hold on its own.
  ///   - owner: the PID the hold lasts no longer than, and whether it is alive now; `nil` for a
  ///     hold with no owner.
  ///   - elapsed: time since the lease was written.
  public static func end(
    lease: SimLease?, liveSessions: Set<String>?, owner: (pid: Int32, alive: Bool)? = nil,
    elapsed: Duration, timeout: Duration
  ) -> SimHoldEnd? {
    guard let lease else { return .released }
    if let session = lease.session, let liveSessions, !liveSessions.contains(session) {
      return .sessionGone(session: session)
    }
    return elapsed >= timeout ? .timedOut(after: timeout) : nil
  }
}
