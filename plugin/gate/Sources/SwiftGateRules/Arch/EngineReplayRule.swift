import SwiftGateDomain

/// Spec §7.2 rule 8: every module declared `kind = "engine"` has a replay test (seed plus input
/// log gives an identical final state across runs).
///
/// Whether a test replays cannot be read from syntax, so the rule uses a naming heuristic: among
/// the test targets that depend on the engine, some test function's name or `@Test` display name
/// contains "replay" (any case). The name is the contract a reviewer checks; the rule only makes
/// its absence impossible to miss.
public enum EngineReplayRule {
  public static let id = "arch.engine-replay-test"

  public static func evaluate(graph: ModuleGraph, sources: [SourceInput])
    throws(ReportContractViolation) -> [Finding]
  {
    let engines = graph.modules.filter { module in
      guard module.kind == .engine else { return false }
      if case .tests = module.role { return false }
      return true
    }
    guard !engines.isEmpty else { return [] }
    let testModules = graph.modules.filter { module in
      if case .tests = module.role { return true }
      return false
    }
    let testModuleNames = Set(testModules.map(\.name))
    var replayingModules = Set<String>()
    for source in sources {
      guard let module = graph.module(containingFile: source.path),
        testModuleNames.contains(module.name), !replayingModules.contains(module.name)
      else { continue }
      let unit = SourceUnit(input: source, scope: module.scope)
      if TestFunction.all(in: unit).contains(where: mentionsReplay) {
        replayingModules.insert(module.name)
      }
    }
    var findings: [Finding] = []
    for engine in engines {
      let covering = testModules.filter { $0.dependencies.contains(engine.name) }
      guard !covering.contains(where: { replayingModules.contains($0.name) }) else { continue }
      findings.append(
        try Finding(
          ruleID: id, severity: .major, file: engine.path, line: nil,
          message:
            "engine module \(engine.name) has no replay test: add a test that runs a seed and an "
            + "input log twice and expects identical final state, with \"replay\" in its name or "
            + "display name",
          failureScenario: "hidden nondeterminism makes recorded games diverge on replay"))
    }
    return findings
  }

  static func mentionsReplay(_ test: TestFunction) -> Bool {
    if test.name.lowercased().contains("replay") { return true }
    return test.testAttribute.flatMap(ChangedTestDiscovery.displayName(of:))?.lowercased()
      .contains("replay") ?? false
  }
}
