import SwiftGateDomain
import SwiftParser
import SwiftSyntax

/// Reads the identifiers an app declares in its typed accessibility-id module: the raw values of
/// its 1 `enum AccessibilityID: String` (simulator QA amendment decision 17).
public enum AccessibilityIDReader {
  public static let enumName = "AccessibilityID"

  /// - Parameter path: the file's repo-relative path, which errors name.
  /// - Throws: when the source doesn't parse, declares no such enum or more than 1, or holds a
  ///   case whose raw value isn't a plain string literal.
  public static func read(source: String, path: String) throws(AccessibilityIDReaderError)
    -> Set<String>
  {
    func fail(_ reason: String) -> AccessibilityIDReaderError {
      AccessibilityIDReaderError(path: path, reason: reason)
    }
    let tree = Parser.parse(source: source)
    if tree.hasError { throw fail("SwiftParser finds a syntax error") }
    let finder = EnumFinder(name: enumName)
    finder.walk(tree)
    guard finder.found.count == 1, let declaration = finder.found.first else {
      throw fail(
        finder.found.isEmpty
          ? "it declares no `enum \(enumName): String`"
          : "it declares `enum \(enumName)` \(finder.found.count) times; keep 1")
    }
    let raw = declaration.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription
    guard raw == "String" || raw == "Swift.String" else {
      throw fail("`enum \(enumName)` isn't backed by `String`, so its cases have no string ids")
    }
    return Set(try rawValues(in: declaration.memberBlock.members, fail: fail))
  }

  /// A case's raw value is its string literal, or its name when it has none. Cases inside an
  /// `#if` count in every branch: a flow may run against any build.
  private static func rawValues(
    in members: MemberBlockItemListSyntax,
    fail: (String) -> AccessibilityIDReaderError
  ) throws(AccessibilityIDReaderError) -> [String] {
    var values: [String] = []
    for member in members {
      if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
        for clause in ifConfig.clauses {
          guard case .decls(let nested) = clause.elements else { continue }
          values += try rawValues(in: nested, fail: fail)
        }
        continue
      }
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      for element in caseDecl.elements {
        guard let rawValue = element.rawValue else {
          values.append(element.name.text.replacingOccurrences(of: "`", with: ""))
          continue
        }
        guard let literal = rawValue.value.as(StringLiteralExprSyntax.self),
          let value = literal.representedLiteralValue
        else {
          throw fail(
            "case `\(element.name.text)`'s raw value `\(rawValue.value.trimmedDescription)` "
              + "isn't a plain string literal")
        }
        values.append(value)
      }
    }
    return values
  }
}

private final class EnumFinder: SyntaxVisitor {
  let name: String
  var found: [EnumDeclSyntax] = []

  init(name: String) {
    self.name = name
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    if node.name.text == name { found.append(node) }
    return .visitChildren
  }
}

/// Why the identifiers couldn't be read, naming the file.
public struct AccessibilityIDReaderError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { "\(path): \(reason)" }
}
