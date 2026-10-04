import Foundation

/// Filed exemptions from the impact rule, read from ``RunLayout/impactExemptionsFile``. Each names one module or one
/// file and must say why the change needs no test change.
public struct ImpactExemptions: Sendable, Equatable {
  /// How messages name the file.
  public static let displayPath = RunLayout.treePath(RunLayout.impactExemptionsFile)
  public static let supportedSchema = 1
  public static let none = ImpactExemptions(entries: [])

  public enum Target: Sendable, Hashable {
    case module(String)
    case path(String)
  }

  public struct Entry: Sendable, Equatable {
    public let target: Target
    public let reason: String
  }

  public let entries: [Entry]

  private struct File: Decodable {
    struct RawEntry: Decodable {
      let module: String?
      let path: String?
      let reason: String?
    }

    let schema: Int
    let exemptions: [RawEntry]
  }

  public static func decode(_ data: Data) throws(ImpactExemptionsError) -> ImpactExemptions {
    let file: File
    do {
      file = try JSONDecoder().decode(File.self, from: data)
    } catch {
      throw .malformed(String(describing: error))
    }
    guard file.schema == supportedSchema else { throw .unsupportedSchema(file.schema) }
    var entries: [Entry] = []
    for (index, raw) in file.exemptions.enumerated() {
      let target: Target
      switch (raw.module?.nonBlank, raw.path?.nonBlank) {
      case (let module?, nil): target = .module(module)
      case (nil, let path?): target = .path(path)
      default: throw .ambiguousTarget(index: index)
      }
      guard let reason = raw.reason?.nonBlank else { throw .missingReason(index: index) }
      entries.append(Entry(target: target, reason: reason))
    }
    return ImpactExemptions(entries: entries)
  }

  func reason(forPath path: String, module: String) -> String? {
    entries.first { $0.target == .path(path) }?.reason
      ?? entries.first { $0.target == .module(module) }?.reason
  }
}

/// The exemptions file is the repository's own input, so every case is a code problem (`red`).
public enum ImpactExemptionsError: Error, Sendable, Equatable, CustomStringConvertible {
  case malformed(String)
  case unsupportedSchema(Int)
  /// An entry must name exactly one of `module` or `path`.
  case ambiguousTarget(index: Int)
  case missingReason(index: Int)

  public var description: String {
    let file = ImpactExemptions.displayPath
    switch self {
    case .malformed(let detail): return "\(file) is not valid JSON of the expected shape: \(detail)"
    case .unsupportedSchema(let schema):
      return "\(file) has schema \(schema); this swiftgate reads schema "
        + "\(ImpactExemptions.supportedSchema)"
    case .ambiguousTarget(let index):
      return "\(file) exemptions[\(index)] must name exactly one of `module` or `path`"
    case .missingReason(let index):
      return "\(file) exemptions[\(index)] needs a non-empty `reason`"
    }
  }
}

/// A changed file that needed a test change and was exempted instead.
public struct ImpactWaiver: Sendable, Equatable {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }
}

public struct ImpactResult: Sendable, Equatable {
  public let findings: [Finding]
  public let waived: [ImpactWaiver]
}

/// Spec rule 7.2.7: a changed Core, client or Live source file needs a change in the same
/// module's test target, or a filed exemption.
public enum ImpactAnalysis {
  public static let ruleID = "impact.untested-change"

  /// A module's host test target is named `<Module>Tests`. UI-flow (T3) targets never count: they
  /// don't exercise a module's logic directly.
  static func testedModule(of scope: ModuleScope) -> String? {
    guard case .tests(let tier) = scope.role, tier != .t3, scope.module.hasSuffix("Tests")
    else { return nil }
    return String(scope.module.dropLast("Tests".count))
  }

  static func needsTests(_ role: ModuleRole) -> Bool {
    switch role {
    case .core, .client, .clientLive: true
    case .ui, .app, .testSupport, .tests: false
    }
  }

  /// The changed files ``evaluate(changedFiles:scopes:exemptions:)`` would hold to the rule.
  public static func sourcesNeedingTests(
    changedFiles: [String], scopes: any ModuleScopeResolving
  ) -> [String] {
    changedFiles.filter { path in
      guard let scope = scopes.scope(forFile: path) else { return false }
      return needsTestChange(path: path, scope: scope)
    }
  }

  private static func needsTestChange(path: String, scope: ModuleScope) -> Bool {
    testedModule(of: scope) == nil && needsTests(scope.role) && path.hasSuffix(".swift")
  }

  public static func evaluate(
    changedFiles: [String], scopes: any ModuleScopeResolving, exemptions: ImpactExemptions
  ) throws(ReportContractViolation) -> ImpactResult {
    var testedModules = Set<String>()
    var sourcesByModule: [String: [String]] = [:]
    for path in changedFiles {
      guard let scope = scopes.scope(forFile: path) else { continue }
      if let tested = testedModule(of: scope) {
        testedModules.insert(tested)
      } else if needsTestChange(path: path, scope: scope) {
        sourcesByModule[scope.module, default: []].append(path)
      }
    }

    var findings: [Finding] = []
    var waived: [ImpactWaiver] = []
    for (module, paths) in sourcesByModule.sorted(by: { $0.key < $1.key })
    where !testedModules.contains(module) {
      var untested: [String] = []
      for path in paths.sorted() {
        if let reason = exemptions.reason(forPath: path, module: module) {
          waived.append(ImpactWaiver(path: path, reason: reason))
        } else {
          untested.append(path)
        }
      }
      guard let first = untested.first else { continue }
      let files = untested.count == 1 ? "1 file" : "\(untested.count) files"
      findings.append(
        try Finding(
          ruleID: ruleID, severity: .major, file: first, line: nil,
          message:
            "\(module) changed (\(files)) with no change under \(module)Tests; add or update a "
            + "test, or file an exemption with a reason in \(ImpactExemptions.displayPath)",
          failureScenario: "the changed behavior ships with no test that would catch it breaking"))
    }
    findings.sort { $0.file < $1.file }
    waived.sort { $0.path < $1.path }
    return ImpactResult(findings: findings, waived: waived)
  }
}

extension String {
  fileprivate var nonBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
