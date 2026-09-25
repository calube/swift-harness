import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("bootstrap config inference")
struct ConfigInferenceTests {
  private static func device(_ name: String, _ runtime: String, available: Bool = true)
    -> SimulatorDevice
  {
    SimulatorDevice(
      udid: UUID().uuidString, name: name,
      runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.\(runtime)", state: "Shutdown",
      isAvailable: available)
  }

  @Test(
    "the app scheme comes from the real SampleApp listing, not a package product scheme — catches app_scheme naming a library scheme that has no UI tests"
  )
  func appSchemeFromListing() throws {
    let listing = try SchemeListing.decode(Fixture.data("Bootstrap/xcodebuild-list-project.json"))
    #expect(listing.container == "SampleApp")
    #expect(ConfigInference.appScheme(listing) == "SampleApp")
    let unnamed = SchemeListing(
      container: "Project", schemes: ["CounterCore", "Shop", "ShopUITests"],
      targets: ["Shop", "ShopUITests"])
    #expect(ConfigInference.appScheme(unnamed) == "Shop")
    let twoApps = SchemeListing(
      container: "Shop", schemes: ["Shop", "ShopAdmin"], targets: ["Shop", "ShopAdmin"])
    #expect(ConfigInference.appScheme(twoApps) == "Shop")
  }

  @Test(
    "sibling packages collapse to one glob and lone packages stay literal — catches a config that misses packages or matches none"
  )
  func packageGlobs() {
    #expect(
      ConfigInference.packageGlobs(["Packages/A", "Packages/B", "Tools/Lint", ""]) == [
        ".", "Packages/*", "Tools/Lint",
      ])
  }

  @Test(
    "the newest iOS runtime's base iPhone is pinned, ignoring unavailable devices and other platforms — catches pinning a device that cannot boot"
  )
  func simulatorChoice() {
    let inferred = ConfigInference.infer(
      RepositorySurvey(
        packageDirectories: ["P"], schemes: nil, xcodeVersion: "26.2",
        devices: [
          Self.device("iPhone 17 Pro", "iOS-26-4"), Self.device("iPhone 17", "iOS-26-4"),
          Self.device("iPhone 16", "iOS-26-4"), Self.device("iPhone 17", "iOS-26-2"),
          Self.device("iPhone 18", "iOS-27-0", available: false),
          Self.device("Apple TV", "tvOS-26-4"),
        ]))
    #expect(inferred.simulator == InferredSimulator(device: "iPhone 17", os: "26.4"))
  }

  @Test(
    "what cannot be inferred renders as a visible placeholder and a note, and the rendered config loads — catches a guessed pin or an unparseable first config"
  )
  func unresolvedValues() throws {
    let inferred = ConfigInference.infer(
      RepositorySurvey(packageDirectories: [], schemes: nil, xcodeVersion: nil, devices: []))
    #expect(inferred.unresolved.count == 4)
    let text = inferred.render(
      template: "xcode = {{XCODE}}\napp_scheme = {{APP_SCHEME}}\npackages = {{PACKAGES}}\n")
    #expect(text == "xcode = \"SET-ME\"\napp_scheme = \"SET-ME\"\npackages = [\"SET-ME\"]\n")
  }

  @Test(
    "an existing config is compared only on what breaks a run — catches bootstrap nagging about deliberate choices or missing an uncovered package"
  )
  func drift() throws {
    let config = try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
    let matching = ConfigInference.infer(
      RepositorySurvey(
        packageDirectories: ["Packages/A", "Packages/B"],
        schemes: SchemeListing(container: "SampleApp", schemes: ["SampleApp"], targets: []),
        xcodeVersion: "26.2.1",
        devices: [Self.device("iPhone 17", "iOS-26-4"), Self.device("iPhone 17", "iOS-26-2")]))
    #expect(matching.drift(from: config).isEmpty)

    let drifted = ConfigInference.infer(
      RepositorySurvey(
        packageDirectories: ["Packages/A", "Tools/Lint"], schemes: nil, xcodeVersion: "26.4",
        devices: [Self.device("iPhone 17", "iOS-26-4")]))
    let notes = drifted.drift(from: config)
    #expect(notes.count == 3)
    #expect(notes.contains { $0.hasPrefix("xcode") && $0.contains("26.4") })
    #expect(notes.contains { $0.contains("does not cover Tools/Lint") })
    #expect(notes.contains { $0.contains("iOS 26.2 is not installed") })
  }
}

