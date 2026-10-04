import Foundation

/// The rules `sim verify` applies to a run's recorded evidence. Each is `RED`: the evidence
/// doesn't show the app did what the run claims.
public enum SimEvidenceRule: String, Sendable, Equatable, CaseIterable {
  /// The run recorded no step.
  case noSteps = "sim.no-steps"
  /// A step names a screenshot or tree that isn't on disk, can't be read, or doesn't parse.
  case evidenceMissing = "sim.evidence-missing"
  /// A step's `assert` text isn't in that step's tree.
  case assertAbsent = "sim.assert-absent"
  /// The checkout's HEAD isn't the commit `sim up` built.
  case staleHead = "sim.stale-head"
  /// An interactive element in a step's tree has no accessibility identifier.
  case a11yIdentifier = "sim.a11y-identifier"
  /// An interactive element in a step's tree has no readable label.
  case a11yLabel = "sim.a11y-label"

  public var verdict: Verdict { .red }
}

/// One step file as the loader found it. A path with no entry isn't on disk.
public enum SimEvidenceFile: Sendable, Equatable {
  case present(Data)
  /// On disk, but reading it failed, with why.
  case unreadable(String)
}

/// The checkout's HEAD as the caller read it.
public enum SimCheckoutHead: Sendable, Equatable {
  case commit(String)
  /// git couldn't name HEAD, with why.
  case unreadable(String)
}

/// A run's `sim/` folder, loaded: the session, the step log, and each file a step names.
public struct SimEvidence: Sendable, Equatable {
  public var runID: String
  public var session: SimSession
  public var steps: [SimStep]
  /// Keyed by the path relative to the run's `sim/` folder, as the step line names it.
  public var files: [String: SimEvidenceFile]

  public init(
    runID: String, session: SimSession, steps: [SimStep], files: [String: SimEvidenceFile]
  ) {
    self.runID = runID
    self.session = session
    self.steps = steps
    self.files = files
  }

  /// Whether a step line's `path` stays inside the run's `sim/` folder: relative, with no `..`
  /// component. A loader reads only these.
  public static func isInsideRun(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else { return false }
    return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
}

/// What one rule found.
public struct SimEvidenceFinding: Sendable, Equatable {
  public var rule: SimEvidenceRule
  /// The step it concerns; `nil` for a finding about the whole run.
  public var step: Int?
  /// The file it concerns, relative to the run's `sim/` folder.
  public var path: String?
  public var message: String

  public init(rule: SimEvidenceRule, step: Int?, path: String?, message: String) {
    self.rule = rule
    self.step = step
    self.path = path
    self.message = message
  }
}

public enum SimEvidenceRules {
  private enum StepFile {
    case read(Data)
    case missing(SimEvidenceFinding)
  }

  /// Every finding over `evidence`, in step order, the run-level ones first. `checkoutHead` is
  /// `nil` when it couldn't be read, so `sim.stale-head` isn't judged.
  public static func findings(_ evidence: SimEvidence, checkoutHead: String?)
    -> [SimEvidenceFinding]
  {
    var findings: [SimEvidenceFinding] = []
    if evidence.steps.isEmpty {
      findings.append(
        SimEvidenceFinding(
          rule: .noSteps, step: nil, path: SimStep.logFileName,
          message: "run \(evidence.runID) recorded no step: run sim snap at each checked point"))
    }
    if let checkoutHead, checkoutHead != evidence.session.headCommit {
      findings.append(
        SimEvidenceFinding(
          rule: .staleHead, step: nil, path: SimSession.fileName,
          message:
            "run \(evidence.runID) built \(evidence.session.headCommit), but the checkout is at "
            + "\(checkoutHead): run sim up again on this commit"))
    }
    for step in evidence.steps {
      findings += stepFindings(step, files: evidence.files)
    }
    return findings
  }

  private static func stepFindings(_ step: SimStep, files: [String: SimEvidenceFile])
    -> [SimEvidenceFinding]
  {
    let name = "step \(SimStep.stem(step.n)) \"\(step.label)\""
    func missing(_ path: String, _ why: String) -> SimEvidenceFinding {
      SimEvidenceFinding(
        rule: .evidenceMissing, step: step.n, path: path, message: "\(name): \(path) \(why)")
    }
    func contents(_ path: String) -> StepFile {
      guard SimEvidence.isInsideRun(path) else {
        return .missing(missing(path, "is outside the run's sim folder, so it isn't this run's"))
      }
      switch files[path] {
      case nil: return .missing(missing(path, "isn't on disk"))
      case .unreadable(let reason)?: return .missing(missing(path, "can't be read: \(reason)"))
      case .present(let data)?: return .read(data)
      }
    }

    var findings: [SimEvidenceFinding] = []
    switch contents(step.screenshot) {
    case .missing(let finding): findings.append(finding)
    case .read(let png) where png.isEmpty: findings.append(missing(step.screenshot, "is empty"))
    case .read: break
    }

    let tree: SimTree
    switch contents(step.tree) {
    case .missing(let finding):
      findings.append(finding)
      return findings
    case .read(let data):
      do throws(SimTreeError) {
        tree = try SimTree.parse(snapshotJSON: data)
      } catch {
        switch error {
        case .unknownRole(let role):
          findings.append(
            missing(step.tree, "holds the role \(role), which the pinned agent-device can't name"))
        case .malformed(let reason):
          findings.append(missing(step.tree, "doesn't parse as a snapshot: \(reason)"))
        }
        return findings
      }
    }
    if let assert = step.assert, !tree.contains(text: assert) {
      findings.append(
        SimEvidenceFinding(
          rule: .assertAbsent, step: step.n, path: step.tree,
          message: "\(name): no element's label or value is \"\(assert)\" in \(step.tree)"))
    }
    return findings
  }
}

/// `sim verify`'s verdict over one run: what `sim/report.json` holds.
public struct SimVerifyReport: Sendable, Equatable {
  public static let fileName = "report.json"
  /// The history line's `command`.
  public static let command = "sim verify"

