import Foundation

/// The table `swiftgate discover` prints (design §5.2): 1 row per value, with its source and
/// confidence, then 1 `missing:` line per step with no command.
public enum ProposalTable {
  /// `appliedTo` is the config path an `--apply` wrote; `nil` for a proposal only printed.
  public static func render(_ proposal: DiscoverProposal, milliseconds: Int, appliedTo: String?)
    -> String
  {
    let seconds = String(format: "%.1f", Double(milliseconds) / 1_000)
    let areaCount = proposal.areas.count == 1 ? "1 area" : "\(proposal.areas.count) areas"
    let header =
      "swiftgate discover · \(areaCount) · \(seconds)s · "
      + (appliedTo.map { "applied to \($0)" } ?? "not applied")
    var rows = [
      ["area", "language", "root", "value", "command or setting", "source", "confidence"]
    ]
    for area in proposal.areas {
      let lead = [area.name, area.language.rawValue, area.root]
      for step in AreaStep.allCases {
        guard let value = area.commands[step] else { continue }
        rows.append(
          lead + [step.rawValue, value.value, value.source, value.confidence.rawValue])
      }
      if let xcode = area.xcode {
        let setting =
          xcode.value.inclusion.rawValue
          + (xcode.value.manifest.map { " (manifest \($0))" } ?? "")
        rows.append(
          lead + ["inclusion", setting, xcode.source, xcode.confidence.rawValue])
      }
    }
    let widths = rows[0].indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
    let table = rows.map { row in
      row.indices.map { column in
        column == row.count - 1
          ? row[column] : row[column].padding(toLength: widths[column], withPad: " ", startingAt: 0)
      }.joined(separator: "  ")
    }
    let missing = proposal.areas.flatMap { area in
      AreaStep.allCases.compactMap { step in
        area.missing[step].map { "missing: \(area.name) \(step.rawValue) (\($0))" }
      }
    }
    return ([header] + table + missing).joined(separator: "\n")
  }
}

/// `discover/last.json`: the last applied proposal, with every value's source and confidence,
/// the edits that shaped it, and the dirty files. The warm-up and the run report read it.
public struct DiscoverRecord: Sendable, Equatable, Codable {
  public struct Value: Sendable, Equatable, Codable {
    public let step: AreaStep
    public let command: String
    public let source: String
    public let confidence: Confidence
  }

  public struct Missing: Sendable, Equatable, Codable {
    public let step: AreaStep
    public let reason: String
  }

  public struct Xcode: Sendable, Equatable, Codable {
    public let workspace: String?
    public let project: String?
    public let inclusion: XcodeInclusion
    public let manifest: String?
    public let schemes: [String]
    public let source: String
    public let confidence: Confidence
  }

  public struct Area: Sendable, Equatable, Codable {
    public let name: String
    public let root: String
    public let language: AreaLanguage
    public let kind: AreaKind
    public let source: String
    public let values: [Value]
    public let missing: [Missing]
    public let testGlobs: [String]
    public let xcode: Xcode?
    public let generatedProjectTracked: Bool?
  }

  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let head: String
  public let areas: [Area]
  public let dirty: [String]
  public let edits: [DiscoverEdit]

  public init(proposal: DiscoverProposal, edits: [DiscoverEdit]) {
    self.schemaVersion = Self.schemaVersion
    self.head = proposal.head
    self.areas = proposal.areas.map { area in
      Area(
        name: area.name, root: area.root, language: area.language, kind: area.kind,
        source: area.source,
        values: AreaStep.allCases.compactMap { step in
          area.commands[step].map {
            Value(step: step, command: $0.value, source: $0.source, confidence: $0.confidence)
          }
        },
        missing: AreaStep.allCases.compactMap { step in
          area.missing[step].map { Missing(step: step, reason: $0) }
        },
        testGlobs: area.testGlobs,
        xcode: area.xcode.map {
          Xcode(
            workspace: $0.value.workspace, project: $0.value.project,
            inclusion: $0.value.inclusion, manifest: $0.value.manifest,
            schemes: $0.value.schemes, source: $0.source, confidence: $0.confidence)
        },
        generatedProjectTracked: area.generatedProjectTracked)
    }
    self.dirty = proposal.dirty
    self.edits = edits
  }

  /// The proposal this record holds.
  public var proposal: DiscoverProposal {
    DiscoverProposal(
      head: head,
      areas: areas.map { area in
        ProposedArea(
          name: area.name, root: area.root, language: area.language, kind: area.kind,
          source: area.source,
          commands: Dictionary(
            area.values.map {
              ($0.step, Sourced(value: $0.command, source: $0.source, confidence: $0.confidence))
            }, uniquingKeysWith: { first, _ in first }),
          missing: Dictionary(
            area.missing.map { ($0.step, $0.reason) }, uniquingKeysWith: { first, _ in first }),
          testGlobs: area.testGlobs,
          xcode: area.xcode.map {
            Sourced(
              value: XcodeAreaConfig(
                workspace: $0.workspace, project: $0.project, inclusion: $0.inclusion,
                manifest: $0.manifest, schemes: $0.schemes), source: $0.source,
              confidence: $0.confidence)
          },
          generatedProjectTracked: area.generatedProjectTracked)
      }, dirty: dirty)
  }
}

/// `discover/dirty.json`: the paths modified or untracked when discovery ran, which workers never
/// stage.
public struct DiscoverDirtyFiles: Sendable, Equatable, Codable {
  public let head: String
  /// Repository-relative, as `git status --porcelain` prints them; an untracked directory ends
  /// in `/`.
  public let paths: [String]

  public init(head: String, paths: [String]) {
    self.head = head
    self.paths = paths
  }
}
