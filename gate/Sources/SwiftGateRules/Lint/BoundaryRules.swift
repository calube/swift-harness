import SwiftSyntax

/// IO, vendor SDKs and direct logging kept inside their `*Live` modules (standards D3, D5, O3).
enum BoundaryRules {
  static let all: [any Rule] = [
    urlSessionShared, vendorModule, directLogger, directSignposter, print,
  ]

  static let urlSessionShared = SyntaxLintRule(
    id: "client.urlsession-shared", summary: "URLSession.shared outside a Live module",
    scope: LintScopes.outsideLive
  ) { unit, index, _ in
    index.memberAccesses.filter {
      $0.declName.baseName.text == "shared" && $0.base?.refersToType("URLSession") == true
    }.map {
      unit.violation(
        at: $0,
        message: "`URLSession.shared` belongs in a `*Live` module; depend on the client interface",
        failureScenario: "tests hit the real network because the transport cannot be replaced")
    }
  }

  static let vendorModule = SyntaxLintRule(
    id: "client.vendor-module", summary: "vendor SDK imported outside a Live module",
    scope: LintScopes.outsideLive
  ) { unit, index, context in
    index.imports.compactMap { decl -> RuleViolation? in
      guard let module = decl.path.first?.name.text, context.vendorModules.contains(module)
      else { return nil }
      return unit.violation(
        at: decl,
        message: "`\(module)` is a vendor SDK; import it only in a `*Live` module",
        failureScenario: "the module can't build or be tested without the vendor SDK")
    }
  }

  static let directLogger = SyntaxLintRule(
    id: "obs.direct-logger", summary: "OSLog used directly outside LogClientLive",
    scope: LintScopes.outsideObservabilityLive
  ) { unit, index, _ in
    index.calls.filter {
      $0.constructs("Logger") || $0.constructs("OSLog") || $0.callsFreeFunction(in: ["os_log"])
    }.map {
      unit.violation(
        at: $0, message: "log through `@Dependency(\\.logClient)`, not OSLog directly",
        failureScenario: "logs skip privacy classification and never reach the remote backends")
    }
  }

  static let directSignposter = SyntaxLintRule(
    id: "obs.direct-signposter", summary: "signposts used directly outside TracingClientLive",
    scope: LintScopes.outsideObservabilityLive
  ) { unit, index, _ in
    index.calls.filter {
      $0.constructs("OSSignposter") || $0.callsFreeFunction(in: ["os_signpost"])
    }.map {
      unit.violation(
        at: $0, message: "trace through `@Dependency(\\.tracingClient)`, not OSSignposter",
        failureScenario: "spans are missing from remote traces")
    }
  }

  static let print = SyntaxLintRule(
    id: "obs.print", summary: "console printing outside LogClientLive",
    scope: LintScopes.outsideObservabilityLive
  ) { unit, index, _ in
    index.calls.filter { $0.callsFreeFunction(in: ["print", "debugPrint", "dump", "NSLog"]) }.map {
      unit.violation(
        at: $0, message: "log through `@Dependency(\\.logClient)` instead of printing",
        failureScenario: "the message is lost in production and unredacted in device logs")
    }
  }
}
