import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real, on-disk repository root: a `.swiftgate.toml` naming one package directory that holds
/// a placeholder `Package.swift` (its content is never parsed — `PackageDirectories` only checks
/// it exists; the manifest itself comes from `FakeSwiftPM`, so `ConfigLoader`,
/// `PackageDirectories` and `ModuleGraphLoader` all run for real against real files, without a
/// real `swift package describe` call).
private struct DesignScopeRepository {
  let root: URL

  static let packagePath = "Sample"

  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "Sample"
    packages = ["Sample"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """

  /// `Core` (kind `.feature`), `APIClient` and `APIClientLive` (kind `.client`): two existing
  /// kinds, so a new module can land on an existing kind or a genuinely new one.
  static func manifest() -> PackageManifest {
    PackageManifest(
      name: "Sample", path: packagePath,
      targets: [
        PackageTarget(name: "Core", type: .library, path: "\(packagePath)/Sources/Core"),
        PackageTarget(
          name: "APIClient", type: .library, path: "\(packagePath)/Sources/APIClient"),
        PackageTarget(
          name: "APIClientLive", type: .library, path: "\(packagePath)/Sources/APIClientLive",
          targetDependencies: ["APIClient"]),
      ])
  }

  init(withConfig: Bool = true) throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-design-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    let package = root.appending(path: Self.packagePath, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.2\n".utf8).write(
      to: package.appending(path: "Package.swift"))
    if withConfig {
      try Data(Self.config.utf8).write(to: root.appending(path: ConfigLoader.fileName))
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func frameAnswersFile(_ contents: String) throws -> URL {
    let url = root.appending(path: "frame-answers-\(UUID().uuidString).json")
    try Data(contents.utf8).write(to: url)
    return url
  }

  var swiftPM: FakeSwiftPM { FakeSwiftPM(serving: [Self.manifest()]) }
}

@Suite("swiftgate design-scope")
struct DesignScopeCommandTests {
  private static let unusedSwiftPM = FakeSwiftPM(serving: [])

  @Test(
    "no --frame-answers is a failure, never a default tier — catches a skill forgetting the flag")
  func missingFlagFails() async {
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: nil, root: FileManager.default.temporaryDirectory,
      swiftPM: Self.unusedSwiftPM)
    guard case .failed(let message) = outcome else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains("--frame-answers"))
  }

  @Test("an unreadable path is a failure, never a default tier")
  func unreadablePathFails() async {
    let missing = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-design-scope-missing-\(UUID().uuidString).json")
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: missing.path, root: FileManager.default.temporaryDirectory,
      swiftPM: Self.unusedSwiftPM)
    guard case .failed(let message) = outcome else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains(missing.path))
  }

  @Test("malformed JSON is a failure, never a default tier")
  func malformedJSONFails() async throws {
    let repository = try DesignScopeRepository()
    defer { repository.remove() }
    let file = try repository.frameAnswersFile("not json")
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: file.path, root: repository.root, swiftPM: repository.swiftPM)
    guard case .failed(let message) = outcome else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains(file.path))
  }

  @Test("no .swiftgate.toml is a failure naming the config file, never a default tier")
  func noConfigFails() async throws {
    let repository = try DesignScopeRepository(withConfig: false)
    defer { repository.remove() }
    let file = try repository.frameAnswersFile(
      """
      {"schemaVersion": 1, "touchedModules": [], "newModules": [], "newDependencies": []}
      """)
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: file.path, root: repository.root, swiftPM: repository.swiftPM)
    guard case .failed(let message) = outcome else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains(ConfigLoader.fileName))
  }

  @Test(
    "a touched module the real graph doesn't have is a failure naming it, never a default tier — proves the CLI checks against the real loader, not a hand-rolled count"
  )
  func touchedModuleNotInRealGraphFails() async throws {
    let repository = try DesignScopeRepository()
    defer { repository.remove() }
    let file = try repository.frameAnswersFile(
      """
      {"schemaVersion": 1, "touchedModules": ["Ghost"], "newModules": [], "newDependencies": []}
      """)
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: file.path, root: repository.root, swiftPM: repository.swiftPM)
    guard case .failed(let message) = outcome else {
      Issue.record("expected .failed")
      return
    }
    #expect(message.contains("Ghost"))
  }

  @Test(
    "a valid frame-answers file, checked against the real module graph, recommends a tier and echoes both the answers and the derived counts"
  )
  func validFileRecommends() async throws {
    let repository = try DesignScopeRepository()
    defer { repository.remove() }
    let file = try repository.frameAnswersFile(
      """
      {
        "schemaVersion": 1,
        "touchedModules": ["Core", "APIClient"],
        "newModules": [{"name": "Engine", "kind": "engine"}],
        "newDependencies": []
      }
      """)
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: file.path, root: repository.root, swiftPM: repository.swiftPM)
    guard case .recommended(let report) = outcome else {
      Issue.record("expected .recommended")
      return
    }
    // touches Core, APIClient and the new Engine: 3 modules; adds 1; Engine's kind (.engine) is
    // new to the graph (Core is .feature, APIClient/APIClientLive are .client).
    #expect(report.input.derived.modulesTouched == 3)
    #expect(report.input.derived.modulesAdded == 1)
    #expect(report.input.derived.addsModuleKind)
    #expect(!report.input.derived.addsDependency)
    #expect(report.input.answers.touchedModules == ["Core", "APIClient"])
    #expect(report.tier == .standard)
    #expect(report.reasons.map(\.code) == [.newModuleKind])

    // Renders (encodes) newModules too, not just fields read straight off the Swift value.
    let rendered = DesignScopeReport.render(report, format: .json)
    let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
    let newModules =
      (object?["input"] as? [String: Any])?["answers"] as? [String: Any]
    let engine = (newModules?["newModules"] as? [[String: Any]])?.first
    #expect(engine?["name"] as? String == "Engine")
    #expect(engine?["kind"] as? String == "engine")
  }

  @Test("the JSON report echoes both answers and derived facts under the documented keys")
  func jsonReportShape() async throws {
    let repository = try DesignScopeRepository()
    defer { repository.remove() }
    let file = try repository.frameAnswersFile(
      """
      {
        "schemaVersion": 1,
        "touchedModules": [],
        "newModules": [],
        "newDependencies": ["swift-algorithms"]
      }
      """)
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: file.path, root: repository.root, swiftPM: repository.swiftPM)
    guard case .recommended(let report) = outcome else {
      Issue.record("expected .recommended")
      return
    }
    let rendered = DesignScopeReport.render(report, format: .json)
    let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
    #expect(object?["command"] as? String == "design-scope")
    #expect(object?["tier"] as? String == "standard")
    let input = object?["input"] as? [String: Any]
    let answers = input?["answers"] as? [String: Any]
    #expect(answers?["newDependencies"] as? [String] == ["swift-algorithms"])
    let derived = input?["derived"] as? [String: Any]
    #expect(derived?["addsDependency"] as? Bool == true)
    let reasons = input.flatMap { _ in object?["reasons"] as? [[String: Any]] }
    #expect(reasons?.first?["code"] as? String == "new-dependency")
  }

  @Test("the human report names the tier and every reason")
  func humanReportShape() async throws {
    let repository = try DesignScopeRepository()
    defer { repository.remove() }
    let file = try repository.frameAnswersFile(
      """
      {"schemaVersion": 1, "touchedModules": ["Core"], "newModules": [], "newDependencies": []}
      """)
    let outcome = await DesignScopeRun.run(
      frameAnswersPath: file.path, root: repository.root, swiftPM: repository.swiftPM)
    guard case .recommended(let report) = outcome else {
      Issue.record("expected .recommended")
      return
    }
    let rendered = DesignScopeReport.render(report, format: .human)
    #expect(rendered.contains("quick"))
    #expect(rendered.contains("no new dependency"))
  }
}
