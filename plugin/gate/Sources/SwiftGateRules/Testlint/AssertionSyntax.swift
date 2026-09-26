import SwiftSyntax

/// Recognises assertion constructs by syntax. An assertion is any construct that can fail a test:
/// `#expect`/`#require`, `XCTAssert*`/`XCTUnwrap`/`XCTFail`, `Issue.record`, `confirmation`,
/// TestStore `send`/`receive`, and free or member functions named `assert…`/`expect…`
/// (`assertSnapshot`, `expectNoDifference`, project helpers).
enum AssertionSyntax {
  static func isAssertion(_ node: Syntax) -> Bool {
    if let macro = node.as(MacroExpansionExprSyntax.self) {
      return ["expect", "require"].contains(macro.macroName.text)
    }
    guard let call = node.as(FunctionCallExprSyntax.self), let callee = call.callee else {
      return false
    }
    return isAssertionCall(base: callee.base, name: callee.name)
  }

  static func isAssertionCall(base: String?, name: String) -> Bool {
    if name.hasPrefix("XCTAssert") || name == "XCTUnwrap" || name == "XCTFail" { return true }
    if base == "Issue", name == "record" { return true }
    if base == nil, name == "confirmation" { return true }
    if name == "send" || name == "receive",
      let base, base.lowercased().hasSuffix("store")
    {
      return true
    }
    return name.hasPrefix("assert") || name.hasPrefix("expect")
  }

  /// Assertions in `node`'s subtree, outermost only (an `#expect` inside a helper closure passed
  /// to another assertion counts once).
  static func assertions(in node: some SyntaxProtocol) -> [Syntax] {
    var found: [Syntax] = []
    var stack = Array(node.children(viewMode: .sourceAccurate).reversed())
    while let current = stack.popLast() {
      if isAssertion(current) {
        found.append(current)
        continue
      }
      stack.append(contentsOf: current.children(viewMode: .sourceAccurate).reversed())
    }
    return found
  }

  /// Calls in `node` to functions named in `names` (file-local helpers that assert).
  static func callsHelper(in node: some SyntaxProtocol, named names: Set<String>) -> Bool {
    node.descendants(of: FunctionCallExprSyntax.self).contains { call in
      guard let callee = call.callee else { return false }
      return (callee.base == nil || callee.base == "self") && names.contains(callee.name)
    }
  }

  /// The arguments of an assertion, whichever form it takes.
  static func arguments(of assertion: Syntax) -> LabeledExprListSyntax? {
    if let macro = assertion.as(MacroExpansionExprSyntax.self) { return macro.arguments }
    return assertion.as(FunctionCallExprSyntax.self)?.arguments
  }

  static func name(of assertion: Syntax) -> String {
    if let macro = assertion.as(MacroExpansionExprSyntax.self) { return "#" + macro.macroName.text }
    return assertion.as(FunctionCallExprSyntax.self)?.callee?.name ?? ""
  }

  /// Splits `a == b` (or `===`, `>=`, `<=`, `!=`) at its only comparison operator. The parser
  /// leaves binary expressions unfolded, so this works on the flat sequence.
  static func comparison(_ expression: ExprSyntax) -> (
    left: String, op: String, right: String
  )? {
    let unwrapped =
      expression.as(TupleExprSyntax.self).flatMap { tuple in
        tuple.elements.count == 1 ? tuple.elements.first?.expression : nil
      } ?? expression
    guard let sequence = unwrapped.as(SequenceExprSyntax.self) else { return nil }
    let elements = Array(sequence.elements)
    let comparisons = elements.indices.filter { index in
      guard let op = elements[index].as(BinaryOperatorExprSyntax.self) else { return false }
      return ["==", "===", "!=", "!==", ">=", "<=", ">", "<"].contains(op.operator.text)
    }
    guard comparisons.count == 1, let index = comparisons.first,
      let op = elements[index].as(BinaryOperatorExprSyntax.self)
    else { return nil }
    let left = elements[..<index].map(\.trimmedDescription).joined(separator: " ")
    let right = elements[(index + 1)...].map(\.trimmedDescription).joined(separator: " ")
    return (left, op.operator.text, right)
  }
}
