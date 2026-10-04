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
    nil
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
    false
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

  /// `Scenario.swift` in the entry point's directory.
  public static func path(beside entryPoint: AppEntryPoint) -> String {
    guard let slash = entryPoint.path.lastIndex(of: "/") else { return fileName }
    return "\(entryPoint.path[..<slash])/\(fileName)"
  }
}
