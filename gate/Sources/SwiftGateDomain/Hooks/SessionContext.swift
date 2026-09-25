import Foundation

public enum XcodePin {
  /// `26.2` accepts `26.2` and `26.2.x`, not `26.20`.
  public static func matches(pinned: String, selected: String) -> Bool {
    selected == pinned || selected.hasPrefix(pinned + ".")
  }
}

public struct PlanSummary: Sendable, Equatable {
  public let slug: String
  public let status: String
  public let resume: String?

  public init(slug: String, status: String, resume: String?) {
    self.slug = slug
    self.status = status
    self.resume = resume
  }
}

/// The shared `index.json` under the git common dir (spec §4, §5.8):
/// `{"plans": [{"slug", "status", "resume"}, …]}`. Other keys are ignored, so a plan's full
/// ledger never reaches session context through the index.
public struct PlanIndex: Sendable, Equatable {
  public static let finishedStatuses: Set<String> = [
    "done", "complete", "completed", "abandoned", "archived", "cancelled",
  ]

  public let plans: [PlanSummary]

  public init(plans: [PlanSummary]) { self.plans = plans }

  public var active: [PlanSummary] {
    plans.filter { !Self.finishedStatuses.contains($0.status.lowercased()) }
  }

  public static func decode(_ data: Data) throws -> PlanIndex {
    let wire = try JSONDecoder().decode(Wire.self, from: data)
    return PlanIndex(
      plans: wire.plans.map { PlanSummary(slug: $0.slug, status: $0.status, resume: $0.resume) })
  }

  /// One pretty-printed, key-sorted object, so two encodes of the same value produce identical
  /// bytes (`swiftgate index set` writes this under a file lock; the file is reviewable as a diff).
  public func encode() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(
      Wire(plans: plans.map { Wire.Plan(slug: $0.slug, status: $0.status, resume: $0.resume) }))
    data.append(UInt8(ascii: "\n"))
    return data
  }

  private struct Wire: Codable {
    struct Plan: Codable {
      let slug: String
      let status: String
      let resume: String?
    }

    let plans: [Plan]
  }
}

/// The compact context SessionStart injects (spec §8): the module map, the Xcode pin, and the
/// RESUME lines of active plans. Stays under Claude Code's 10,000-character hook output cap.
public enum SessionContext {
  public static let maxCharacters = 9_000
  static let maxResumeCharacters = 600
  /// Sub-budget for the rendered plan list (spec §6.3 row 7, §10): well under
  /// ``maxCharacters``, so a large ``index.json`` truncates with an explicit overflow count
  /// instead of the overall clip silently swallowing the tail of the plan list mid-line.
  static let maxPlanListCharacters = 4_000

  public struct ModuleEntry: Sendable, Equatable {
    public let package: String
    public let name: String
    public let role: String
    public let kind: String

    public init(package: String, name: String, role: String, kind: String) {
      self.package = package
      self.name = name
      self.role = role
      self.kind = kind
    }
  }

  public enum Xcode: Sendable, Equatable {
    case selected(pinned: String, version: String, developerDirectory: String)
    case unknown(pinned: String, reason: String)
  }

  public enum Plans: Sendable, Equatable {
    case none
    case active([PlanSummary])
    case unreadable(String)
  }

  public struct Inputs: Sendable, Equatable {
    public let projectName: String
    /// The Claude Code session id (spec §6.3 row 1): a skill reads it back out of this context
    /// to pass `--session` to `swiftgate plan claim`/`plan release`, since skills can't read hook
    /// payloads directly. Empty when the caller has none to report (never rendered).
    public let sessionID: String
    public let modules: [ModuleEntry]
    /// `nil` when there is no valid config to read the pin from.
    public let xcode: Xcode?
    public let plans: Plans
    /// Extra lines: a module map that could not be built, an invalid config, sweep results.
    public let notes: [String]

