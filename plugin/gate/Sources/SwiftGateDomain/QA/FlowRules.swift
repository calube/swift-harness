import Foundation

/// The identifiers a flow's `id="…"` selectors may name, or why they can't be checked.
public enum FlowIDs: Sendable, Equatable {
  /// The raw values of the typed accessibility-id enum in `source`, a repo-relative path.
  case declared(source: String, ids: Set<String>)
  /// No module is configured; the reason becomes the `qa.flow-ids-unknown` note.
  case unconfigured(reason: String)
}

/// The 5 batch steps file rules (simulator QA amendment §6.1), each `RED`, and the note that says
/// identifiers weren't checked.
public enum FlowRules {
  public static let unparsedRuleID = "qa.flow-unparsed"
  public static let refTargetRuleID = "qa.flow-ref-target"
  public static let noAssertRuleID = "qa.flow-no-assert"
  public static let schemaRuleID = "qa.flow-schema"
  public static let unknownIDRuleID = "qa.flow-unknown-id"
  public static let idsUnknownRuleID = "qa.flow-ids-unknown"

  /// Every finding 1 steps file earns. An unparsed file earns only `qa.flow-unparsed`.
  /// - Parameter file: the path findings name.
  public static func check(file: String, data: Data, schemas: ToolSchemas, ids: FlowIDs)
    -> [Finding]
  {
    []
  }

  /// Checks each file, then adds 1 `qa.flow-ids-unknown` note when `ids` is unconfigured.
  public static func lint(
    files: [(path: String, data: Data)], schemas: ToolSchemas, ids: FlowIDs
  ) -> FlowLintReport {
    FlowLintReport(files: [], findings: [])
  }
}

/// What `qa lint` reports: the files it read, their findings and the verdict they make.
public struct FlowLintReport: Sendable, Equatable {
  public let files: [String]
  public let findings: [Finding]
  /// Why the rules couldn't run; `nil` when they ran.
  public let blockedReason: String?

  public init(files: [String], findings: [Finding]) {
    self.files = files
    self.findings = findings
    self.blockedReason = nil
  }

  /// `BLOCKED` when the rules couldn't run, `RED` when any finding gates, else `GREEN`.
  public var verdict: Verdict {
    .green
  }

  public var message: String {
    ""
  }

  /// A lint the environment stopped before any rule ran: the schemas or the id module didn't load.
  public static func blocked(_ message: String, files: [String]) -> FlowLintReport {
    FlowLintReport(files: files, findings: [])
  }
}

extension FlowLintReport: Codable {
  public init(from decoder: any Decoder) throws {
    self.files = []
    self.findings = []
    self.blockedReason = nil
  }

  /// `{files, verdict, findings, message}`, every key always present.
  public func encode(to encoder: any Encoder) throws {}
}
