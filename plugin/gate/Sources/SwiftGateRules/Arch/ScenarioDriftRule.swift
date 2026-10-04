import SwiftGateDomain
import SwiftSyntax

/// Simulator QA design §6: the app's `enum Scenario: String` and `.swiftgate.toml`'s
/// `[[scenarios]]` name the same scenarios, so `sim up --scenario` never accepts a name the app
/// ignores, nor misses one the app declares.
public enum ScenarioDriftRule {
  public static let id = "sim.scenario-drift"

  /// - Parameter sources: every Swift file the run read; files under a `packages` glob are
  ///   skipped, since the enum belongs to the app target.
  public static func evaluate(config: Config, sources: [SourceInput])
    throws(ReportContractViolation) -> [Finding]
  {
    let enums = sources.filter { !inPackage($0.path, globs: config.packages) }
      .flatMap(scenarioEnums(in:))
    let configured = config.scenarios.map(\.name)
    if enums.count > 1 {
      return [
        try finding(
          file: enums[0].path, line: enums[0].line,
          message:
            "\(enums.count) `enum Scenario: String` declarations outside `packages` ("
            + enums.map { "\($0.path):\($0.line)" }.joined(separator: ", ")
            + "); keep 1 in the app target so its cases are the one list `[[scenarios]]` mirrors")
      ]
    }
    guard let declared = enums.first else {
      guard !configured.isEmpty else { return [] }
      return [
        try finding(
          file: Config.fileName, line: nil,
          message:
            "`[[scenarios]]` lists \(quoted(configured)) but no `enum Scenario: String` exists "
            + "outside `packages`; declare it in the app target with those cases, or remove the "
            + "entries")
      ]
    }
    let configOnly = configured.filter { !declared.rawValues.contains($0) }
    let enumOnly = declared.rawValues.filter { !configured.contains($0) }
    guard !configOnly.isEmpty || !enumOnly.isEmpty else { return [] }
    var sides: [String] = []
    if !configOnly.isEmpty {
      sides.append("only in `[[scenarios]]`: \(quoted(configOnly))")
    }
    if !enumOnly.isEmpty {
      sides.append("only in the enum: \(quoted(enumOnly))")
    }
    return [
      try finding(
        file: declared.path, line: declared.line,
        message:
          "`enum Scenario` and `[[scenarios]]` in \(Config.fileName) differ, "
          + sides.joined(separator: "; ")
          + "; add each missing case or entry, or remove it from the side that has it")
    ]
  }

  private static func finding(file: String, line: Int?, message: String)
    throws(ReportContractViolation) -> Finding
  {
    try Finding(
      ruleID: id, severity: .major, file: file, line: line, message: message,
      failureScenario:
        "`sim up --scenario` accepts a name the app launches live with, or an app scenario no "
        + "agent can select")
  }

  private static func quoted(_ names: [String]) -> String {
    names.map { "`\($0)`" }.joined(separator: ", ")
  }

  /// A file is in a package when some prefix of its directories matches a `packages` glob.
  private static func inPackage(_ path: String, globs: [String]) -> Bool {
    let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
    guard components.count > 1 else { return false }
    return globs.contains { glob in
      (1..<components.count).contains { count in
        PackageGlob.matches(glob, components.prefix(count).joined(separator: "/"))
      }
    }
  }

  struct Declaration {
    let path: String
    let line: Int
    let rawValues: [String]
  }

  static func scenarioEnums(in source: SourceInput) -> [Declaration] {
    guard source.text.contains("Scenario") else { return [] }
    let unit = SourceUnit(input: source, scope: nil)
    let finder = EnumFinder(viewMode: .sourceAccurate)
    finder.walk(unit.tree)
    return finder.found.map { declaration in
      Declaration(
        path: source.path, line: unit.line(of: declaration.positionAfterSkippingLeadingTrivia),
        rawValues: rawValues(of: declaration))
    }
  }

  /// A case's raw value is its string literal, or its name when it has none.
  private static func rawValues(of declaration: EnumDeclSyntax) -> [String] {
    rawValues(in: declaration.memberBlock.members)
  }

  /// Cases inside an `#if` count in every branch: the config can't say which build is meant.
  private static func rawValues(in members: MemberBlockItemListSyntax) -> [String] {
    members.flatMap { member -> [String] in
      if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
        return ifConfig.clauses.flatMap { clause -> [String] in
          guard case .decls(let nested) = clause.elements else { return [] }
          return rawValues(in: nested)
        }
      }
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { return [] }
      return caseDecl.elements.map { element in
        if let literal = element.rawValue?.value.as(StringLiteralExprSyntax.self),
          let value = literal.representedLiteralValue
        {
          return value
        }
        return element.name.identifier?.name ?? element.name.text
      }
    }
  }

  private final class EnumFinder: SyntaxVisitor {
    var found: [EnumDeclSyntax] = []

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
      let rawType = node.inheritanceClause?.inheritedTypes.first?.type
        .as(IdentifierTypeSyntax.self)?.name.text
      if node.name.text == "Scenario", rawType == "String" {
        found.append(node)
      }
      return .visitChildren
    }
  }
}
