#if DEBUG
  import APIClient
  import ComposableArchitecture

  /// A named set of dependency overrides the app launches with when it gets
  /// `-harness-scenario <rawValue>`. Agents and UI tests select the same cases, and
  /// `.swiftgate.toml`'s `[[scenarios]]` lists the same names.
  enum Scenario: String, CaseIterable {
    case live
    case fixedFact = "fixed-fact"

    static let fixedFactText = "A group of cats is called a clowder."

    func apply(to dependencies: inout DependencyValues) {
    }
  }
#endif
