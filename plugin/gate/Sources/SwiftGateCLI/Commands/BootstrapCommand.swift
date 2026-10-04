import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `bootstrap`: stamps the per-app layer (spec §4.2) from the plugin's `templates/`. A dry run
/// reads only; `--apply` writes the repository files, then the registry and shim under the home
/// directory, then installs the git hooks.
enum BootstrapRun {
  struct Environment: Sendable {
    var home: URL
    /// The plugin checkout: `templates/` and `bin/swiftgate` live here.
    var harnessRoot: URL
    var probe: any BootstrapProbe
    var swiftLintInstalled: Bool
    var lefthookInstalled: Bool
  }

  struct Outcome: Sendable {
    /// `nil` when bootstrap failed before it could plan.
    let plan: BootstrapPlan?
    let text: String
    let failed: Bool
  }

  static func survey(root: URL, profile: String?, environment: Environment)
    async throws(BootstrapError)
    -> BootstrapInputs
  {
    let templates = try BootstrapFiles.templates(harnessRoot: environment.harnessRoot)
    let schemes: SchemeListing? =
      switch AppContainer.choose(among: BootstrapFiles.rootEntries(root: root)) {
      case .success(let container):
        await environment.probe.schemes(root: root, container: container)
      case .failure: nil
      }
    async let xcode = environment.probe.xcodeVersion()
    async let devices = environment.probe.devices()
    async let git = environment.probe.git(root: root)
    let survey = RepositorySurvey(
      packageDirectories: BootstrapFiles.packageDirectories(root: root), schemes: schemes,
      xcodeVersion: await xcode, devices: await devices)
    let registryPath = environment.home.appending(path: ProjectRegistry.path).path
    let shimPath = environment.home.appending(path: DoctorRun.shimPath).path
    let appSources = BootstrapFiles.appSources(root: root)
    var existing = BootstrapFiles.entries(root: root)
    for entryPoint in appSources.entryPoints {
      let path = ScenarioStamp.path(beside: entryPoint)
      existing[path] = BootstrapFiles.entry(root: root, path: path)
    }
    return BootstrapInputs(
      root: root.path, existing: existing, templates: templates,
      config: BootstrapFiles.configState(root: root), inferred: ConfigInference.infer(survey),
      swiftLintInstalled: environment.swiftLintInstalled,
      lefthookInstalled: environment.lefthookInstalled, git: await git,
      registry: BootstrapFiles.registryState(path: registryPath), registryPath: registryPath,
      shim: HarnessFiles.shimStatus(linkPath: shimPath, harnessRoot: environment.harnessRoot.path),
      shimPath: shimPath, shimTarget: environment.harnessRoot.appending(path: "bin/swiftgate").path,
      profile: profile, appSources: appSources)
  }

  static func run(root: URL, apply: Bool, profile: String? = nil, environment: Environment) async
    -> Outcome
  {
    let inputs: BootstrapInputs
    do throws(BootstrapError) {
      inputs = try await survey(root: root, profile: profile, environment: environment)
    } catch {
      return Outcome(
        plan: nil, text: "bootstrap: \(error)", failed: true)
    }
    let plan = BootstrapPlanner.plan(inputs)
    let preview = plan.render()
    guard apply else {
      let footer =
        plan.isNoOp
        ? "Nothing to do." : "Dry run: nothing was written. Re-run with --apply to write it."
      return Outcome(plan: plan, text: preview + "\n" + footer, failed: false)
    }
    guard !plan.isNoOp else { return Outcome(plan: plan, text: preview, failed: false) }

    var done: [String] = []
    do throws(BootstrapError) {
      try BootstrapFiles.apply(plan.stamps, root: root)
      done += plan.writes.map { "wrote \($0.path)" }
      for action in plan.home {
        switch action {
        case .writeRegistry(let path, _, let adding):
          try BootstrapFiles.apply(action)
          done.append("registered \(adding) in \(path)")
        case .linkShim(let path, let target):
          try BootstrapFiles.apply(action)
          done.append("linked \(path) -> \(target)")
        case .installGitHooks:
          try await environment.probe.installGitHooks(root: root)
          done.append("installed git hooks with lefthook")
        }
      }
    } catch {
      return Outcome(
        plan: plan,
        text: (["bootstrap: applied partly, then failed: \(error)"] + done).joined(separator: "\n"),
        failed: true)
    }
    let notes = plan.notes.isEmpty ? [] : ["Notes:"] + plan.notes.map { "  \($0)" }
    let summary = "bootstrap: applied \(done.count) change(s)"
    return Outcome(
      plan: plan, text: ([summary] + done.map { "  \($0)" } + notes).joined(separator: "\n"),
      failed: false)
  }
}

struct BootstrapCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bootstrap",
    abstract: "Stamp or upgrade this repository's harness layer. Dry run unless --apply.",
    discussion: """
      Writes AGENTS.md (managed block) and a CLAUDE.md symlink, .swiftgate.toml (only when \
      missing), Scenario.swift beside a single @main App file when it creates the config, \
      .swift-format, .swiftlint.yml (when swiftlint is installed), lefthook.yml, \
      .gitignore entries and .harness/plans/index.json. With --apply it also registers the \
      repository in ~/.swift-harness/projects.json, links ~/.local/bin/swiftgate to this \
      plugin's shim, and runs `lefthook install`. Run it from the repository root.
      """)

  @Flag(help: "Write the changes. Without it, print what would change and write nothing.")
  var apply = false

  @Option(
    help:
      "The build preset a new .swiftgate.toml names as its [harness] profile (default: default).")
  var profile: String?

  func run() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let harnessRoot = environment["SWIFTGATE_HARNESS_ROOT"] else {
      FileHandle.standardError.write(
        Data(
          "bootstrap: run through the plugin's bin/swiftgate, which locates its templates\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
    // getcwd already resolves symlinks, so the registry records one spelling per repository.
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let path = environment["PATH"] ?? ""
    let outcome = await BootstrapRun.run(
      root: root, apply: apply, profile: profile,
      environment: BootstrapRun.Environment(
        home: URL(filePath: environment["HOME"] ?? NSHomeDirectory(), directoryHint: .isDirectory),
        harnessRoot: URL(filePath: harnessRoot, directoryHint: .isDirectory),
        probe: LiveBootstrapProbe(runner: LiveProcessRunner()),
        swiftLintInstalled: HarnessFiles.isOnPath("swiftlint", path: path),
        lefthookInstalled: HarnessFiles.isOnPath("lefthook", path: path)))
    Console.write(outcome.text)
    if outcome.failed { throw ExitCode(Verdict.blocked.exitCode) }
  }
}
