import Foundation
import SwiftGateDomain

/// Why `bootstrap` could not read its templates or perform a write. Always the machine's or the
/// installation's problem, never the code's.
public enum BootstrapError: Error, Sendable, Equatable, CustomStringConvertible {
  case missingTemplate(path: String)
  case write(path: String, reason: String)
  case gitHooks(String)

  public var verdict: Verdict { .blocked }

  public var description: String {
    switch self {
    case .missingTemplate(let path): "template \(path) is missing or unreadable"
    case .write(let path, let reason): "could not write \(path): \(reason)"
    case .gitHooks(let reason): "lefthook install failed: \(reason)"
    }
  }
}

/// The machine and git facts `bootstrap` needs, and the one external command it runs.
public protocol BootstrapProbe: Sendable {
  /// `26.2`, or `nil` when `xcodebuild -version` gave none.
  func xcodeVersion() async -> String?
  /// Every simulator device; empty when `simctl` could not answer.
  func devices() async -> [SimulatorDevice]
  /// `xcodebuild -list -json` of `container` (a `.xcodeproj` or `.xcworkspace` at `root`).
  func schemes(root: URL, container: String) async -> SchemeListing?
  func git(root: URL) async -> GitState
  func installGitHooks(root: URL) async throws(BootstrapError)
}

public struct LiveBootstrapProbe: BootstrapProbe {
  private let runner: any ProcessRunner

  public init(runner: any ProcessRunner) {
    self.runner = runner
  }

  public func xcodeVersion() async -> String? {
    guard let output = try? await LiveXcodebuild(runner: runner).version() else { return nil }
    return Doctor.xcodeVersion(from: output)
  }

  public func devices() async -> [SimulatorDevice] {
    (try? await LiveSimctl(runner: runner).devices()) ?? []
  }

