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
        packageDirectories: ["P"], schemes: nil, xcodeVersion: nil,
        devices: [
          Self.device("iPhone 17 Pro", "iOS-26-4"), Self.device("iPhone 17", "iOS-26-4"),
          Self.device("iPhone 16", "iOS-26-4"), Self.device("iPhone 17", "iOS-26-2"),
          Self.device("iPhone 18", "iOS-27-0", available: false),
          Self.device("Apple TV", "tvOS-26-4"),
        ]))
    #expect(inferred.simulator == InferredSimulator(device: "iPhone 17", os: "26.4"))
  }

  @Test(
    "the runtime matching the selected Xcode wins over a newer one — catches pinning a runtime another machine with the same Xcode lacks, whose rendering fails every recorded snapshot"
  )
  func simulatorMatchesXcode() {
    let devices = [
      Self.device("iPhone 17", "iOS-26-4"), Self.device("iPhone 17 Pro", "iOS-26-4"),
      Self.device("iPhone 17", "iOS-26-2"), Self.device("iPhone 16", "iOS-26-2"),
    ]
    let matched = ConfigInference.infer(
      RepositorySurvey(
        packageDirectories: ["P"], schemes: nil, xcodeVersion: "26.2", devices: devices))
    #expect(matched.simulator == InferredSimulator(device: "iPhone 17", os: "26.2"))

    let noMatch = ConfigInference.infer(
      RepositorySurvey(
        packageDirectories: ["P"], schemes: nil, xcodeVersion: "26.1", devices: devices))
    #expect(noMatch.simulator == InferredSimulator(device: "iPhone 17", os: "26.4"))
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
    lefthook: "pre-commit:\n", gitignore: "# swift-harness\n**/.harness/runs/\n.harness/x.lock\n",
    docsIndex: "# Docs index\n", scenario: "enum Scenario: String { case live }\n")

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
          simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
          docs: DocsConfig(managedFiles: [
            BootstrapPlanner.Paths.docsIndex, BootstrapPlanner.Paths.agents,
          ])))
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
    #expect(change(plan, "docs/index.md") == .create(Self.templates.docsIndex))
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
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      docs: DocsConfig(managedFiles: [
        BootstrapPlanner.Paths.docsIndex, BootstrapPlanner.Paths.agents,
      ]))
    #expect(
      change(BootstrapPlanner.plan(Self.inputs(config: .loaded(current))), ".swiftgate.toml")
        == .unchanged)
    let predatesManagedFiles = try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
    #expect(
      change(
        BootstrapPlanner.plan(Self.inputs(config: .loaded(predatesManagedFiles))), ".swiftgate.toml"
      ) != .unchanged, "a config naming neither managed file is not current")
    #expect(
      change(BootstrapPlanner.plan(Self.inputs(config: .invalid("line 3"))), ".swiftgate.toml")
        == .untouched(advice: "never rewritten by bootstrap, and it does not load: line 3"))
  }

  @Test(
    "an existing config without [docs] managed_files is left alone with a note naming the missing entries, and adding them turns docs-lint GREEN — catches an upgraded repo whose bootstrap silently leaves docs-lint red"
  )
  func existingConfigMissingManagedFiles() throws {
    let noDocsSection = try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
    guard
      case .untouched(let advice) = change(
        BootstrapPlanner.plan(Self.inputs(config: .loaded(noDocsSection))), ".swiftgate.toml")
    else {
      Issue.record("expected the config to be left alone")
      return
    }
    #expect(advice.contains("[docs] managed_files is missing"))
    let suggested = [BootstrapPlanner.Paths.docsIndex, BootstrapPlanner.Paths.agents].filter {
      advice.contains($0)
    }
    #expect(suggested == [BootstrapPlanner.Paths.docsIndex, BootstrapPlanner.Paths.agents])

    // The stamped router and AGENTS.md, linted as they stand before and after the suggested edit.
    let stamped = [BootstrapPlanner.Paths.docsIndex, BootstrapPlanner.Paths.agents].map { path in
      DocsLintPolicy.ScannedDocument(
        path: path, rawText: "one two", markdown: MarkdownDocument.parse("one two"))
    }
    let before = try DocsLintPolicy.check(documents: stamped, config: noDocsSection.docs)
    #expect(before.contains { $0.ruleID == "docs-lint.managed-file-unlisted" })
    let after = try DocsLintPolicy.check(
      documents: stamped,
      config: DocsConfig(managedFiles: noDocsSection.docs.managedFiles + suggested))
    #expect(after.filter { $0.ruleID.hasPrefix("docs-lint.managed-file") } == [])

    let partial = try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
      docs: DocsConfig(managedFiles: [BootstrapPlanner.Paths.agents]))
    guard
      case .untouched(let partialAdvice) = change(
        BootstrapPlanner.plan(Self.inputs(config: .loaded(partial))), ".swiftgate.toml")
    else {
      Issue.record("expected the config to be left alone")
      return
    }
    #expect(
      partialAdvice.contains("[docs] managed_files is missing \(BootstrapPlanner.Paths.docsIndex)"))
  }

  @Test(
    "a created config names --profile as its [harness] profile, and default without the flag — catches bootstrap stamping a profile other than the one asked for"
  )
  func createdConfigNamesProfile() {
    var inputs = Self.inputs()
    inputs.templates = HarnessTemplates(
      agents: Self.templates.agents, config: "[harness]\nprofile = {{PROFILE}}\n",
      swiftFormat: Self.templates.swiftFormat, swiftLint: Self.templates.swiftLint,
      lefthook: Self.templates.lefthook, gitignore: Self.templates.gitignore,
      docsIndex: Self.templates.docsIndex, scenario: Self.templates.scenario)
    #expect(
      change(BootstrapPlanner.plan(inputs), ".swiftgate.toml")
        == .create("[harness]\nprofile = \"default\"\n"))
    inputs.profile = "timed"
    #expect(
      change(BootstrapPlanner.plan(inputs), ".swiftgate.toml")
        == .create("[harness]\nprofile = \"timed\"\n"))
  }

  @Test(
    "an existing config whose profile differs from --profile is left alone with advice naming both, and one that matches is current — catches --profile silently ignored on an existing repository"
  )
  func existingConfigProfileDrift() throws {
    func config(profile: String?) throws -> Config {
      try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        docs: DocsConfig(managedFiles: [
          BootstrapPlanner.Paths.docsIndex, BootstrapPlanner.Paths.agents,
        ]), profile: profile)
    }
    var inputs = Self.inputs(config: .loaded(try config(profile: nil)))
    inputs.profile = "timed"
    guard case .untouched(let advice) = change(BootstrapPlanner.plan(inputs), ".swiftgate.toml")
    else {
      Issue.record("expected the config to be left alone with advice")
      return
    }
    #expect(advice.contains("[harness] profile is \"default\""))
    #expect(advice.contains("--profile asked for \"timed\""))

    inputs.config = .loaded(try config(profile: "timed"))
    #expect(change(BootstrapPlanner.plan(inputs), ".swiftgate.toml") == .unchanged)
    inputs.profile = nil
    #expect(change(BootstrapPlanner.plan(inputs), ".swiftgate.toml") == .unchanged)
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
    "a CLAUDE.md that is a real file, an existing docs router, and a missing swiftlint are all left alone — catches bootstrap destroying user content or a router that has grown"
  )
  func leftAlone() {
    let plan = BootstrapPlanner.plan(
      Self.inputs(existing: [
        "CLAUDE.md": .file("mine\n"), "docs/index.md": .file("# Docs index\ncustom rows\n"),
      ]))
    guard case .untouched = change(plan, "CLAUDE.md"),
      case .untouched = change(plan, ".swiftlint.yml")
    else {
      Issue.record("expected CLAUDE.md and .swiftlint.yml to be left alone")
      return
    }
    #expect(change(plan, "docs/index.md") == .unchanged)
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

  @Test(
    "commit-msg is a tracked hook — catches lefthook.yml gaining the stanza while bootstrap keeps reporting it uninstalled forever"
  )
  func commitMsgHookTracked() {
    #expect(BootstrapPlanner.gitHooks.contains("commit-msg"))
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

@Suite("bootstrap scenario stamp")
struct BootstrapScenarioStampTests {
  static let scenarioTemplate = "enum Scenario: String, CaseIterable {\n  case live\n}\n"

  static func inputs(
    entryPoints: [AppEntryPoint], declarations: [String] = [],
    existing: [String: ExistingEntry] = [:], config: ConfigState = .absent
  ) -> BootstrapInputs {
    var inputs = BootstrapPlanTests.inputs(existing: existing, config: config)
    let base = BootstrapPlanTests.templates
    inputs.templates = HarnessTemplates(
      agents: base.agents, config: "schema = 1\n{{SCENARIOS}}\n", swiftFormat: base.swiftFormat,
      swiftLint: base.swiftLint, lefthook: base.lefthook, gitignore: base.gitignore,
      docsIndex: base.docsIndex, scenario: scenarioTemplate)
    inputs.appSources = AppSources(entryPoints: entryPoints, scenarioDeclarations: declarations)
    return inputs
  }

  static let app = AppEntryPoint(path: "App/MyApp.swift", typeName: "MyApp")

  private func stamp(_ plan: BootstrapPlan, _ path: String) -> StampChange? {
    plan.stamps.first { $0.path == path }?.change
  }

  @Test(
    "an @main type conforming to App is an entry point, and other @main types are not — catches a stamp beside a command-line tool's main or a missed SwiftUI app"
  )
  func scansEntryPoints() {
    let found: [(String, String?)] = [
      ("@main\nstruct MyApp: App {\n  var body: some Scene { WindowGroup {} }\n}\n", "MyApp"),
      ("@MainActor @main public struct Shop: SwiftUI.App, Sendable {}", "Shop"),
      ("@main\nfinal class Legacy: NSObject, App {}", "Legacy"),
      ("@main\nstruct Tool: AsyncParsableCommand {}", nil),
      ("@main struct Runner {\n  static func main() {}\n}\n", nil),
      ("struct Preview: App {}", nil),
      ("@main\nstruct Wrapped: AppWrapper {}", nil),
    ]
    for (text, typeName) in found {
      #expect(AppEntryPoint.scan(path: "A/F.swift", text: text)?.typeName == typeName, "\(text)")
    }
    #expect(
      AppEntryPoint.scan(path: "A/F.swift", text: "@main struct X: App {}")
        == AppEntryPoint(path: "A/F.swift", typeName: "X"))
  }

  @Test(
    "any type named Scenario counts as declared, and a longer name does not — catches a second Scenario type stamped into a module that already has one"
  )
  func detectsScenarioDeclarations() {
    #expect(AppSources.declaresScenario("enum Scenario: String, CaseIterable {}"))
    #expect(AppSources.declaresScenario("  public struct Scenario {}"))
    #expect(AppSources.declaresScenario("#if DEBUG\nenum Scenario: String { case live }\n#endif"))
    #expect(!AppSources.declaresScenario("enum ScenarioKind: String {}"))
    #expect(!AppSources.declaresScenario("let scenario = Scenario.live"))
  }

  @Test(
    "1 entry point and no config stamps Scenario.swift beside it, a [[scenarios]] live entry, and the call to add — catches a stamp without its config entry, or one that edits the app file"
  )
  func singleEntryPointStampsBoth() throws {
    let plan = BootstrapPlanner.plan(Self.inputs(entryPoints: [Self.app]))

    #expect(stamp(plan, "App/Scenario.swift") == .create(Self.scenarioTemplate))
    #expect(stamp(plan, "App/MyApp.swift") == nil)
    guard case .create(let config) = stamp(plan, BootstrapPlanner.Paths.config) else {
      Issue.record("config not created")
      return
    }
    #expect(config.contains("[[scenarios]]\nname = \"live\"\nreason = "))
    #expect(!config.contains("{{SCENARIOS}}"))
    let call = try #require(plan.notes.first { $0.contains(ScenarioStamp.call) })
    #expect(call.contains("MyApp"))
    #expect(call.contains("App/MyApp.swift"))
    #expect(!plan.notes.contains { $0.hasPrefix("consider") })
  }

  @Test(
    "2 entry points stamp neither file and add a consider line naming both — catches a stamp guessed into the wrong target"
  )
  func twoEntryPointsConsider() throws {
    let other = AppEntryPoint(path: "Widget/WidgetApp.swift", typeName: "WidgetApp")
    let plan = BootstrapPlanner.plan(Self.inputs(entryPoints: [Self.app, other]))

    #expect(!plan.stamps.contains { $0.path.hasSuffix(ScenarioStamp.fileName) })
    guard case .create(let config) = stamp(plan, BootstrapPlanner.Paths.config) else {
      Issue.record("config not created")
      return
    }
    #expect(!config.contains("\n[[scenarios]]"))
    #expect(!config.contains("{{SCENARIOS}}"))
    let consider = try #require(plan.notes.first { $0.hasPrefix("consider") })
    #expect(consider.contains("App/MyApp.swift") && consider.contains("Widget/WidgetApp.swift"))
    #expect(consider.contains(ScenarioStamp.call))
  }

  @Test(
    "no entry point stamps neither file and adds a consider line — catches a stamp written to the repository root of a package-only repository"
  )
  func noEntryPointConsider() throws {
    let plan = BootstrapPlanner.plan(Self.inputs(entryPoints: []))

    #expect(!plan.stamps.contains { $0.path.hasSuffix(ScenarioStamp.fileName) })
    let consider = try #require(plan.notes.first { $0.hasPrefix("consider") })
    #expect(consider.contains(Self.scenarioTemplate.split(separator: "\n")[0]))
  }

  @Test(
    "an existing config stamps neither file and prints the file and the call under consider — catches bootstrap adding an enum the config it never rewrites does not list"
  )
  func existingConfigConsider() throws {
    let config = try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"))
    let plan = BootstrapPlanner.plan(
      Self.inputs(entryPoints: [Self.app], config: .loaded(config)))

    #expect(stamp(plan, "App/Scenario.swift") == nil)
    let consider = try #require(plan.notes.first { $0.hasPrefix("consider") })
    #expect(consider.contains("App/Scenario.swift"))
    #expect(consider.contains("case live"))
    #expect(consider.contains("name = \"live\""))
    #expect(consider.contains(ScenarioStamp.call))
  }

  @Test(
    "an existing Scenario.swift or Scenario type is never touched and asks for nothing — catches a rerun that overwrites the app's own scenarios"
  )
  func existingScenarioUntouched() {
    let fresh = BootstrapPlanner.plan(Self.inputs(entryPoints: [Self.app]))
    #expect(fresh.stamps.contains { $0.path == "App/Scenario.swift" })
    let own = ExistingEntry.file("enum Scenario: String { case live, empty }\n")
    for inputs in [
      Self.inputs(entryPoints: [Self.app], existing: ["App/Scenario.swift": own]),
      Self.inputs(entryPoints: [Self.app], declarations: ["App/Support/Scenarios.swift"]),
    ] {
      let plan = BootstrapPlanner.plan(inputs)
      #expect(!plan.stamps.contains { $0.path.hasSuffix(ScenarioStamp.fileName) })
      #expect(!plan.notes.contains { $0.contains(ScenarioStamp.call) })
    }
  }
}
