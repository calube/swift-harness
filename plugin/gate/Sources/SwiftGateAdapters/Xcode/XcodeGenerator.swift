import Foundation
import SwiftGateDomain

/// A tool that writes an Xcode project from a spec the repository commits.
public enum XcodeGeneratorTool: String, Sendable, Equatable, CaseIterable {
  case xcodegen
  case tuist

  /// `nil` for an inclusion whose project is edited, not generated.
  public init?(inclusion: XcodeInclusion) {
    switch inclusion {
    case .xcodegen: self = .xcodegen
    case .tuist: self = .tuist
    case .synchronized, .explicit: return nil
    }
  }
}

/// The generator version a repository asks for, and the file that asks.
public struct XcodeGeneratorPin: Sendable, Equatable {
  public let version: String
  /// Repository-relative.
  public let source: String

  public init(version: String, source: String) {
    self.version = version
    self.source = source
  }
}

/// 1 area's generate step.
public struct XcodeGenerateRequest: Sendable, Equatable {
  public let tool: XcodeGeneratorTool
  /// Repository-relative path of `project.yml` or `Project.swift`.
  public let manifest: String
  /// A committed generated project generates in a scratch tree, so the user's tree gets no diff.
  public let generatedProjectTracked: Bool

  public init(tool: XcodeGeneratorTool, manifest: String, generatedProjectTracked: Bool) {
    self.tool = tool
    self.manifest = manifest
    self.generatedProjectTracked = generatedProjectTracked
  }

  /// `nil` when the area has no generator or no manifest.
  public init?(xcode: XcodeAreaConfig, generatedProjectTracked: Bool) {
    guard let tool = XcodeGeneratorTool(inclusion: xcode.inclusion), let manifest = xcode.manifest
    else { return nil }
    self.init(tool: tool, manifest: manifest, generatedProjectTracked: generatedProjectTracked)
  }
}

/// Where a generator wrote its project.
public enum XcodeGeneratedLocation: Sendable, Equatable {
  /// The user's tree: the generated project is gitignored.
  case inPlace
  /// A scratch worktree at `HEAD` under the git dir, removed once the caller's body returns.
  case scratch
}

/// A generate that ran to a zero exit.
public struct XcodeGeneration: Sendable, Equatable {
  public let tool: XcodeGeneratorTool
  /// The installed version, as the tool prints it.
  public let installed: String
  /// `nil` when the repository pins no version: the caller reports the run as unpinned.
  public let pin: XcodeGeneratorPin?
  public let location: XcodeGeneratedLocation
  /// The toplevel of the tree the project was generated in.
  public let tree: URL
  /// The generator's stdout and stderr.
  public let output: String
  public let elapsed: Duration

  public init(
    tool: XcodeGeneratorTool, installed: String, pin: XcodeGeneratorPin?,
    location: XcodeGeneratedLocation, tree: URL, output: String, elapsed: Duration
  ) {
    self.tool = tool
    self.installed = installed
    self.pin = pin
    self.location = location
    self.tree = tree
    self.output = output
    self.elapsed = elapsed
  }
}

/// What a generate step came to. Only ``generated(_:_:)`` ran the caller's body.
public enum XcodeGenerateOutcome<Value: Sendable>: Sendable {
  case generated(XcodeGeneration, Value)
  /// The tool isn't on `PATH`; `message` is what the launch printed.
  case notInstalled(tool: XcodeGeneratorTool, message: String)
  /// The installed version isn't the pinned one, so the generator never ran.
  case versionMismatch(tool: XcodeGeneratorTool, pinned: XcodeGeneratorPin, installed: String)
  /// The version query or the generate exited nonzero.
  case failed(tool: XcodeGeneratorTool, status: ExitStatus, output: String)
  /// The step couldn't run at all: a launch failure, a timeout or a scratch tree that wasn't made.
  case blocked(tool: XcodeGeneratorTool, reason: String)
}

extension XcodeGenerateOutcome: Equatable where Value: Equatable {}

/// Runs an area's `xcodegen generate` or `tuist generate` at the version the repository pins.
public struct XcodeGenerator: Sendable {
  private let runner: any ProcessRunner
  private let repositoryRoot: URL
  private let layout: BrownfieldStateLayout
  private let timeout: Duration

  /// - Parameters:
  ///   - repositoryRoot: the worktree's toplevel.
  ///   - layout: its brownfield state, whose scratch directory holds the scratch trees.
  public init(
    runner: any ProcessRunner = LiveProcessRunner(), repositoryRoot: URL,
    layout: BrownfieldStateLayout, timeout: Duration = .seconds(600)
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.layout = layout
    self.timeout = timeout
  }