    public init(
      projectName: String, sessionID: String = "", modules: [ModuleEntry], xcode: Xcode?,
      plans: Plans, notes: [String]
    ) {
      self.projectName = projectName
      self.sessionID = sessionID
      self.modules = modules
      self.xcode = xcode
      self.plans = plans
      self.notes = notes
    }
  }

  /// Classifies the shared `index.json` (spec §6.3 rows 1 and 7): no bytes at all — no common
  /// dir, no file yet, or being outside a git repository — degrades silently to ``Plans/none``,
  /// since that is the ordinary "no plan started" state. Bytes that fail to decode are the one
  /// case worth a note: a file exists but this build can't trust it.
  public static func resolvePlans(indexData: Data?) -> Plans {
    guard let indexData else { return .none }
    do {
      return .active(try PlanIndex.decode(indexData).active)
    } catch {
      return .unreadable("\(error)")
    }
  }

  public static func render(_ inputs: Inputs) -> String {
    var lines = [
      "swift-harness is active in \(inputs.projectName) (.swiftgate.toml). Gate commands go "
        + "through `swiftgate`; the Stop hook runs `swiftgate check --tier fast` and blocks a RED "
        + "result. Raw xcodebuild, `simctl erase|delete all`, snapshot recording, global "
        + "DerivedData deletion and hand edits to snapshots, Package.resolved or .xcresult are "
        + "denied."
    ]
    if !inputs.sessionID.isEmpty {
      lines.append(
        "Session id: \(inputs.sessionID) (pass as `--session` to `swiftgate plan claim`/`plan "
          + "release`).")
    }
    if !inputs.modules.isEmpty {
      lines.append("Modules by package (role, kind):")
      let packages = Dictionary(grouping: inputs.modules, by: \.package)
      for package in packages.keys.sorted() {
        let modules = (packages[package] ?? []).map { "\($0.name) (\($0.role), \($0.kind))" }
        lines.append("- \(package): \(modules.joined(separator: ", "))")
      }
    }
    switch inputs.xcode {
    case .selected(let pinned, let version, let directory):
      if XcodePin.matches(pinned: pinned, selected: version) {
        lines.append("Xcode: pinned \(pinned); selected \(version) (\(directory)).")
      } else {
        lines.append(
          "Xcode MISMATCH: .swiftgate.toml pins \(pinned) but \(version) is selected "
            + "(\(directory)). Simulator tiers need the pinned Xcode: `xcode-select -s` or "
            + "DEVELOPER_DIR.")
      }
    case .unknown(let pinned, let reason):
      lines.append("Xcode: pinned \(pinned); the selected Xcode is unknown (\(reason)).")
    case nil:
      break
    }
    switch inputs.plans {
    case .none:
      break
    case .active(let plans) where plans.isEmpty:
      lines.append("Active plans: none.")
    case .active(let plans):
      lines.append("Active plans (RESUME summaries; ledgers are orchestrator-only):")
      var shownCharacters = 0
      var shown = 0
      for plan in plans {
        let resume =
          plan.resume.map {
            clip(
              $0.split(whereSeparator: \.isNewline).joined(separator: " "), to: maxResumeCharacters)
          } ?? "no RESUME summary"
        let line = "- \(plan.slug) (\(plan.status)): \(resume)"
        if shown > 0, shownCharacters + line.count > maxPlanListCharacters { break }
        lines.append(line)
        shownCharacters += line.count
        shown += 1
      }
      let omitted = plans.count - shown
      if omitted > 0 {
        lines.append(
          "…and \(omitted) more active plan\(omitted == 1 ? "" : "s") not shown (over the "
            + "context budget).")
      }
    case .unreadable(let reason):
      lines.append("Plans: the shared plan index is unreadable: \(reason)")
    }
    lines += inputs.notes
    return clip(lines.joined(separator: "\n"), to: maxCharacters)
  }

  private static func clip(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit - 1)) + "…"
  }
}
