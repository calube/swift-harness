import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// T0 `swift format lint --strict` on the Swift files a change touches (spec §7.1). Whole-tree
/// formatting is not this gate's business: an untouched file's drift is not the change's fault.
enum FormatCheck {
  static let ruleIDPrefix = "format."
  /// A file `swift format` could not parse.
  static let parseRuleID = "format.parse"

  /// Changed paths, restricted to Swift files that still exist and that a source walk would read.
  static func files(changed: [String], root: URL, excluded: [String]) -> [String] {
    let collector = SwiftSourceCollector(root: root, excluding: excluded)
    return changed.filter { path in
      guard path.hasSuffix(".swift"), !collector.isExcluded(path) else { return false }
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(
        atPath: root.appending(path: path).path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    }.sorted()
  }

  static func run(
    changed: Result<[String], BlockedReason>, root: URL, excluded: [String],
    formatter: any SwiftFormatter
  ) async -> StaticCheckOutcome {
    let paths: [String]
    switch changed {
    case .failure(let reason): return .blocked(reason: "format: \(reason.text)")
    case .success(let changed): paths = files(changed: changed, root: root, excluded: excluded)
    }
    guard !paths.isEmpty else { return .checked(RuleRunResult(findings: [], allowances: [])) }
    let violations: [FormatViolation]
    do throws(SwiftFormatError) {
      violations = try await formatter.lint(paths: paths)
    } catch {
      return .blocked(reason: "swift format: \(error)")
    }
    do throws(ReportContractViolation) {
      return .checked(RuleRunResult(findings: try findings(violations), allowances: []))
    } catch {
      return .blocked(reason: "format: \(error)")
    }
  }

  static func findings(_ violations: [FormatViolation]) throws(ReportContractViolation)
    -> [Finding]
  {
    try violations.map { violation throws(ReportContractViolation) in
      try Finding(
        ruleID: violation.rule.map { ruleIDPrefix + $0 } ?? parseRuleID, severity: .major,
        file: violation.path, line: violation.line,
        message: "\(violation.message) (run `swift format --in-place \(violation.path)`)",
        failureScenario: nil)
    }
  }
}