  /// Generates the project and hands `body` the result while the tree holding it still exists.
  ///
  /// The version is checked before anything is written: a missing tool or one other than the
  /// pinned version never generates.
  public func generate<Value: Sendable>(
    _ request: XcodeGenerateRequest, _ body: (XcodeGeneration) async -> Value
  ) async -> XcodeGenerateOutcome<Value> {
    let tool = request.tool
    let installed: String
    switch await run(tool.versionArguments, in: repositoryRoot.path, tool: tool) {
    case .failure(let outcome):
      return outcome.retyped()
    case .success(let output):
      guard let version = Self.version(printedBy: tool, output.stdout.text) else {
        return .failed(
          tool: tool, status: output.status,
          output: "unreadable version: \(output.stdout.text)\(output.stderr.text)")
      }
      installed = version
    }
    let pin = Self.pin(for: tool, manifest: request.manifest) { path in
      FileManager.default.contents(atPath: repositoryRoot.appending(path: path).path)
    }
    if let pin, !Self.version(installed, satisfies: pin.version) {
      return .versionMismatch(tool: tool, pinned: pin, installed: installed)
    }
    guard request.generatedProjectTracked else {
      return await generate(
        request, installed: installed, pin: pin, location: .inPlace,
        in: repositoryRoot, body)
    }
    let scratch = LiveScratchWorktrees(
      runner: runner, repositoryRoot: repositoryRoot.path, directory: layout.scratchDirectory)
    do {
      try FileManager.default.createDirectory(
        at: layout.scratchDirectory, withIntermediateDirectories: true)
    } catch {
      return .blocked(tool: tool, reason: "creating \(layout.scratchDirectory.path): \(error)")
    }
    do {
      return try await scratch.withScratchTree(
        ScratchTreeRequest(revision: "HEAD", revertTo: "HEAD", copiedPaths: [], revertedPaths: [])
      ) { tree in
        await generate(request, installed: installed, pin: pin, location: .scratch, in: tree, body)
      }
    } catch {
      return .blocked(tool: tool, reason: "making a scratch tree: \(error)")
    }
  }

  private func generate<Value: Sendable>(
    _ request: XcodeGenerateRequest, installed: String, pin: XcodeGeneratorPin?,
    location: XcodeGeneratedLocation, in tree: URL, _ body: (XcodeGeneration) async -> Value
  ) async -> XcodeGenerateOutcome<Value> {
    let tool = request.tool
    let manifest = URL(filePath: request.manifest)
    let directory = tree.appending(path: manifest.deletingLastPathComponent().relativePath)
    var arguments = tool.generateArguments
    if tool == .xcodegen, manifest.lastPathComponent != "project.yml" {
      arguments += ["--spec", manifest.lastPathComponent]
    }
    switch await run(arguments, in: directory.standardizedFileURL.path, tool: tool) {
    case .failure(let outcome):
      return outcome.retyped()
    case .success(let output):
      let generation = XcodeGeneration(
        tool: tool, installed: installed, pin: pin, location: location, tree: tree,
        output: output.stdout.text + output.stderr.text, elapsed: output.elapsed)
      return .generated(generation, await body(generation))
    }
  }

