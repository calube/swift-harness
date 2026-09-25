import Foundation

/// What is at a repository path before `bootstrap` writes.
public enum ExistingEntry: Sendable, Equatable {
  case absent
  case file(String)
  case symlink(destination: String)
  /// A directory, or a file that is not UTF-8 text.
  case other
}

/// The files under the plugin's `templates/`.
public struct HarnessTemplates: Sendable, Equatable {
  /// The router body placed between the managed-block markers of `AGENTS.md`.
  public let agents: String
  /// `.swiftgate.toml` with `{{…}}` placeholders (see ``InferredConfig/render(template:)``).
  public let config: String
  public let swiftFormat: String
  public let swiftLint: String
  public let lefthook: String
  /// `.gitignore` lines; comments and blank lines are kept only when the file is created.
  public let gitignore: String

  public init(
    agents: String, config: String, swiftFormat: String, swiftLint: String, lefthook: String,
    gitignore: String
  ) {
    self.agents = agents
    self.config = config
    self.swiftFormat = swiftFormat
    self.swiftLint = swiftLint
    self.lefthook = lefthook
    self.gitignore = gitignore
  }
}

public enum ConfigState: Sendable, Equatable {
  case absent
  case loaded(Config)
  /// Present but unreadable or invalid; the reason says which.
  case invalid(String)
}

public enum RegistryState: Sendable, Equatable {
  case absent
  case loaded(ProjectRegistry)
  case invalid(String)
}

public enum GitState: Sendable, Equatable {
  case notRepository
  /// `prefix` is where the repository root sits inside the git worktree (`""` at the toplevel).
  /// `hooksInstalled` is whether every hook in ``BootstrapPlanner/gitHooks`` runs lefthook.
  case repository(prefix: String, hooksInstalled: Bool)
}

/// Everything ``BootstrapPlanner`` decides from, gathered by adapters.
public struct BootstrapInputs: Sendable {
  /// Absolute, symlink-resolved repository root; the path the registry records.
  public var root: String
  /// Keyed by the paths in ``BootstrapPlanner/Paths``; a missing key reads as absent.
  public var existing: [String: ExistingEntry]
  public var templates: HarnessTemplates
  public var config: ConfigState
  public var inferred: InferredConfig
  public var swiftLintInstalled: Bool
  public var lefthookInstalled: Bool
  public var git: GitState
  public var registry: RegistryState
  /// Absolute path of `~/.swift-harness/projects.json`.
  public var registryPath: String
  public var shim: ShimStatus
  /// Absolute path of `~/.local/bin/swiftgate`.
  public var shimPath: String
  /// The plugin's `bin/swiftgate`, which the stable path must lead to.
  public var shimTarget: String

  public init(
    root: String, existing: [String: ExistingEntry], templates: HarnessTemplates,
    config: ConfigState, inferred: InferredConfig, swiftLintInstalled: Bool,
    lefthookInstalled: Bool, git: GitState, registry: RegistryState, registryPath: String,
    shim: ShimStatus, shimPath: String, shimTarget: String
  ) {
    self.root = root
    self.existing = existing
    self.templates = templates
    self.config = config
    self.inferred = inferred
    self.swiftLintInstalled = swiftLintInstalled
    self.lefthookInstalled = lefthookInstalled
    self.git = git
    self.registry = registry
    self.registryPath = registryPath
    self.shim = shim
    self.shimPath = shimPath
    self.shimTarget = shimTarget
  }
}

public enum StampChange: Sendable, Equatable {
  case create(String)
  case update(from: String, to: String)
  /// A relative symlink to `destination`.
  case link(destination: String)
  case unchanged
  /// Nothing is written; `advice` says what to change by hand, if anything.
  case untouched(advice: String)

  public var writes: Bool {
    switch self {
    case .create, .update, .link: true
    case .unchanged, .untouched: false
    }
  }
}

public struct Stamp: Sendable, Equatable {
  public let path: String
  public let change: StampChange

  public init(path: String, change: StampChange) {
    self.path = path
    self.change = change
  }
}

/// A side effect outside the repository; only `--apply` performs it.
public enum HomeAction: Sendable, Equatable {
  case writeRegistry(path: String, contents: String, adding: String)
  case linkShim(path: String, target: String)
  case installGitHooks
}

public struct BootstrapPlan: Sendable, Equatable {
  public let stamps: [Stamp]
  public let home: [HomeAction]
  /// Things bootstrap could not do or infer; shown, never written.
  public let notes: [String]

  public var writes: [Stamp] { stamps.filter(\.change.writes) }
  public var isNoOp: Bool { writes.isEmpty && home.isEmpty }