@Suite("bootstrap plan")
struct BootstrapPlanTests {
  static let templates = HarnessTemplates(
    agents: "# Router\n", config: "xcode = {{XCODE}}\n", swiftFormat: "{}\n", swiftLint: "rules\n",
    lefthook: "pre-commit:\n", gitignore: "# swift-harness\n**/.harness/runs/\n.harness/x.lock\n")

  static let inferred = ConfigInference.infer(
    RepositorySurvey(
      packageDirectories: ["Packages/A", "Packages/B"],
      schemes: SchemeListing(container: "App", schemes: ["App"], targets: ["App"]),
      xcodeVersion: "26.2",
      devices: [
        SimulatorDevice(
          udid: "U", name: "iPhone 17",
          runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
          state: "Shutdown", isAvailable: true)
      ]))

  static func inputs(
    existing: [String: ExistingEntry] = [:], config: ConfigState = .absent,
    swiftLint: Bool = false, lefthook: Bool = true,
    git: GitState = .repository(prefix: "", hooksInstalled: false),
    registry: RegistryState = .absent, shim: ShimStatus = .missing(path: "/H/.local/bin/swiftgate")
  ) -> BootstrapInputs {
    BootstrapInputs(
      root: "/R", existing: existing, templates: templates, config: config, inferred: inferred,
      swiftLintInstalled: swiftLint, lefthookInstalled: lefthook, git: git, registry: registry,
      registryPath: "/H/.swift-harness/projects.json", shim: shim,
      shimPath: "/H/.local/bin/swiftgate", shimTarget: "/P/bin/swiftgate")
  }

  private func change(_ plan: BootstrapPlan, _ path: String) -> StampChange? {
    plan.stamps.first { $0.path == path }?.change
  }

