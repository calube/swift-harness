import Foundation

/// The rule ids `sim down` reports.
public enum SimDownRule: String, Sendable, Equatable, CaseIterable {
  /// The run's lease belongs to another worktree.
  case notOwner = "sim.not-owner"
  /// `agent-device` could not close the run's session or release its claims.
  case driverFailed = "sim.driver-failed"
  /// The lease couldn't be read or removed, or the holder or device outlived the wait.
  case environment = "swiftgate.environment"

  public var verdict: Verdict {
    switch self {
    case .notOwner: .red
    case .driverFailed, .environment: .blocked
    }
  }
}

/// Why `sim down` did not finish cleanly.
public struct SimDownFailure: Error, Sendable, Equatable {
  public var rule: SimDownRule
  public var message: String
  /// The run, once `sim down` has resolved one.
  public var runID: String?

  public init(rule: SimDownRule, message: String, runID: String? = nil) {
    self.rule = rule
    self.message = message
    self.runID = runID
  }

  public var verdict: Verdict { rule.verdict }

  /// `{schemaVersion, verdict, ruleID, message, runID}`, `runID` `null` before a run is resolved.
  public func json() -> Data {
    let object: [String: Any] = [
      "schemaVersion": SimSession.schemaVersion, "verdict": verdict.rawValue,
      "ruleID": rule.rawValue, "message": message, "runID": runID ?? NSNull(),
    ]
    // Strings, an integer and null always encode.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  public var text: String {
    "sim down \(verdict.rawValue) \(rule.rawValue): \(message)"
  }
}

/// What a successful `sim down` did.
public enum SimDownOutcome: Sendable, Equatable {
  /// No lease was there to release: `runID` names the run asked for, or is `nil` when this
  /// worktree holds no run at all.
  case nothingHeld(runID: String?)
  /// The run's session was closed, its lease removed, its holder and device are gone, and its
  /// stale `agent-device` claims were released.
  case released(runID: String, udid: String)
}

/// What a successful `sim down` prints. `notes` name anything it could not check, such as an
/// unreadable lease or a session listing that failed; none of them fails the call.
public struct SimDowned: Sendable, Equatable {
  public var outcome: SimDownOutcome
  public var notes: [String]
  /// The crash reports copied into the run's `sim/crashes/`, relative to `sim/`.
  public var crashReports: [String]

  public init(outcome: SimDownOutcome, notes: [String] = [], crashReports: [String] = []) {
    self.outcome = outcome
    self.notes = notes
    self.crashReports = crashReports
  }

  /// `{schemaVersion, verdict, released, runID, udid, crashReports, notes}`, `runID` and `udid`
  /// `null` when they are unknown.
  public func json() -> Data {
    let runID: String?
    let udid: String?
    switch outcome {
    case .nothingHeld(let run):
      runID = run
      udid = nil
    case .released(let run, let device):
      runID = run
      udid = device
    }
    let object: [String: Any] = [
      "schemaVersion": SimSession.schemaVersion, "verdict": Verdict.green.rawValue,
      "released": udid != nil, "runID": runID ?? NSNull(), "udid": udid ?? NSNull(),
      "crashReports": crashReports, "notes": notes,
    ]
    // Strings, an integer, a boolean, a list of strings and null always encode.
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
  }

  public var text: String {
    let head =
      switch outcome {
      case .nothingHeld(let runID?): "sim down: run \(runID) holds no simulator; nothing to release"
      case .nothingHeld(nil): "sim down: this worktree holds no simulator; nothing to release"
      case .released(let runID, let udid):
        "sim down: run \(runID) released \(udid): session closed, device deleted, claims released"
      }
    let reports = crashReports.map { "  crash report: \($0)" }
    return ([head] + reports + notes.map { "  note: \($0)" }).joined(separator: "\n")
  }
}

/// What sweeping the leases of dead holders did. A holder killed outright never closes its
/// `agent-device` session, and the session's claim belongs to the still-running `agent-device`
/// daemon, so neither the orphan device sweep nor `release --stale` frees it.
public struct SimLeaseSweep: Sendable, Equatable {
  /// The runs whose session was closed, lease removed and claims released.
  public var released: [String]
  /// What could not be freed, each naming its run; any one makes `gc` BLOCKED.
  public var problems: [String]
  /// Unreadable leases skipped, which never fail the sweep.
  public var notes: [String]

  public init(released: [String] = [], problems: [String] = [], notes: [String] = []) {
    self.released = released
    self.problems = problems
    self.notes = notes
  }
}
