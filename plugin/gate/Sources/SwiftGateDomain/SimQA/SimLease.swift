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
    .owner
  }

  /// A run id names a file, so it is one non-empty path component that does not start with `.`.
  public static func isValidRunID(_ runID: String) -> Bool {
    !runID.isEmpty
  }

  public static func decode(_ data: Data) throws(SimLeaseDecodingError) -> SimLease {
    throw .malformed("not implemented")
  }

  public func encoded() -> Data {
    Data()
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

  public var message: String {
    switch self {
    case .released: "the lease was removed"
    case .sessionGone(let session): "agent-device session \"\(session)\" is gone"
    case .timedOut(let after): "the session timeout of \(after.components.seconds / 60) min passed"
    }
  }
}

/// The holder's decision each time it looks: keep the device, or give it back and why.
public enum SimHoldWatch {
  /// - Parameters:
  ///   - lease: the lease as read now; `nil` once removed.
  ///   - liveSessions: session names `agent-device` lists now; `nil` when not asked this round
  ///     or the listing failed, which never ends the hold on its own.
  ///   - elapsed: time since the lease was written.
  public static func end(
    lease: SimLease?, liveSessions: Set<String>?, elapsed: Duration, timeout: Duration
  ) -> SimHoldEnd? {
    nil
  }
}