  /// The repository and home as they would be after applying `plan`.
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
    "a fresh repository gets every file, the CLAUDE.md link and every home action — catches bootstrap silently skipping part of the per-app layer"
  )
  func fresh() {
    let plan = BootstrapPlanner.plan(Self.inputs(swiftLint: true))
    #expect(plan.writes.map(\.path) == BootstrapPlanner.Paths.all)
    #expect(change(plan, "CLAUDE.md") == .link(destination: "AGENTS.md"))
    #expect(change(plan, ".swiftgate.toml") == .create("xcode = \"26.2\"\n"))
    #expect(change(plan, ".harness/plans/index.json") == .create(BootstrapPlanner.emptyPlanIndex))
    #expect(plan.home.count == 3)
    #expect(plan.home.contains(.installGitHooks))
  }

  @Test(
    "planning again over an applied plan writes nothing — catches a non-idempotent bootstrap that churns files on every run"
  )
  func idempotent() throws {
    let first = Self.inputs(existing: [".gitignore": .file("build/\n")], swiftLint: true)
    let plan = BootstrapPlanner.plan(first)
    let second = BootstrapPlanner.plan(try applied(plan, over: first))
    #expect(second.isNoOp)
    #expect(second.writes.isEmpty && second.home.isEmpty)
    #expect(second.render().hasPrefix("bootstrap: 0 to write"))
  }

  @Test(
    "an existing config is never rewritten, only advised on — catches bootstrap clobbering a tuned .swiftgate.toml"
  )
  func existingConfig() throws {
    let stale = try Config(
      xcode: "25.0", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
    let plan = BootstrapPlanner.plan(Self.inputs(config: .loaded(stale)))
    guard case .untouched(let advice) = change(plan, ".swiftgate.toml") else {
      Issue.record("expected the config to be left alone")
      return
    }
    #expect(advice.contains("xcode is \"25.0\""))
    let current = try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
    #expect(
      change(BootstrapPlanner.plan(Self.inputs(config: .loaded(current))), ".swiftgate.toml")
        == .unchanged)
    #expect(
      change(BootstrapPlanner.plan(Self.inputs(config: .invalid("line 3"))), ".swiftgate.toml")
        == .untouched(advice: "never rewritten by bootstrap, and it does not load: line 3"))
  }

  @Test(
    "AGENTS.md keeps the team's text and only the managed block is added or refreshed — catches bootstrap deleting a repository's own agent instructions"
  )
  func agentsBlock() {
    let own = "# Team rules\nBe kind.\n"
    let plan = BootstrapPlanner.plan(Self.inputs(existing: ["AGENTS.md": .file(own)]))
    let block = "<!-- swift-harness:begin -->\n# Router\n<!-- swift-harness:end -->\n"
    #expect(change(plan, "AGENTS.md") == .update(from: own, to: own + "\n" + block))

    let outdated =
      own + "\n<!-- swift-harness:begin -->\nold router\n<!-- swift-harness:end -->\nTail.\n"
    #expect(
      change(
        BootstrapPlanner.plan(Self.inputs(existing: ["AGENTS.md": .file(outdated)])), "AGENTS.md")
        == .update(from: outdated, to: own + "\n" + block + "Tail.\n"))
  }

  @Test(
    ".gitignore gains only the missing harness entries — catches duplicated entries or a rewritten ignore file"
  )
  func gitignore() {
    let current = "build/\n**/.harness/runs/\n"
    let plan = BootstrapPlanner.plan(Self.inputs(existing: [".gitignore": .file(current)]))
    #expect(
      change(plan, ".gitignore")
        == .update(from: current, to: current + "\n# swift-harness\n.harness/x.lock\n"))
  }

  @Test(
    "a CLAUDE.md that is a real file, an existing plan index, and a missing swiftlint are all left alone — catches bootstrap destroying user content or orchestrator state"
  )
  func leftAlone() {
    let plan = BootstrapPlanner.plan(
      Self.inputs(existing: [
        "CLAUDE.md": .file("mine\n"), ".harness/plans/index.json": .file("{\"plans\":[{}]}"),
      ]))
    guard case .untouched = change(plan, "CLAUDE.md"),
      case .untouched = change(plan, ".swiftlint.yml")
    else {
      Issue.record("expected CLAUDE.md and .swiftlint.yml to be left alone")
      return
    }
    #expect(change(plan, ".harness/plans/index.json") == .unchanged)
    #expect(plan.render().contains("Left alone:\n  CLAUDE.md: exists and is not a symlink"))
  }

  @Test(
    "home side effects happen only when needed: registered once, a regular-file shim is not replaced, hooks reinstalled when lefthook.yml changes — catches duplicate registry entries or deleting a user's binary"
  )
  func homeActions() {
    let registered = BootstrapPlanner.plan(
      Self.inputs(
        registry: .loaded(ProjectRegistry(projects: ["/R", "/Other"])),
        shim: .elsewhere(
          path: "/H/.local/bin/swiftgate", target: "/H/.local/bin/swiftgate", expected: "x")))
    #expect(!registered.home.contains { if case .writeRegistry = $0 { true } else { false } })
    #expect(!registered.home.contains { if case .linkShim = $0 { true } else { false } })
    #expect(registered.notes.contains { $0.contains("is a regular file") })

    let stale = BootstrapPlanner.plan(
      Self.inputs(
        existing: ["lefthook.yml": .file("old\n")],
        git: .repository(prefix: "", hooksInstalled: true),
        shim: .elsewhere(
          path: "/H/.local/bin/swiftgate", target: "/old/bin/swiftgate", expected: "x")))
    #expect(stale.home.contains(.installGitHooks))
    #expect(
      stale.home.contains(.linkShim(path: "/H/.local/bin/swiftgate", target: "/P/bin/swiftgate")))
  }

  @Test(
    "a project nested in a larger git repository gets no lefthook.yml or hook install, and a missing lefthook is a note — catches hooks installed at the wrong root"
  )
  func nestedAndMissingLefthook() {
    let nested = BootstrapPlanner.plan(
      Self.inputs(git: .repository(prefix: "apps/ios/", hooksInstalled: false)))
    guard case .untouched(let advice) = change(nested, "lefthook.yml") else {
      Issue.record("expected lefthook.yml to be left alone")
      return
    }
    #expect(advice.contains("root: apps/ios/"))
    #expect(!nested.home.contains(.installGitHooks))

    let noLefthook = BootstrapPlanner.plan(Self.inputs(lefthook: false))
    #expect(!noLefthook.home.contains(.installGitHooks))
    #expect(noLefthook.notes.contains { $0.hasPrefix("lefthook is not installed") })
  }

  @Test("the registry round-trips sorted and unique — catches status listing a repository twice")
  func registry() throws {
    let registry = ProjectRegistry(projects: ["/b", "/a"]).adding("/b")
    #expect(registry.projects == ["/a", "/b"])
    #expect(try ProjectRegistry.decode(Data(registry.encoded().utf8)) == registry)
    #expect(throws: DecodingError.self) {
      try ProjectRegistry.decode(Data("{\"schema\":2,\"projects\":[]}".utf8))
    }
  }
}
