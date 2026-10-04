import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The docs router bootstrap stamps, and the templates that carry the router, the AGENTS.md
/// pointer to it, and the design doc skeleton.
@Suite("bootstrap docs router")
struct BootstrapRouterTests {
  static let templates = HarnessTemplates(
    agents: "# Router\nSee [`docs/index.md`](docs/index.md).\n", config: "xcode = {{XCODE}}\n",
    swiftFormat: "{}\n", swiftLint: "rules\n", lefthook: "pre-commit:\n",
    gitignore: "# swift-harness\n**/.harness/runs/\n", docsIndex: "# Docs index\n",
    scenario: "enum Scenario: String { case live }\n")

  static let inferred = ConfigInference.infer(
    RepositorySurvey(
      packageDirectories: ["Packages/A"],
      schemes: SchemeListing(container: "App", schemes: ["App"], targets: ["App"]),
      xcodeVersion: "26.2",
      devices: [
        SimulatorDevice(
          udid: "U", name: "iPhone 17",
          runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Shutdown",
          isAvailable: true)
      ]))

  static func inputs(existing: [String: ExistingEntry] = [:]) -> BootstrapInputs {
    BootstrapInputs(
      root: "/R", existing: existing, templates: templates, config: .absent, inferred: inferred,
      swiftLintInstalled: false, lefthookInstalled: true,
      git: .repository(prefix: "", hooksInstalled: false), registry: .absent,
      registryPath: "/H/.swift-harness/projects.json",
      shim: .missing(path: "/H/.local/bin/swiftgate"),
      shimPath: "/H/.local/bin/swiftgate", shimTarget: "/P/bin/swiftgate")
  }

  private func change(_ plan: BootstrapPlan, _ path: String) -> StampChange? {
    plan.stamps.first { $0.path == path }?.change
  }

  /// Reads a real shipped template, relative to the plugin checkout root, the way
  /// `BootstrapFiles.templates(harnessRoot:)` does.
  private func template(_ relativePath: String) throws -> String {
    try String(
      contentsOf: Fixture.checkoutRoot.appending(path: relativePath), encoding: .utf8)
  }

  /// The repository as it would be after applying every write in `plan`.
  private func applied(_ plan: BootstrapPlan, over inputs: BootstrapInputs) throws
    -> BootstrapInputs
  {
    var next = inputs
    for stamp in plan.stamps {
      switch stamp.change {
      case .create(let text), .update(_, let text): next.existing[stamp.path] = .file(text)
      case .link(let destination): next.existing[stamp.path] = .symlink(destination: destination)
      case .unchanged, .untouched: break
      }
    }
    if case .create = change(plan, BootstrapPlanner.Paths.config) {
      next.config = .loaded(
        try Config(
          xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
          simulator: SimulatorConfig(device: "iPhone 17", os: "26.2")))
    }
    for action in plan.home {
      switch action {
      case .writeRegistry(_, let contents, _):
        next.registry = .loaded(try ProjectRegistry.decode(Data(contents.utf8)))
      case .linkShim: next.shim = .current
      case .installGitHooks: next.git = .repository(prefix: "", hooksInstalled: true)
      }
    }
    return next
  }

  @Test(
    "a fresh repository gets the docs router and the AGENTS.md pointer to it, and no plan-state file — catches plan state stamped per worktree"
  )
  func freshRouterAndPointer() {
    let plan = BootstrapPlanner.plan(Self.inputs())
    #expect(change(plan, "docs/index.md") == .create(Self.templates.docsIndex))
    guard case .create(let agents) = change(plan, "AGENTS.md") else {
      Issue.record("expected AGENTS.md to be created")
      return
    }
    #expect(agents.contains("docs/index.md"))
    #expect(!plan.stamps.contains { $0.path.hasPrefix(".harness/plans") })
  }

  @Test(
    "planning again over an applied plan that includes the docs router writes nothing — catches a non-idempotent bootstrap that churns the router on every run"
  )
  func routerIsIdempotent() throws {
    let first = BootstrapPlanner.plan(Self.inputs())
    let second = BootstrapPlanner.plan(try applied(first, over: Self.inputs()))
    #expect(second.isNoOp)
    #expect(change(second, "docs/index.md") == .unchanged)
  }

  @Test(
    "once the docs router exists, bootstrap never rewrites it — catches bootstrap clobbering rows the design and plan skills added"
  )
  func routerOwnedAfterCreation() {
    let grown = "# Docs index\n\n| Reading a design | [designs/foo.md](designs/foo.md) |\n"
    let plan = BootstrapPlanner.plan(Self.inputs(existing: ["docs/index.md": .file(grown)]))
    #expect(change(plan, "docs/index.md") == .unchanged)
  }

  @Test(
    "the shipped gitignore template drops the repo-level orchestrator-lock entry and adds the harness's newer ephemeral directories, keeping the rest — catches stale or missing ignore entries shipping to real repositories"
  )
  func gitignoreTemplateContent() throws {
    let text = try template("templates/gitignore")
    #expect(!text.contains(".harness/orchestrator.lock"))
    #expect(text.contains("**/.harness/runs/"))
    #expect(text.contains("**/.harness/probe/"))
    #expect(text.contains("**/.harness/context-pack/"))
    #expect(text.contains("**/.harness/task-status.json"))
  }

  @Test(
    "the gitignore template ignores the build returns and a worker's scratch directory — catches a build leaving main dirty for the next ship preflight, and a worker's scratch files reaching a commit"
  )
  func gitignoreTemplateIgnoresBuildScratch() throws {
    let text = try template("templates/gitignore")
    #expect(text.contains("**/.harness/build/"))
    #expect(text.contains("**/.harness/tmp/"))
  }

  @Test(
    "bootstrap wires a commit-msg hook, and tracks every hook the shipped template installs — catches lefthook.yml gaining a stanza bootstrap never checks is installed"
  )
  func commitMsgHookWiredWithItsCommand() throws {
    #expect(BootstrapPlanner.gitHooks == ["pre-commit", "pre-push", "commit-msg"])
    let text = try template("templates/lefthook.yml")
    #expect(text.contains("commit-msg"))
    #expect(text.contains("comments --commit-msg"))
  }

  @Test(
    "the stamped AGENTS.md router block stays within the SessionStart hook's line budget — catches the router growing the block past what agents will read"
  )
  func stampedAgentsWithinBudget() throws {
    let body = try template("templates/AGENTS.md")
    let block = "\(BootstrapPlanner.blockBegin)\n\(body)\(BootstrapPlanner.blockEnd)\n"
    #expect(block.split(separator: "\n", omittingEmptySubsequences: false).count <= 60)
  }

  @Test(
    "the design doc template's sections appear in the spec's order — catches a skeleton section reordered out of sync with design-lint"
  )
  func designDocSkeletonSectionOrder() throws {
    let text = try template("templates/design-doc.md")
    let order = [
      "## Problem", "## Requirements", "## Evidence", "## Options", "## Decision",
      "## Architecture", "## Module kinds", "## Test plan by tier", "## Observability",
      "## Perf & scale", "## Risks", "## Open questions", "## Changelog",
    ]
    var searchStart = text.startIndex
    for heading in order {
      guard let range = text.range(of: heading, range: searchStart..<text.endIndex) else {
        Issue.record("missing or out-of-order section: \(heading)")
        return
      }
      searchStart = range.upperBound
    }
    #expect(text.contains("status: proposed"))
    #expect(text.contains("```mermaid\nflowchart"))
    #expect(text.contains("```mermaid\nsequenceDiagram"))
  }
}