  /// Through `/usr/bin/env`, so a tool missing from `PATH` exits 127 with env's own message
  /// instead of failing to launch.
  private func run(_ arguments: [String], in directory: String, tool: XcodeGeneratorTool) async
    -> Result<ProcessOutput, XcodeGenerateFailure>
  {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "/usr/bin/env", arguments: [tool.rawValue] + arguments,
          workingDirectory: directory, timeout: timeout))
    } catch {
      return .failure(
        .blocked(
          tool: tool, reason: "\(tool.rawValue) \(arguments.joined(separator: " ")): \(error)"))
    }
    switch output.status {
    case .exited(0):
      return .success(output)
    case .exited(127):
      let message = (output.stderr.text + output.stdout.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return .failure(.notInstalled(tool: tool, message: message))
    default:
      return .failure(
        .failed(tool: tool, status: output.status, output: output.stdout.text + output.stderr.text))
    }
  }

  /// `Version: 2.45.3` from XcodeGen, `4.210.0` from Tuist.
  static func version(printedBy tool: XcodeGeneratorTool, _ stdout: String) -> String? {
    for line in stdout.split(whereSeparator: \.isNewline) {
      var text = line.trimmingCharacters(in: .whitespaces)
      if tool == .xcodegen, text.hasPrefix("Version:") {
        text = String(text.dropFirst("Version:".count)).trimmingCharacters(in: .whitespaces)
      }
      if text.first?.isNumber == true { return text }
    }
    return nil
  }

  /// A pin may name a prefix, as mise allows: `2.45` accepts `2.45.3`.
  static func version(_ installed: String, satisfies pinned: String) -> Bool {
    installed == pinned || installed.hasPrefix(pinned + ".")
  }

  static let pinFiles = [
    "Mintfile", ".mise.toml", "mise.toml", ".tool-versions", "Package.resolved",
  ]

  /// The pin the nearest file at or above the manifest's directory declares for `tool`.
  public static func pin(
    for tool: XcodeGeneratorTool, manifest: String, read: (String) -> Data?
  ) -> XcodeGeneratorPin? {
    var directories: [String] = []
    var components = manifest.split(separator: "/").map(String.init).dropLast()
    while true {
      directories.append(components.joined(separator: "/"))
      guard !components.isEmpty else { break }
      components = components.dropLast()
    }
    for directory in directories {
      for file in pinFiles {
        let path = directory.isEmpty ? file : "\(directory)/\(file)"
        guard let data = read(path),
          let version = pinnedVersion(of: tool, in: file, String(decoding: data, as: UTF8.self))
        else { continue }
        return XcodeGeneratorPin(version: version, source: path)
      }
    }
    return nil
  }

  private static func pinnedVersion(of tool: XcodeGeneratorTool, in file: String, _ text: String)
    -> String?
  {
    let version: String?
    switch file {
    case "Mintfile":
      // `yonaskolb/XcodeGen@2.42.0`
      version =
        lines(text).lazy.compactMap { line -> String? in
          let parts = line.split(separator: "@", maxSplits: 1).map(String.init)
          guard parts.count == 2, names(tool, parts[0]) else { return nil }
          return parts[1]
        }.first
    case ".tool-versions":
      // `xcodegen 2.42.0`
      version =
        lines(text).lazy.compactMap { line -> String? in
          let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
          guard parts.count >= 2, names(tool, parts[0]) else { return nil }
          return parts[1]
        }.first
    case "Package.resolved":
      version = resolvedVersion(of: tool, text)
    default:
      version = miseVersion(of: tool, text)
    }
    guard var version, !version.isEmpty else { return nil }
    if version.hasPrefix("v") { version.removeFirst() }
    return version.first?.isNumber == true ? version : nil
  }

  /// A `[tools]` entry: `xcodegen = "2.42.0"` or `"aqua:yonaskolb/XcodeGen" = "2.42.0"`.
  private static func miseVersion(of tool: XcodeGeneratorTool, _ text: String) -> String? {
    var inTools = false
    for line in lines(text) {
      if line.hasPrefix("[") {
        inTools = line == "[tools]"
        continue
      }
      guard inTools, let equals = line.firstIndex(of: "=") else { continue }
      let key = unquoted(line[..<equals])
      guard names(tool, key) else { continue }
      return unquoted(line[line.index(after: equals)...])
    }
    return nil
  }

  /// A SwiftPM pin whose identity is the tool: a tools package that builds it.
  private static func resolvedVersion(of tool: XcodeGeneratorTool, _ text: String) -> String? {
    struct Resolved: Decodable {
      struct Pin: Decodable {
        struct State: Decodable { let version: String? }
        let identity: String
        let state: State
      }
      let pins: [Pin]
    }
    guard let resolved = try? JSONDecoder().decode(Resolved.self, from: Data(text.utf8))
    else { return nil }
    return resolved.pins.first { $0.identity.lowercased() == tool.rawValue }?.state.version
  }

  /// `xcodegen`, `yonaskolb/XcodeGen` and `aqua:yonaskolb/XcodeGen` all name XcodeGen.
  private static func names(_ tool: XcodeGeneratorTool, _ spec: String) -> Bool {
    let name = spec.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
    return name.lowercased() == tool.rawValue
  }

  private static func lines(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).compactMap { raw in
      let line =
        (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
        ?? "").trimmingCharacters(in: .whitespaces)
      return line.isEmpty ? nil : line
    }
  }

  private static func unquoted(_ text: Substring) -> String {
    text.trimmingCharacters(in: .whitespaces).trimmingCharacters(
      in: CharacterSet(charactersIn: "\"'"))
  }
}

/// Every outcome that ends a generate before the caller's body runs.
private enum XcodeGenerateFailure: Error {
  case notInstalled(tool: XcodeGeneratorTool, message: String)
  case failed(tool: XcodeGeneratorTool, status: ExitStatus, output: String)
  case blocked(tool: XcodeGeneratorTool, reason: String)

  func retyped<Value: Sendable>() -> XcodeGenerateOutcome<Value> {
    switch self {
    case .notInstalled(let tool, let message): .notInstalled(tool: tool, message: message)
    case .failed(let tool, let status, let output):
      .failed(tool: tool, status: status, output: output)
    case .blocked(let tool, let reason): .blocked(tool: tool, reason: reason)
    }
  }
}

extension XcodeGeneratorTool {
  fileprivate var versionArguments: [String] {
    switch self {
    case .xcodegen: ["--version"]
    case .tuist: ["version"]
    }
  }

  fileprivate var generateArguments: [String] {
    switch self {
    case .xcodegen: ["generate"]
    case .tuist: ["generate", "--no-open"]
    }
  }
}
