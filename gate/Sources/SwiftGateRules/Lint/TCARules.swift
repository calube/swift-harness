import SwiftSyntax

/// Banned TCA and snapshot-testing APIs (standards A6) and implicit snapshot recording (testing
/// playbook). Matching is limited to files that import the library, so same-named types elsewhere
/// (`TaskResult`, `isRecording`, SwiftUI's `.animation`) are not mistaken for it.
enum TCARules {
  static let all: [any Rule] = [bannedAPI, snapshotRecordMode]

  private static let bannedIdentifiers: Set<String> = [
    "ViewStore", "ViewStoreOf", "WithViewStore", "BindingViewState", "BindingViewStore",
    "TaskResult", "AnyCasePath",
  ]
  /// `@BindingState` is pre-observation; `@Feature` is the TCA 2.0 beta macro.
  private static let bannedAttributes: Set<String> = ["BindingState", "Feature"]
  /// Effect operators that only exist in the Combine-era API.
  private static let effectOperators: Set<String> = [
    "debounce", "throttle", "animation", "transaction", "map",
  ]
  /// Implicit-member effect constructors a chain of effect operators starts from.
  private static let effectRoots: Set<String> = [
    "run", "send", "merge", "concatenate", "none", "publisher",
  ]
  private static let snapshotGlobals: Set<String> = ["isRecording", "diffTool"]

  static let bannedAPI = SyntaxLintRule(
    id: "tca.banned-api", summary: "banned or deprecated TCA / snapshot API", scope: .allFiles
  ) { unit, index, _ in
    var hits: [(Syntax, String)] = []
    if unit.imports("ComposableArchitecture") {
      hits += tcaHits(index)
    }
    if unit.imports.contains(where: isSnapshotTestingModule) {
      for reference in index.references where snapshotGlobals.contains(reference.baseName.text) {
        if let member = reference.parent?.as(MemberAccessExprSyntax.self),
          member.declName.id == reference.id,
          member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text != "SnapshotTesting"
        {
          continue
        }
        hits.append(
          (
            Syntax(reference),
            "`\(reference.baseName.text)` is a deprecated global; use `withSnapshotTesting` or the `.snapshots` trait"
          ))
      }
    }
    return hits.map { node, message in
      unit.violation(
        at: node, message: message,
        failureScenario: "code built on a deprecated API breaks on the next TCA upgrade")
    }
  }

  private static func tcaHits(_ index: SyntaxIndex) -> [(Syntax, String)] {
    var hits: [(Syntax, String)] = []
    for reference in index.references where bannedIdentifiers.contains(reference.baseName.text) {
      hits.append((Syntax(reference), "`\(reference.baseName.text)` is a banned pre-1.x TCA API"))
    }
    for type in index.typeNames where bannedIdentifiers.contains(type.name.text) {
      hits.append((Syntax(type), "`\(type.name.text)` is a banned pre-1.x TCA API"))
    }
    for attribute in index.attributes
    where bannedAttributes.contains(attribute.attributeName.trimmedDescription) {
      hits.append(
        (
          Syntax(attribute),
          "`@\(attribute.attributeName.trimmedDescription)` is banned (pre-observation or TCA 2.0)"
        ))
    }
    for member in index.memberAccesses {
      let name = member.declName.baseName.text
      if name == "publisher", let base = member.base,
        lastIdentifier(of: base)?.lowercased()
          .hasSuffix("store") == true
      {
        hits.append((Syntax(member), "`store.publisher` is banned; observe state instead"))
      }
    }
    for call in index.calls {
      guard let name = call.calledName else { continue }
      let labels = call.argumentLabels
      switch name {
      case "scope" where labels.first == "state", "Scope" where labels.first == "state":
        hits.append(
          (
            Syntax(call),
            "`\(name)(state:action:)` is deprecated; use the unlabelled `\(name)(_:action:)`"
          ))
      case "send" where labels.count >= 2 && labels[1] == "animation":
        hits.append(
          (
            Syntax(call),
            "`send(_:animation:)` is deprecated; use `withAnimation { _ = store.send(action) }`"
          ))
      case "withState" where call.calledMember != nil:
        hits.append((Syntax(call), "`withState` is banned; read state from the store directly"))
      case "concatenate" where call.calledMember != nil:
        hits.append((Syntax(call), "`Effect.concatenate` is banned; sequence work inside `.run`"))
      case _ where effectOperators.contains(name):
        guard let base = call.calledMember?.base else { continue }
        let isTCAOperator =
          isEffectRooted(base)
          || ((name == "debounce" || name == "throttle") && labels.contains("id"))
        if isTCAOperator {
          hits.append((Syntax(call), "`Effect.\(name)` is a banned Combine-era effect operator"))
        }
      default:
        continue
      }
    }
    return hits
  }

  /// Follows a chain of calls and member accesses back to where it starts: an implicit effect
  /// constructor (`.run`, `.send`) or the `Effect` type.
  private static func isEffectRooted(_ expression: ExprSyntax) -> Bool {
    var current = expression
    while true {
      if let call = current.as(FunctionCallExprSyntax.self) {
        current = call.calledExpression
      } else if let member = current.as(MemberAccessExprSyntax.self) {
        guard let base = member.base else {
          return effectRoots.contains(member.declName.baseName.text)
        }
        if base.refersToType("Effect") || base.refersToType("EffectOf") { return true }
        current = base
      } else {
        return false
      }
    }
  }

  private static func lastIdentifier(of expression: ExprSyntax) -> String? {
    if let reference = expression.as(DeclReferenceExprSyntax.self) {
      return reference.baseName.text
    }
    return expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
  }

  static func isSnapshotTestingModule(_ module: String) -> Bool {
    module.contains("SnapshotTesting")
  }

  static let snapshotRecordMode = SyntaxLintRule(
    id: "snap.record-mode", summary: "snapshot record mode other than .never or nil",
    scope: .allFiles
  ) { unit, index, _ in
    guard unit.imports.contains(where: isSnapshotTestingModule) else { return [] }
    return index.calls.flatMap { call in
      call.arguments.filter { argument in
        guard argument.label?.text == "record" else { return false }
        let value = argument.expression
        if value.is(NilLiteralExprSyntax.self) { return false }
        return value.as(MemberAccessExprSyntax.self)?.declName.baseName.text != "never"
      }
    }.map {
      unit.violation(
        at: $0,
        message:
          "`\($0.trimmedDescription)` records references in the test run; only "
          + "`swiftgate snapshots record` may record",
        failureScenario:
          "a missing or changed reference is silently re-recorded and the test passes")
    }
  }
}