  public var runID: String
  /// `nil` when the step log couldn't be read.
  public var stepCount: Int?
  /// The commit `sim up` built, from `session.json`; `nil` when it couldn't be read.
  public var headCommit: String?
  /// `nil` when git couldn't name it.
  public var checkoutHead: String?
  public var findings: [SimEvidenceFinding]
  /// Why the run couldn't be fully judged; `nil` when it was.
  public var blocked: String?

  public init(
    runID: String, stepCount: Int?, headCommit: String?, checkoutHead: String?,
    findings: [SimEvidenceFinding], blocked: String?
  ) {
    self.runID = runID
    self.stepCount = stepCount
    self.headCommit = headCommit
    self.checkoutHead = checkoutHead
    self.findings = findings
    self.blocked = blocked
  }

  /// The rules applied to a loaded run. An unreadable HEAD leaves the run `BLOCKED` unless
  /// another rule finds it `RED`.
  public static func judged(_ evidence: SimEvidence, checkoutHead: SimCheckoutHead)
    -> SimVerifyReport
  {
    let head = checkoutHead.commit
    return SimVerifyReport(
      runID: evidence.runID, stepCount: evidence.steps.count,
      headCommit: evidence.session.headCommit, checkoutHead: head,
      findings: SimEvidenceRules.findings(evidence, checkoutHead: head),
      blocked: checkoutHead.reason.map { "can't read the checkout's HEAD: \($0)" })
  }

  /// A run whose `session.json` or step log couldn't be read: `BLOCKED`, never `GREEN`.
  public static func unreadable(runID: String, reason: String, checkoutHead: SimCheckoutHead)
    -> SimVerifyReport
  {
    SimVerifyReport(
      runID: runID, stepCount: nil, headCommit: nil, checkoutHead: checkoutHead.commit,
      findings: [], blocked: reason)
  }

  /// `RED` on any finding, else `BLOCKED` when the run couldn't be fully judged, else `GREEN`.
  public var verdict: Verdict {
    Verdict.merged([findings.isEmpty ? .green : .red, blocked == nil ? .green : .blocked])
  }

  /// `{schemaVersion, command, runID, verdict, stepCount, headCommit, checkoutHead, blocked,
  /// findings: [{rule, step, path, message}]}`, with `null` for each unknown value.
  public func json() -> Data {
    let object: [String: Any] = [
      "schemaVersion": SimSession.schemaVersion, "command": Self.command, "runID": runID,
      "verdict": verdict.rawValue, "stepCount": stepCount ?? NSNull(),
      "headCommit": headCommit ?? NSNull(), "checkoutHead": checkoutHead ?? NSNull(),
      "blocked": blocked ?? NSNull(),
      "findings": findings.map { finding -> [String: Any] in
        [
          "rule": finding.rule.rawValue, "step": finding.step ?? NSNull(),
          "path": finding.path ?? NSNull(), "message": finding.message,
        ]
      },
    ]
    // Strings, integers, arrays, objects and null always encode.
    return
      (try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
  }

  public var text: String {
    let steps = stepCount.map { $0 == 1 ? "1 step" : "\($0) steps" } ?? "steps unread"
    var lines = ["sim verify \(verdict.rawValue): run \(runID), \(steps)"]
    lines += findings.map { "  \($0.rule.rawValue): \($0.message)" }
    if let blocked { lines.append("  BLOCKED: \(blocked)") }
    return lines.joined(separator: "\n")
  }

  /// The report as a history line's ``RunReport``: 1 T3 tier carrying the verdict, and 1 major
  /// finding per rule finding, its file relative to the run directory.
  public func runReport(durationMilliseconds: Int) throws(ReportContractViolation) -> RunReport {
    var mapped: [Finding] = []
    for finding in findings {
      mapped.append(
        try Finding(
          ruleID: finding.rule.rawValue, severity: .major,
          file: "\(SimSession.directoryName)/\(finding.path ?? SimStep.logFileName)", line: nil,
          message: finding.message, failureScenario: nil))
    }
    return try RunReport(
      runID: runID, durationMilliseconds: durationMilliseconds,
      tiers: [
        try TierResult(
          tier: .t3, verdict: verdict, durationMilliseconds: durationMilliseconds,
          testCounts: nil)
      ], findings: mapped)
  }
}

/// Why `sim verify` judged nothing: it wrote no report and no history line.
public enum SimVerifyRefusal: String, Sendable, Equatable, CaseIterable {
  /// The run's lease belongs to another worktree.
  case notOwner = "sim.not-owner"
  /// No run to judge could be found: no run id and no live lease, or the leases couldn't be read.
  case environment = "swiftgate.environment"

  public var verdict: Verdict {
    switch self {
    case .notOwner: .red
    case .environment: .blocked
    }
  }
}

public struct SimVerifyFailure: Error, Sendable, Equatable {
  public var rule: SimVerifyRefusal
  public var message: String
  /// The run, once one is resolved.
  public var runID: String?

  public init(rule: SimVerifyRefusal, message: String, runID: String? = nil) {
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
    "sim verify \(verdict.rawValue) \(rule.rawValue): \(message)"
  }
}

extension SimCheckoutHead {
  fileprivate var commit: String? {
    if case .commit(let sha) = self { sha } else { nil }
  }

  fileprivate var reason: String? {
    if case .unreadable(let why) = self { why } else { nil }
  }
}