  /// The dry-run view: a unified diff per written file, then what stays alone and what happens
  /// outside the repository.
  public func render() -> String {
    var sections: [String] = []
    for stamp in stamps {
      switch stamp.change {
      case .create(let contents):
        sections.append(UnifiedDiff.render(path: stamp.path, old: nil, new: contents))
      case .update(let from, let to):
        sections.append(UnifiedDiff.render(path: stamp.path, old: from, new: to))
      case .link(let destination):
        sections.append("\(stamp.path) -> \(destination) (new symlink)\n")
      case .unchanged, .untouched: continue
      }
    }
    let untouched = stamps.compactMap { stamp -> String? in
      guard case .untouched(let advice) = stamp.change else { return nil }
      return "  \(stamp.path): \(advice)"
    }
    if !untouched.isEmpty {
      sections.append((["Left alone:"] + untouched).joined(separator: "\n") + "\n")
    }
    if !home.isEmpty {
      let lines = home.map { action in
        switch action {
        case .writeRegistry(let path, _, let adding): "  register \(adding) in \(path)"
        case .linkShim(let path, let target): "  link \(path) -> \(target)"
        case .installGitHooks: "  run `lefthook install` (git pre-commit and pre-push hooks)"
        }
      }
      sections.append((["Outside the repository:"] + lines).joined(separator: "\n") + "\n")
    }
    if !notes.isEmpty {
      sections.append((["Notes:"] + notes.map { "  \($0)" }).joined(separator: "\n") + "\n")
    }
    let unchanged = stamps.filter { $0.change == .unchanged }.count
    let summary =
      "bootstrap: \(writes.count) to write, \(unchanged) unchanged, "
      + "\(stamps.count - writes.count - unchanged) left alone, \(home.count) outside the repository"
    return ([summary + "\n"] + sections).joined(separator: "\n")
  }
}

/// Decides what `swiftgate bootstrap` writes (spec §4.2). Idempotent: planning again over the
/// result of applying a plan yields a plan with no writes.
public enum BootstrapPlanner {
  public enum Paths {
    public static let agents = "AGENTS.md"
    public static let claude = "CLAUDE.md"
    public static let config = Config.fileName
    public static let swiftFormat = ".swift-format"
    public static let swiftLint = ".swiftlint.yml"
    public static let lefthook = "lefthook.yml"
    public static let gitignore = ".gitignore"
    public static let planIndex = PlanIndex.path

    public static let all = [
      agents, claude, config, swiftFormat, swiftLint, lefthook, gitignore, planIndex,
    ]
  }

  /// The git hooks `lefthook.yml` defines.
  public static let gitHooks = ["pre-commit", "pre-push"]
  public static let blockBegin = "<!-- swift-harness:begin -->"
  public static let blockEnd = "<!-- swift-harness:end -->"
  public static let emptyPlanIndex = "{\n  \"plans\" : []\n}\n"

  public static func plan(_ inputs: BootstrapInputs) -> BootstrapPlan {
    func existing(_ path: String) -> ExistingEntry { inputs.existing[path] ?? .absent }
    let nested: String? =
      if case .repository(let prefix, _) = inputs.git, !prefix.isEmpty { prefix } else { nil }

    var stamps = [
      agents(existing(Paths.agents), body: inputs.templates.agents),
      Stamp(path: Paths.claude, change: claudeLink(existing(Paths.claude))),
      Stamp(path: Paths.config, change: config(inputs)),
      owned(Paths.swiftFormat, existing(Paths.swiftFormat), inputs.templates.swiftFormat),
    ]
    let swiftLint = existing(Paths.swiftLint)
    if inputs.swiftLintInstalled || swiftLint != .absent {
      stamps.append(owned(Paths.swiftLint, swiftLint, inputs.templates.swiftLint))
    } else {
      stamps.append(
        Stamp(
          path: Paths.swiftLint,
          change: .untouched(advice: "not written: swiftlint is not installed (style only)")))
    }
    if let nested {
      stamps.append(
        Stamp(
          path: Paths.lefthook,
          change: .untouched(
            advice:
              "not written: this project sits at \(nested) inside its git repository; add the "
              + "template's commands to the toplevel lefthook.yml with `root: \(nested)`")))
    } else {
      stamps.append(owned(Paths.lefthook, existing(Paths.lefthook), inputs.templates.lefthook))
    }
    stamps.append(
      Stamp(
        path: Paths.gitignore,
        change: gitignore(existing(Paths.gitignore), template: inputs.templates.gitignore)))
    stamps.append(planIndex(existing(Paths.planIndex)))

    var home: [HomeAction] = []
    var notes = inputs.inferred.unresolved.map { "inferred config: \($0)" }
    switch inputs.registry {
    case .absent:
      home.append(
        .writeRegistry(
          path: inputs.registryPath,
          contents: ProjectRegistry(projects: [inputs.root]).encoded(), adding: inputs.root))
    case .loaded(let registry) where !registry.projects.contains(inputs.root):
      home.append(
        .writeRegistry(
          path: inputs.registryPath, contents: registry.adding(inputs.root).encoded(),
          adding: inputs.root))
    case .loaded: break
    case .invalid(let reason):
      notes.append("\(inputs.registryPath) is left alone: \(reason)")
    }

    switch inputs.shim {
    case .current: break
    case .missing, .dangling, .unverified:
      home.append(.linkShim(path: inputs.shimPath, target: inputs.shimTarget))
    case .elsewhere(let path, let target, _):
      if target == path {
        notes.append(
          "\(path) is a regular file, not a symlink; git hooks call it, so replace it with a "
            + "symlink to \(inputs.shimTarget)")
      } else {
        home.append(.linkShim(path: inputs.shimPath, target: inputs.shimTarget))
      }
    }

    switch inputs.git {
    case .notRepository:
      notes.append("not a git repository: lefthook hooks are not installed")
    case .repository(let prefix, let installed):
      let lefthookChanges = stamps.contains { $0.path == Paths.lefthook && $0.change.writes }
      if !prefix.isEmpty {
        break
      } else if !inputs.lefthookInstalled {
        notes.append(
          "lefthook is not installed: install it and re-run `swiftgate bootstrap --apply` so "
            + "pre-commit and pre-push run swiftgate")
      } else if !installed || lefthookChanges {
        home.append(.installGitHooks)
      }
    }
    return BootstrapPlan(stamps: stamps, home: home, notes: notes)
  }

