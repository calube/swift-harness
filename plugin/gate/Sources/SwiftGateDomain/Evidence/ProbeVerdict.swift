/// Where each probe snippet lives and the Swift enum it's wrapped in (spec §6.2): one file per
/// probe, so a compiler diagnostic's file name attributes back to the claim it probes.
public enum ProbeIdentifier {
  /// `Probe_<id>`, with the id's hyphens — the only character a valid `ev-` id contains besides
  /// lowercase ASCII letters and digits (``IdPolicy``) — turned into underscores, since a Swift
  /// identifier can't hold one. Distinct ids stay distinct: hyphen is the only character this
  /// remaps, and no valid `ev-` id already contains an underscore.
  public static func enumName(forClaimID claimID: String) -> String {
    "Probe_" + String(claimID.map { $0 == "-" ? "_" : $0 })
  }

  /// The probe's source file name: its enum name plus `.swift`, so a compiler diagnostic's file
  /// attributes back to this claim.
  public static func fileName(forClaimID claimID: String) -> String {
    enumName(forClaimID: claimID) + ".swift"
  }
}

/// One `error:`/`warning:` line read from a captured `swift build`/`xcodebuild` run.
public struct ProbeDiagnostic: Sendable, Equatable {
  public let file: String
  public let line: Int
  public let column: Int
  public let level: LintLevel
  public let message: String

  public init(file: String, line: Int, column: Int, level: LintLevel, message: String) {
    self.file = file
    self.line = line
    self.column = column
    self.level = level
    self.message = message
  }
}

/// Reads primary diagnostic lines out of a captured build's combined output
/// (`Tests/Fixtures/README.md` "Probe"). Only `<path>:<line>:<col>: error|warning: <message>`
/// carries a file to attribute a diagnostic to; the source-snippet and caret-continuation lines a
/// compiler prints under it start with no such prefix, so a line-anchored match never mistakes
/// them for one. A parse error recurs once per remaining compile job in the same invocation, so a
/// caller must not assume one diagnostic per file.
public enum CompilerDiagnostics {
  public static func parse(_ output: String) -> [ProbeDiagnostic] {
    // A regex literal is not Sendable, so it is built per call rather than cached in a global.
    let primaryLine =
      #/^(?<file>.+\.swift):(?<line>[0-9]+):(?<column>[0-9]+): (?<level>error|warning): (?<message>.+)$/#
    return output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
      guard let match = try? primaryLine.wholeMatch(in: line),
        let lineNumber = Int(match.line),
        let column = Int(match.column),
        let level = LintLevel(rawValue: String(match.level))
      else { return nil }
      return ProbeDiagnostic(
        file: String(match.file), line: lineNumber, column: column, level: level,
        message: String(match.message))
    }
  }
}

/// One probe's verdict: the diagnostics its own file produced, and the ``Verdict`` they add up to
/// (spec §6.2 — a fabricated API or a wrong signature fails; a warning never does).
public struct ProbeVerdict: Sendable, Equatable {
  public let claimID: String
  public let diagnostics: [ProbeDiagnostic]
  public let verdict: Verdict

  public init(claimID: String, diagnostics: [ProbeDiagnostic]) {
    self.claimID = claimID
    self.diagnostics = diagnostics
    self.verdict = diagnostics.contains { $0.level == .error } ? .red : .green
  }
}

/// Attributes a build's diagnostics to the probes that produced them, by matching each
/// diagnostic's file name against ``ProbeIdentifier/fileName(forClaimID:)``. A diagnostic that
/// matches none of them is not silently dropped and not silently passed (spec §6.2: "an
/// unattributed error is a gate error") — it forces ``verdict`` to at least ``Verdict/blocked``,
/// which a real ``Verdict/red`` from an attributed probe still dominates, matching
/// ``Verdict/merged(with:)``'s own rule that a proven failure outranks an inconclusive one.
public struct ProbeAttribution: Sendable, Equatable {
  public let verdicts: [ProbeVerdict]
  public let unattributed: [ProbeDiagnostic]

  public var verdict: Verdict {
    let attributed = Verdict.merged(verdicts.map(\.verdict))
    let unattributedVerdict: Verdict =
      unattributed.contains { $0.level == .error } ? .blocked : .green
    return attributed.merged(with: unattributedVerdict)
  }

  /// - Parameters:
  ///   - diagnostics: every diagnostic parsed from one build.
  ///   - claimIDs: every probe under test in this build. A claim id whose file produced no
  ///     diagnostic still gets a ``ProbeVerdict`` (``Verdict/green``, no diagnostics).
  public static func attribute(_ diagnostics: [ProbeDiagnostic], probes claimIDs: [String])
    -> ProbeAttribution
  {
    let claimIDByFileName = Dictionary(
      uniqueKeysWithValues: claimIDs.map { (ProbeIdentifier.fileName(forClaimID: $0), $0) })
    var diagnosticsByClaimID: [String: [ProbeDiagnostic]] = Dictionary(
      uniqueKeysWithValues: claimIDs.map { ($0, []) })
    var unattributed: [ProbeDiagnostic] = []
    for diagnostic in diagnostics {
      guard let claimID = claimIDByFileName[fileName(diagnostic.file)] else {
        unattributed.append(diagnostic)
        continue
      }
      diagnosticsByClaimID[claimID, default: []].append(diagnostic)
    }
    return ProbeAttribution(
      verdicts: claimIDs.map {
        ProbeVerdict(claimID: $0, diagnostics: diagnosticsByClaimID[$0] ?? [])
      },
      unattributed: unattributed)
  }

  /// The diagnostic's file, stripped to its last path component: attribution matches on the
  /// probe's file name, not the scratch package's absolute path.
  private static func fileName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}
