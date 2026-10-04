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
      switch self {
      case .live:
        break
      case .fixedFact:
        dependencies.apiClient.randomFact = { Fact(text: Self.fixedFactText) }
      }
    }

    /// The scenario named after `-harness-scenario` in `arguments`, or nil when the flag is absent.
    /// An unknown name reports an issue and yields `.live`, so a typo shows instead of passing silently.
    static func selected(by arguments: [String]) -> Scenario? {
      guard let flag = arguments.firstIndex(of: "-harness-scenario") else { return nil }
      let nameIndex = arguments.index(after: flag)
      guard nameIndex < arguments.endIndex else {
        reportIssue("-harness-scenario needs a name; launching live")
        return .live
      }
      let name = arguments[nameIndex]
      guard let scenario = Scenario(rawValue: name) else {
        reportIssue(
          "Unknown scenario \"\(name)\"; expected one of "
            + "\(allCases.map(\.rawValue).joined(separator: ", ")). Launching live")
        return .live
      }
      return scenario
    }
  }
#endif
