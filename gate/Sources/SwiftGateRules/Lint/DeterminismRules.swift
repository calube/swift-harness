import SwiftSyntax

/// Nondeterminism read directly instead of through a dependency (standards D1, G1).
enum DeterminismRules {
  static let all: [any Rule] = [dateInit, uuidInit, taskSleep, asyncAfter, random]

  private static let scenario =
    "a test's outcome depends on the wall clock or the run instead of the code"

  static let dateInit = SyntaxLintRule(
    id: "det.date-init", summary: "wall-clock Date read in Core or a client interface",
    scope: LintScopes.coreAndInterfaces
  ) { unit, index, _ in
    let constructions = index.calls.filter { call in
      guard call.constructs("Date") else { return false }
      return call.hasNoArguments || call.argumentLabels == ["timeIntervalSinceNow"]
    }
    let nowReads = index.memberAccesses.filter {
      $0.declName.baseName.text == "now" && $0.base?.refersToType("Date") == true
    }
    return (constructions.map(Syntax.init) + nowReads.map(Syntax.init)).map {
      unit.violation(
        at: $0, message: "reads the wall clock; use `@Dependency(\\.date.now)`",
        failureScenario: scenario)
    }
  }

  static let uuidInit = SyntaxLintRule(
    id: "det.uuid-init", summary: "random UUID in Core or a client interface",
    scope: LintScopes.coreAndInterfaces
  ) { unit, index, _ in
    index.calls.filter { $0.constructs("UUID") && $0.hasNoArguments }.map {
      unit.violation(
        at: $0, message: "`UUID()` is random; use `@Dependency(\\.uuid)`",
        failureScenario: scenario)
    }
  }

  static let taskSleep = SyntaxLintRule(
    id: "det.task-sleep", summary: "real-time sleep in Core or a client interface",
    scope: LintScopes.coreAndInterfaces
  ) { unit, index, _ in
    index.calls.filter { call in
      guard let member = call.calledMember, member.declName.baseName.text == "sleep",
        let base = member.base
      else { return false }
      return base.refersToType("Task") || base.refersToType("Thread")
    }.map {
      unit.violation(
        at: $0, message: "sleeps in real time; use `@Dependency(\\.continuousClock)`",
        failureScenario: "tests wait real time and time out or flake under load")
    }
  }

  static let asyncAfter = SyntaxLintRule(
    id: "det.async-after", summary: "DispatchQueue.asyncAfter in Core or a client interface",
    scope: LintScopes.coreAndInterfaces
  ) { unit, index, _ in
    index.calls.filter { $0.calledMember?.declName.baseName.text == "asyncAfter" }.map {
      unit.violation(
        at: $0, message: "`asyncAfter` cannot be driven by a TestClock; sleep on an injected clock",
        failureScenario: "tests wait real time and time out or flake under load")
    }
  }

  private static let generatorMethods: Set<String> = [
    "random", "randomElement", "shuffled", "shuffle",
  ]
  private static let cRandomFunctions: Set<String> = [
    "arc4random", "arc4random_uniform", "arc4random_buf", "drand48",
  ]

  static let random = SyntaxLintRule(
    id: "det.random", summary: "unseeded randomness in Core or a client interface",
    scope: LintScopes.coreAndInterfaces
  ) { unit, index, _ in
    let unseeded = index.calls.filter { call in
      if call.callsFreeFunction(in: cRandomFunctions) { return true }
      guard let member = call.calledMember,
        generatorMethods.contains(member.declName.baseName.text)
      else { return false }
      return !call.argumentLabels.contains("using")
    }
    let systemGenerator =
      index.references.filter { $0.baseName.text == "SystemRandomNumberGenerator" }
      .map(Syntax.init)
      + index.typeNames.filter { $0.name.text == "SystemRandomNumberGenerator" }.map(Syntax.init)
    return (unseeded.map(Syntax.init) + systemGenerator).map {
      unit.violation(
        at: $0,
        message:
          "unseeded randomness; pass `using:` a generator from `@Dependency(\\.withRandomNumberGenerator)`",
        failureScenario: "a replay of the same inputs produces a different state")
    }
  }
}
