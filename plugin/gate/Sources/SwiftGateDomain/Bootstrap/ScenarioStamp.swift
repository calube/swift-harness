import Foundation

/// A Swift file outside `packages` that declares `@main` on a SwiftUI `App`.
public struct AppEntryPoint: Sendable, Equatable {
  /// Repository-relative.
  public let path: String
  public let typeName: String

  public init(path: String, typeName: String) {
    self.path = path
    self.typeName = typeName
  }

  /// The `@main … : App` type `text` declares, or nil when it declares none.
  public static func scan(path: String, text: String) -> AppEntryPoint? {
    let declaration =
      /@main\b(?:\s+@\w+(?:\([^)]*\))?)*\s+(?:(?:public|internal|package|fileprivate|private|final|open)\s+)*(?:struct|class|enum|actor)\s+(\w+)\s*:\s*([^{]*)\{/
    for match in text.matches(of: declaration) {
      let inherited = match.output.2.split(separator: ",").map {
        $0.split(separator: " ").first.map(String.init) ?? ""
      }
      if inherited.contains(where: { $0 == "App" || $0 == "SwiftUI.App" }) {
        return AppEntryPoint(path: path, typeName: String(match.output.1))
      }
    }
    return nil
  }
}

/// What the Swift files outside `packages` hold that the scenario stamp decides from.
public struct AppSources: Sendable, Equatable {
  public var entryPoints: [AppEntryPoint]
  /// Repository-relative files that already declare a type named `Scenario`.
  public var scenarioDeclarations: [String]

  public init(entryPoints: [AppEntryPoint] = [], scenarioDeclarations: [String] = []) {
    self.entryPoints = entryPoints
    self.scenarioDeclarations = scenarioDeclarations
  }

  /// Whether `text` declares a type named `Scenario`, which a stamped one would collide with.
  public static func declaresScenario(_ text: String) -> Bool {
    text.contains(/\b(?:enum|struct|class|actor|typealias)\s+Scenario\b/)
  }
}

/// The dependency scenario enum bootstrap stamps beside a single app entry point (simulator QA
/// design §6), and the `[[scenarios]]` entry that mirrors its one case.
public enum ScenarioStamp {
  public static let fileName = "Scenario.swift"
  public static let live = Scenario(
    name: "live", reason: "the app's own live dependencies, as it ships")
  /// The line the app's `init()` needs; bootstrap never edits app source.
  public static let call = "Scenario.prepareFromLaunchArguments()"

  /// `[[scenarios]]` tables for `scenarios`, or `live` as a commented example when it is empty.
  public static func tables(_ scenarios: [Scenario]) -> String {
    guard !scenarios.isEmpty else {
      return tables([live]).split(separator: "\n", omittingEmptySubsequences: false)
        .map { "# \($0)" }.joined(separator: "\n")
    }
    return scenarios.map { scenario in
      "[[scenarios]]\nname = \(quoted(scenario.name))\nreason = \(quoted(scenario.reason))"
    }.joined(separator: "\n\n")
  }

  private static func quoted(_ value: String) -> String {
    "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
  }

  /// What bootstrap writes and says about scenarios: the `Scenario.swift` stamp and its config
  /// entry only for a single entry point in a repository without a config, a "consider" note when
  /// it can't stamp, and nothing once the app declares a `Scenario` of its own.
  static func plan(_ inputs: BootstrapInputs) -> (
    stamp: Stamp?, scenarios: [Scenario], notes: [String]
  ) {
    let sources = inputs.appSources
    let entryPoints = sources.entryPoints
    let stampExists = entryPoints.contains {
      (inputs.existing[path(beside: $0)] ?? .absent) != .absent
    }
    guard sources.scenarioDeclarations.isEmpty, !stampExists else { return (nil, [], []) }
    if inputs.config == .absent, entryPoints.count == 1 {
      let entryPoint = entryPoints[0]
      let target = path(beside: entryPoint)
      return (
        Stamp(path: target, change: .create(inputs.templates.scenario)), [live],
        [
          "\(target): add `\(call)` as the first line of `\(entryPoint.typeName).init()` in "
            + "\(entryPoint.path) (add an `init()` if it has none); bootstrap never edits app "
            + "source"
        ]
      )
    }
    let reason: String
    let target: String
    switch entryPoints.count {
    case 0:
      reason = "no `@main … : App` file outside packages, so no \(fileName) was stamped"
      target = "\(fileName) beside the app's `@main` file"
    case 1:
      reason = "\(Config.fileName) already exists and bootstrap never rewrites it"
      target = path(beside: entryPoints[0])
    default:
      reason =
        "\(entryPoints.count) `@main … : App` files outside packages ("
        + entryPoints.map(\.path).joined(separator: ", ")
        + "); bootstrap stamps \(fileName) only beside a single one"
      target = "\(fileName) beside the app target's `@main` file"
    }
    func indented(_ text: String) -> String {
      text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "      \($0)" }.joined(separator: "\n")
    }
    let template = inputs.templates.scenario
    let note =
      "consider: dependency scenarios for `swiftgate sim up --scenario`: \(reason). To adopt them, "
      + "create \(target) with:\n"
      + indented(template.hasSuffix("\n") ? String(template.dropLast()) : template)
      + "\n    add to \(Config.fileName):\n" + indented(tables([live]))
      + "\n    and add `\(call)` as the first line of the app's `init()`."
    return (nil, [], [note])
  }

  /// `Scenario.swift` in the entry point's directory.
  public static func path(beside entryPoint: AppEntryPoint) -> String {
    guard let slash = entryPoint.path.lastIndex(of: "/") else { return fileName }
    return "\(entryPoint.path[..<slash])/\(fileName)"
  }
}
