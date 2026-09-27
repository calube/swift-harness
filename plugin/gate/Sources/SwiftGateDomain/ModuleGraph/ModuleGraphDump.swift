/// The text `swiftgate module-graph` prints, which the design and plan skills pass to
/// `context-pack --module-graph`: SessionStart's module map, then one `<Target> -> <Dependency>`
/// line per target dependency. A research-lane pack keeps the lines naming a touched module, so
/// every edge names both ends on one line.
public enum ModuleGraphDump {
  /// Edges run over every module, test targets included, sorted by module then dependency. An
  /// external product (one no described package vends) is an edge too, named as the product.
  public static func lines(_ graph: ModuleGraph) -> [String] {
    let edges = graph.modules.flatMap { module in
      (module.dependencies + module.externalProducts).sorted().map { "\(module.name) -> \($0)" }
    }
    return SessionContext.moduleMapLines(SessionContext.moduleEntries(of: graph)) + edges
  }
}
