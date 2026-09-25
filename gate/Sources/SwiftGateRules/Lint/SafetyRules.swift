import SwiftSyntax

/// Escape hatches that need a same-line `swiftgate:allow <id> — <reason>` (standards C2, E2). The
/// rules flag every use; the engine waives the ones that carry a reason.
enum SafetyRules {
  static let all: [any Rule] = [
    tryBang, asBang, uncheckedSendable, nonisolatedUnsafe, preconcurrency, fatalError,
  ]

  private static func allowHint(_ id: String) -> String {
    "or add `// swiftgate:allow \(id) — <why this cannot fail>` on the same line"
  }

  static let tryBang = SyntaxLintRule(
    id: "safety.try-bang", summary: "try! without a reason", scope: .allFiles
  ) { unit, index, _ in
    index.forceTries.map {
      unit.violation(
        atStartOf: $0,
        message: "`try!` crashes on error; handle it, \(allowHint("safety.try-bang"))",
        failureScenario: "an unexpected input crashes the app")
    }
  }

  static let asBang = SyntaxLintRule(
    id: "safety.as-bang", summary: "as! without a reason", scope: .allFiles
  ) { unit, index, _ in
    index.forceCasts.map {
      unit.violation(
        at: $0,
        message: "`as!` crashes on a type mismatch; use `as?`, \(allowHint("safety.as-bang"))",
        failureScenario: "an unexpected type crashes the app")
    }
  }

  static let uncheckedSendable = SyntaxLintRule(
    id: "safety.unchecked-sendable", summary: "@unchecked Sendable without a reason",
    scope: .allFiles
  ) { unit, index, _ in
    index.attributes.filter { $0.attributeName.trimmedDescription == "unchecked" }.map {
      unit.violation(
        at: $0,
        message:
          "`@unchecked Sendable` turns off data-race checking; fix the isolation, "
          + allowHint("safety.unchecked-sendable"),
        failureScenario: "a data race the compiler would have caught corrupts state")
    }
  }

  static let nonisolatedUnsafe = SyntaxLintRule(
    id: "safety.nonisolated-unsafe", summary: "nonisolated(unsafe) without a reason",
    scope: .allFiles
  ) { unit, index, _ in
    index.modifiers.filter { $0.name.text == "nonisolated" && $0.detail?.detail.text == "unsafe" }
      .map {
        unit.violation(
          at: $0,
          message:
            "`nonisolated(unsafe)` turns off data-race checking; fix the isolation, "
            + allowHint("safety.nonisolated-unsafe"),
          failureScenario: "a data race the compiler would have caught corrupts state")
      }
  }

  static let preconcurrency = SyntaxLintRule(
    id: "safety.preconcurrency", summary: "@preconcurrency without a reason", scope: .allFiles
  ) { unit, index, _ in
    index.attributes.filter { $0.attributeName.trimmedDescription == "preconcurrency" }.map {
      unit.violation(
        at: $0,
        message:
          "`@preconcurrency` hides Sendable diagnostics; \(allowHint("safety.preconcurrency"))",
        failureScenario: "a data race the compiler would have caught corrupts state")
    }
  }

  static let fatalError = SyntaxLintRule(
    id: "safety.fatal-error", summary: "fatalError or preconditionFailure without a reason",
    scope: LintScopes.productionFiles
  ) { unit, index, _ in
    index.calls.filter { $0.callsFreeFunction(in: ["fatalError", "preconditionFailure"]) }.map {
      unit.violation(
        at: $0,
        message:
          "crashes users; use `reportIssue` or a typed error, "
          + allowHint("safety.fatal-error"),
        failureScenario: "input that reaches this path crashes the app")
    }
  }
}