  public func schemes(root: URL, container: String) async -> SchemeListing? {
    let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
    // Listing resolves the project's packages first, which takes tens of seconds when cold.
    let output = try? await runner.run(
      ProcessInvocation(
        executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "-list", "-json", flag, container],
        workingDirectory: root.path, timeout: .seconds(300)))
    guard let output, output.status.isSuccess else { return nil }
    return try? SchemeListing.decode(output.stdout.bytes)
  }

  public func git(root: URL) async -> GitState {
    guard let prefix = await gitLine(["rev-parse", "--show-prefix"], root: root),
      let hooks = await gitLine(["rev-parse", "--git-path", "hooks"], root: root)
    else { return .notRepository }
    let directory = hooks.hasPrefix("/") ? URL(filePath: hooks) : root.appending(path: hooks)
    let installed = BootstrapPlanner.gitHooks.allSatisfy { hook in
      let script = try? String(contentsOf: directory.appending(path: hook), encoding: .utf8)
      return script?.contains("lefthook") == true
    }
    return .repository(prefix: prefix, hooksInstalled: installed)
  }

  public func installGitHooks(root: URL) async throws(BootstrapError) {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "lefthook", arguments: ["install"], workingDirectory: root.path,
          timeout: .seconds(60)))
    } catch {
      throw .gitHooks("\(error)")
    }
    guard output.status.isSuccess else {
      throw .gitHooks(
        "\(output.status): \(output.stderr.text.split(separator: "\n").prefix(2).joined(separator: " "))"
      )
    }
  }

  private func gitLine(_ arguments: [String], root: URL) async -> String? {
    let output = try? await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard let output, output.status.isSuccess else { return nil }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// File-system reads and writes for `bootstrap`.
public enum BootstrapFiles {
  /// `templates/` file names, relative to the plugin root.
  public enum TemplateNames {
    public static let agents = "templates/AGENTS.md"
    public static let config = "templates/swiftgate.toml"
    public static let swiftFormat = "templates/swift-format.json"
    public static let swiftLint = "templates/swiftlint.yml"
    public static let lefthook = "templates/lefthook.yml"
    public static let gitignore = "templates/gitignore"
    public static let docsIndex = "templates/docs-index.md"
  }

  /// Directories never searched for packages: build output, dependency checkouts, bundles.
  static let skippedDirectories: Set<String> = [
    "DerivedData", "Pods", "Carthage", "node_modules", "build",
  ]
  static let maxPackageDepth = 3

  public static func templates(harnessRoot: URL) throws(BootstrapError) -> HarnessTemplates {
    func read(_ name: String) throws(BootstrapError) -> String {
      guard
        let text = try? String(contentsOf: harnessRoot.appending(path: name), encoding: .utf8)
      else { throw .missingTemplate(path: name) }
      return text
    }
    return HarnessTemplates(
      agents: try read(TemplateNames.agents), config: try read(TemplateNames.config),
      swiftFormat: try read(TemplateNames.swiftFormat),
      swiftLint: try read(TemplateNames.swiftLint),
      lefthook: try read(TemplateNames.lefthook), gitignore: try read(TemplateNames.gitignore),
      docsIndex: try read(TemplateNames.docsIndex))
  }

  public static func entry(root: URL, path: String) -> ExistingEntry {
    let manager = FileManager.default
    let fullPath = root.appending(path: path).path
    if let destination = try? manager.destinationOfSymbolicLink(atPath: fullPath) {
      return .symlink(destination: destination)
    }
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { return .absent }
    guard !isDirectory.boolValue,
      let text = try? String(contentsOf: URL(filePath: fullPath), encoding: .utf8)
    else { return .other }
    return .file(text)
  }

  public static func entries(root: URL) -> [String: ExistingEntry] {
    Dictionary(
      uniqueKeysWithValues: BootstrapPlanner.Paths.all.map { ($0, entry(root: root, path: $0)) })
  }

  /// Repository-relative directories holding a `Package.swift`, searched a few levels deep. The
  /// search stops at a package, so fixture packages nested inside one are not reported.
  public static func packageDirectories(root: URL) -> [String] {
    var found: [String] = []
    func visit(_ relative: String, depth: Int) {
      let directory = relative.isEmpty ? root : root.appending(path: relative)
      let manager = FileManager.default
      if manager.fileExists(atPath: directory.appending(path: "Package.swift").path) {
        found.append(relative)
        return
      }
      guard depth < maxPackageDepth,
        let children = try? manager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      else { return }
      for child in children {
        let name = child.lastPathComponent
        let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true, !name.hasPrefix("."),
          !skippedDirectories.contains(name), !name.hasSuffix(".xcodeproj"),
          !name.hasSuffix(".xcworkspace")
        else { continue }
        visit(relative.isEmpty ? name : "\(relative)/\(name)", depth: depth + 1)
      }
    }
    visit("", depth: 0)
    return found.sorted()
  }

  /// Names directly under `root`, for ``AppContainer/choose(among:)``.
  public static func rootEntries(root: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
  }

  public static func configState(root: URL) -> ConfigState {
    do throws(ConfigLoadError) {
      guard let config = try ConfigLoader().load(repositoryRoot: root) else { return .absent }
      return .loaded(config)
    } catch {
      return .invalid(error.description)
    }
  }

  public static func registryState(path: String) -> RegistryState {
    guard FileManager.default.fileExists(atPath: path) else { return .absent }
    guard let data = FileManager.default.contents(atPath: path) else {
      return .invalid("unreadable")
    }
    do {
      return .loaded(try ProjectRegistry.decode(data))
    } catch {
      return .invalid("not a schema \(ProjectRegistry.schema) registry: \(error)")
    }
  }

  /// Writes each stamp that changes something. Files are replaced atomically; parents are created.
  public static func apply(_ stamps: [Stamp], root: URL) throws(BootstrapError) {
    for stamp in stamps {
      let url = root.appending(path: stamp.path)
      switch stamp.change {
      case .create(let text), .update(_, let text):
        try write(text, to: url, displayPath: stamp.path)
      case .link(let destination):
        do {
          try FileManager.default.createSymbolicLink(
            atPath: url.path, withDestinationPath: destination)
        } catch {
          throw .write(path: stamp.path, reason: error.localizedDescription)
        }
      case .unchanged, .untouched: continue
      }
    }
  }

  /// Performs the registry and shim actions; the git-hooks action belongs to ``BootstrapProbe``.
  public static func apply(_ action: HomeAction) throws(BootstrapError) {
    switch action {
    case .writeRegistry(let path, let contents, _):
      try write(contents, to: URL(filePath: path), displayPath: path)
    case .linkShim(let path, let target):
      let manager = FileManager.default
      do {
        try manager.createDirectory(
          at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        // Only a symlink is ever replaced; the planner refuses to replace a regular file.
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
          try manager.removeItem(atPath: path)
        }
        try manager.createSymbolicLink(atPath: path, withDestinationPath: target)
      } catch {
        throw .write(path: path, reason: error.localizedDescription)
      }
    case .installGitHooks: return
    }
  }

  private static func write(_ text: String, to url: URL, displayPath: String)
    throws(BootstrapError)
  {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url, options: .atomic)
    } catch {
      throw .write(path: displayPath, reason: error.localizedDescription)
    }
  }
}
