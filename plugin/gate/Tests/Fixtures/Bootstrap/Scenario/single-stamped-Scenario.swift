#if DEBUG
  import Dependencies
  import Foundation

  /// A named set of dependency overrides the app launches with when it gets
  /// `-harness-scenario <rawValue>`. Agents (`swiftgate sim up --scenario`) and UI tests select
  /// the same cases, and `.swiftgate.toml`'s `[[scenarios]]` lists the same names; `swiftgate arch`
  /// fails when the two lists differ. Add a case, its overrides in `apply(to:)`, and its
  /// `[[scenarios]]` entry together.
  enum Scenario: String, CaseIterable {
    case live

    func apply(to dependencies: inout DependencyValues) {
      switch self {
      case .live:
        break
      }
    }

    /// Applies the scenario the launch arguments name. Call it first in the app's `init()`:
    /// `prepareDependencies` must run before the first store exists, or the store keeps live
    /// values.
    static func prepareFromLaunchArguments() {
      guard let scenario = selected(by: ProcessInfo.processInfo.arguments) else { return }
      prepareDependencies { scenario.apply(to: &$0) }
    }

    /// The scenario named after `-harness-scenario` in `arguments`, or nil when the flag is absent.
    /// An unknown name reports an issue and yields `.live`, so a typo shows instead of passing
    /// silently.
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
#else
  /// Release builds launch with live dependencies only; this keeps the app's one-line call.
  enum Scenario {
    static func prepareFromLaunchArguments() {}
  }
#endif
