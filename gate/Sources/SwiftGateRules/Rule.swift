import SwiftGateDomain

public struct RuleDescriptor: Sendable, Hashable {
  /// Stable, dotted id (`family.name`) that findings, allow directives and fixtures use.
  public let id: String
  public let severity: Severity
  public let summary: String

  public init(id: String, severity: Severity, summary: String) {
    self.id = id
    self.severity = severity
    self.summary = summary
  }
}

/// One rule match. The engine stamps the rule id and severity, so a rule cannot report under
/// another rule's id.
public struct RuleViolation: Sendable, Equatable {
  public let path: String
  /// 1-based lines the offending construct spans; the finding is reported at the first line that
  /// survives added-line filtering, and an allow directive must sit on that line.
  public let lines: ClosedRange<Int>
  public let message: String
  public let failureScenario: String?

  public init(
    path: String, lines: ClosedRange<Int>, message: String, failureScenario: String? = nil
  ) {
    self.path = path
    self.lines = lines
    self.message = message
    self.failureScenario = failureScenario
  }
}

/// Which files a rule examines.
public struct RuleScope: Sendable {
  private let predicate: @Sendable (SourceUnit) -> Bool

  public init(_ predicate: @escaping @Sendable (SourceUnit) -> Bool) {
    self.predicate = predicate
  }

  public func includes(_ unit: SourceUnit) -> Bool { predicate(unit) }

  public static let allFiles = RuleScope { _ in true }

  /// Files whose module has one of `roles`. Files of unknown module are excluded: a role-scoped
  /// rule firing on a guess would be a false positive.
  public static func roles(_ roles: Set<ModuleRole>) -> RuleScope {
    RuleScope { unit in unit.scope.map { roles.contains($0.role) } ?? false }
  }

  /// Files in a test target, or that import a test framework (so a test file outside the usual
  /// layout is still checked).
  public static let testFiles = RuleScope(\.isTestFile)
}

/// Inputs a rule may need beyond the source itself. Everything here is injected so rules stay
/// pure and testable without a repository.
public struct RuleContext: Sendable {
  public let scopes: any ModuleScopeResolving
  /// Names of the declared T3 flows, or `nil` when the repository has no config (the closed-list
  /// rule then has nothing to enforce).
  public let flows: [String]?
  /// Private codenames that must not appear in shared comments.
  public let privateCodenames: [String]
  /// Vendor SDK module names that may be imported only inside `*Live` modules.
  public let vendorModules: Set<String>
  /// Ledger task, claim and doc ids (``KnownIds``) that must not leak into a comment or test name
  /// (spec §5.1). Distinct from `privateCodenames`: this set is derived from the plan/evidence
  /// state, not hand-configured.
  public let knownIds: Set<String>

  public init(
    scopes: any ModuleScopeResolving, flows: [String]? = nil, privateCodenames: [String] = [],
    vendorModules: [String] = [], knownIds: Set<String> = []
  ) {
    self.scopes = scopes
    self.flows = flows
    self.privateCodenames = privateCodenames
    self.vendorModules = Set(vendorModules)
    self.knownIds = knownIds
  }
}

public protocol Rule: Sendable {
  var descriptor: RuleDescriptor { get }
  var scope: RuleScope { get }
  /// Examines every in-scope file of a run at once, for rules that compare files (duplicates).
  func check(_ units: [SourceUnit], context: RuleContext) -> [RuleViolation]
}

/// A rule that examines one file at a time.
public protocol FileRule: Rule {
  func check(_ unit: SourceUnit, context: RuleContext) -> [RuleViolation]
}

extension FileRule {
  public func check(_ units: [SourceUnit], context: RuleContext) -> [RuleViolation] {
    units.flatMap { check($0, context: context) }
  }
}