  static func agents(_ entry: ExistingEntry, body: String) -> Stamp {
    let block = "\(blockBegin)\n\(body.hasSuffix("\n") ? body : body + "\n")\(blockEnd)\n"
    switch entry {
    case .absent: return Stamp(path: Paths.agents, change: .create(block))
    case .symlink, .other:
      return Stamp(
        path: Paths.agents, change: .untouched(advice: "not a regular file; add the router by hand")
      )
    case .file(let current):
      guard let begin = current.range(of: blockBegin) else {
        let separator =
          current.isEmpty || current.hasSuffix("\n\n")
          ? "" : current.hasSuffix("\n") ? "\n" : "\n\n"
        return Stamp(
          path: Paths.agents, change: .update(from: current, to: current + separator + block))
      }
      guard let end = current.range(of: blockEnd, range: begin.upperBound..<current.endIndex) else {
        return Stamp(
          path: Paths.agents,
          change: .untouched(
            advice: "has \(blockBegin) without \(blockEnd); repair the markers and re-run"))
      }
      var replaced = current
      var through = end.upperBound
      if through < current.endIndex, current[through] == "\n" {
        through = current.index(after: through)
      }
      replaced.replaceSubrange(begin.lowerBound..<through, with: block)
      return Stamp(
        path: Paths.agents,
        change: replaced == current ? .unchanged : .update(from: current, to: replaced))
    }
  }

  static func claudeLink(_ entry: ExistingEntry) -> StampChange {
    switch entry {
    case .absent: return .link(destination: Paths.agents)
    case .symlink(let destination)
    where destination == Paths.agents || destination == "./\(Paths.agents)":
      return .unchanged
    case .symlink, .file, .other:
      return .untouched(
        advice:
          "exists and is not a symlink to AGENTS.md; move what it holds into AGENTS.md, delete "
          + "it, and re-run so both names read one file")
    }
  }

  static func config(_ inputs: BootstrapInputs) -> StampChange {
    switch inputs.config {
    case .absent:
      return .create(inputs.inferred.render(template: inputs.templates.config))
    case .loaded(let config):
      let drift = inputs.inferred.drift(from: config)
      return drift.isEmpty
        ? .unchanged
        : .untouched(
          advice: "never rewritten by bootstrap; consider editing: " + drift.joined(separator: "; ")
        )
    case .invalid(let reason):
      return .untouched(advice: "never rewritten by bootstrap, and it does not load: \(reason)")
    }
  }

  /// A file the harness owns outright: created, or upgraded to the template in place.
  static func owned(_ path: String, _ entry: ExistingEntry, _ template: String) -> Stamp {
    switch entry {
    case .absent: return Stamp(path: path, change: .create(template))
    case .file(let current):
      return Stamp(
        path: path, change: current == template ? .unchanged : .update(from: current, to: template))
    case .symlink, .other:
      return Stamp(path: path, change: .untouched(advice: "not a regular file; left as it is"))
    }
  }

  static func gitignore(_ entry: ExistingEntry, template: String) -> StampChange {
    switch entry {
    case .absent: return .create(template)
    case .symlink, .other: return .untouched(advice: "not a regular file; add the entries by hand")
    case .file(let current):
      let present = Set(
        current.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
      let entries = template.split(separator: "\n").map(String.init).filter {
        !$0.isEmpty && !$0.hasPrefix("#")
      }
      let missing = entries.filter { !present.contains($0) }
      guard !missing.isEmpty else { return .unchanged }
      let header = "# swift-harness"
      var added = current.isEmpty || current.hasSuffix("\n") ? current : current + "\n"
      if !present.contains(header) { added += (added.isEmpty ? "" : "\n") + header + "\n" }
      added += missing.map { $0 + "\n" }.joined()
      return .update(from: current, to: added)
    }
  }

  static func planIndex(_ entry: ExistingEntry) -> Stamp {
    switch entry {
    case .absent: Stamp(path: Paths.planIndex, change: .create(emptyPlanIndex))
    // The index belongs to the plan orchestrator once it exists.
    case .file, .symlink, .other: Stamp(path: Paths.planIndex, change: .unchanged)
    }
  }
}
