import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate xcode`: edits to an Xcode project the harness doesn't own.
struct XcodeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "xcode",
    abstract: "Add files to Xcode targets without restructuring the project.",
    subcommands: [XcodeAddFileCommand.self])
}

/// `swiftgate xcode add-file <path> --target <t>`: joins 1 file to 1 target the way the area's
/// inclusion kind says.
struct XcodeAddFileCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add-file",
    abstract: "Add a source file to an Xcode target.")

  @Argument(help: "The file, repository-relative.")
  var path: String

  @Option(help: "The target that compiles it.")
  var target: String

  @Flag(help: "Print JSON.")
  var json = false

  /// The inputs a test replaces.
  struct Dependencies: Sendable {
    var processRunner: any ProcessRunner = LiveProcessRunner()
  }

  /// What the command did. `project` is the `.xcodeproj`, repository-relative.
  enum Outcome: Sendable, Equatable {
    case added(project: String, PBXAddedFile, note: String?)
    case alreadyCompiled(project: String)
    /// The target's synchronized folder takes the file in: nothing to write.
    case synchronized(project: String?)
    /// The generator ran and its project compiles the file in the target.
    case regenerated(project: String, tool: XcodeGeneratorTool)
  }

  /// Why nothing was added; `verdict` picks the exit code.
  struct Failure: Error, Sendable, Equatable {
    let message: String
    let verdict: Verdict
  }

  /// Joins `path` to `target` in the clone holding `directory`.
  static func addFile(
    directory: URL, path: String, target: String, dependencies: Dependencies
  ) async throws(Failure) -> Outcome {
    let runner = dependencies.processRunner
    let git = GitTrackedTree(runner: runner, directory: directory)
    let root: URL
    let layout: BrownfieldStateLayout
    do {
      root = try await git.repositoryRoot()
      layout = try await git.stateLayout()
    } catch {
      throw Failure(message: error.message, verdict: .blocked)
    }
    let config: LoadedConfig?
    do {
      config = try ConfigLoader().loadProfile(repositoryRoot: root, commonDir: layout.commonDir)
    } catch {
      throw Failure(message: "\(error)", verdict: .blocked)
    }
    guard case .brownfield(let brownfield)? = config else {
      throw Failure(
        message: "\(layout.config.path) holds no brownfield config; run swiftgate discover --apply",
        verdict: .blocked)
    }
    let holding = brownfield.areas.filter { area in
      area.xcode != nil && (area.root == "." || path.hasPrefix(area.root + "/"))
    }
    guard let area = holding.max(by: { $0.root.count < $1.root.count }),
      let xcode = area.xcode
    else {
      throw Failure(message: "no Xcode area of the config holds \(path)", verdict: .red)
    }
    guard FileManager.default.fileExists(atPath: root.appending(path: path).path) else {
      throw Failure(message: "\(path) doesn't exist; write it before adding it", verdict: .red)
    }
    if xcode.inclusion == .synchronized { return .synchronized(project: xcode.project) }
    guard let project = xcode.project else {
      throw Failure(
        message: "area \(area.name) names no project for \(path) to join", verdict: .red)
    }
    let files = XcodeProjectFiles(runner: runner, repositoryRoot: root)
    guard let tool = XcodeGeneratorTool(inclusion: xcode.inclusion) else {
      return try await edit(files, path: path, target: target, project: project, note: nil)
    }
    if await isTracked(project + "/project.pbxproj", root: root, runner: runner) {
      return try await edit(
        files, path: path, target: target, project: project,
        note:
          "\(project) is committed, so it was edited directly; cover \(path) in \(xcode.manifest ?? "the generator's spec") too, or the next generate drops it"
      )
    }
    return try await regenerate(
      tool: tool, xcode: xcode, path: path, target: target, project: project, root: root,
      layout: layout, files: files, runner: runner)
  }

  private static func edit(
    _ files: XcodeProjectFiles, path: String, target: String, project: String, note: String?
  ) async throws(Failure) -> Outcome {
    switch await files.addFile(path, target: target, projectPath: project) {
    case .added(let added): return .added(project: project, added, note: note)
    case .alreadyCompiled: return .alreadyCompiled(project: project)
    case .refused(let error):
      throw Failure(message: "\(project): \(error)", verdict: .red)
    case .checkFailed(let command, let status, let output):
      throw Failure(
        message:
          "\(command) rejected the edited \(project) (\(status)), so it was put back:\n\(output)",
        verdict: .red)
    case .io(let reason):
      throw Failure(message: reason, verdict: .blocked)
    }
  }

  /// An ignored generated project: the generator writes it in place, and a missing generator
  /// falls back to a direct edit of the last generated project, saying so.
  private static func regenerate(
    tool: XcodeGeneratorTool, xcode: XcodeAreaConfig, path: String, target: String,
    project: String, root: URL, layout: BrownfieldStateLayout, files: XcodeProjectFiles,
    runner: any ProcessRunner
  ) async throws(Failure) -> Outcome {
    guard let request = XcodeGenerateRequest(xcode: xcode, generatedProjectTracked: false) else {
      throw Failure(message: "the \(tool.rawValue) area names no manifest", verdict: .red)
    }
    let generator = XcodeGenerator(runner: runner, repositoryRoot: root, layout: layout)
    let outcome = await generator.generate(request) { generation in
      XcodeProjectFiles.targets(compiling: path, projectPath: project, in: generation.tree)
    }
    switch outcome {
    case .generated(_, let targets):
      guard targets?.contains(target) == true else {
        throw Failure(
          message:
            "\(tool.rawValue) generate ran but \(project) doesn't compile \(path) in \(target); cover it in \(request.manifest)",
          verdict: .red)
      }
      return .regenerated(project: project, tool: tool)
    case .notInstalled(_, let message):
      guard FileManager.default.fileExists(atPath: root.appending(path: project).path) else {
        throw Failure(message: "\(tool.rawValue) isn't installed: \(message)", verdict: .blocked)
      }
      return try await edit(
        files, path: path, target: target, project: project,
        note:
          "\(tool.rawValue) isn't installed (\(message)), so \(project) was edited directly; cover \(path) in \(request.manifest) too"
      )
    case .versionMismatch(_, let pinned, let installed):
      throw Failure(
        message:
          "\(tool.rawValue) \(installed) is installed but \(pinned.source) pins \(pinned.version)",
        verdict: .blocked)
    case .failed(_, let status, let output):
      throw Failure(
        message: "\(tool.rawValue) generate failed (\(status)):\n\(output)", verdict: .red)
    case .blocked(_, let reason):
      throw Failure(message: reason, verdict: .blocked)
    }
  }

  private static func isTracked(_ path: String, root: URL, runner: any ProcessRunner) async
    -> Bool
  {
    let output = try? await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["ls-files", "--error-unmatch", "--", path],
        workingDirectory: root.path, timeout: .seconds(60)))
    return output?.status.isSuccess == true
  }

  func run() async throws {
    let directory = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome: Outcome
    do throws(Failure) {
      outcome = try await Self.addFile(
        directory: directory, path: path, target: target, dependencies: .init())
    } catch {
      try emit(
        ["status": "error", "message": error.message], text: "xcode add-file: \(error.message)")
      throw ExitCode(error.verdict.exitCode)
    }
    switch outcome {
    case .added(let project, let added, let note):
      var fields = [
        "status": "added", "project": project, "file_reference": added.fileReferenceID,
        "build_file": added.buildFileID,
      ]
      fields["note"] = note
      try emit(
        fields,
        text: "added \(path) to \(target) in \(project)" + (note.map { "\n\($0)" } ?? ""))
    case .alreadyCompiled(let project):
      try emit(
        ["status": "unchanged", "project": project],
        text: "\(target) already compiles \(path) in \(project); nothing changed")
    case .synchronized(let project):
      var fields = ["status": "synchronized"]
      fields["project"] = project
      try emit(
        fields,
        text:
          "\(path) joins \(target) by sitting under its synchronized folder; nothing to write")
    case .regenerated(let project, let tool):
      try emit(
        ["status": "regenerated", "project": project, "tool": tool.rawValue],
        text: "\(tool.rawValue) generate made \(project) compile \(path) in \(target)")
    }
  }

  private func emit(_ fields: [String: String], text: String) throws {
    guard json else { return Console.write(text) }
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    Console.write(String(decoding: data, as: UTF8.self))
  }
}
