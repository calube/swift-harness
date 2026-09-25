/// What a module is for, which decides the rules that apply to its files.
public enum ModuleRole: Sendable, Hashable {
  /// Platform-neutral logic, including client interfaces that are not `*Live`.
  case core
  case ui
  /// A client module's interface half.
  case client
  /// A client module's `*Live` half: the only place IO and vendor SDKs may live.
  case clientLive
  case app
  /// A test target, and the tier its tests run in.
  case tests(Tier)
}

/// The module a file belongs to, as the module graph or config classifies it.
public struct ModuleScope: Sendable, Hashable {
  public let module: String
  public let role: ModuleRole
  public let kind: ModuleKind

  public init(module: String, role: ModuleRole, kind: ModuleKind = .feature) {
    self.module = module
    self.role = role
    self.kind = kind
  }
}

/// Answers which module a file or module name belongs to. Rules take this as input instead of
/// guessing from paths, so the module graph can replace any interim classifier without touching
/// rules.
public protocol ModuleScopeResolving: Sendable {
  /// `nil` when the file's module is unknown; rules restricted to particular roles then skip it.
  func scope(forFile path: String) -> ModuleScope?
  /// `nil` for modules outside the repository (system frameworks, packages).
  func scope(ofModule name: String) -> ModuleScope?
}

/// A fixed table of modules and the path prefixes their files live under.
public struct StaticModuleScopes: ModuleScopeResolving {
  public struct Entry: Sendable, Hashable {
    public let scope: ModuleScope
    /// Repository-relative directory prefixes, without a trailing slash.
    public let directories: [String]

    public init(scope: ModuleScope, directories: [String]) {
      self.scope = scope
      self.directories = directories
    }
  }

  public let entries: [Entry]

  public init(_ entries: [Entry] = []) {
    self.entries = entries
  }

  public func scope(forFile path: String) -> ModuleScope? {
    var best: (length: Int, scope: ModuleScope)?
    for entry in entries {
      for directory in entry.directories
      where path.hasPrefix(directory + "/") && directory.count > (best?.length ?? -1) {
        best = (directory.count, entry.scope)
      }
    }
    return best?.scope
  }

  public func scope(ofModule name: String) -> ModuleScope? {
    entries.first { $0.scope.module == name }?.scope
  }
}

/// Interim classifier from SwiftPM directory layout (`Sources/<Module>/`, `Tests/<Module>/`) and
/// module-name suffixes. It recognises only what naming makes unambiguous and returns `nil`
/// otherwise; in particular it never infers a simulator (T2) test target, so rules that need tier
/// placement stay quiet until the module graph supplies it.
public struct PathConventionModuleScopes: ModuleScopeResolving {
  public init() {}

  public func scope(forFile path: String) -> ModuleScope? {
    let components = path.split(separator: "/").map(String.init)
    // The outermost layout directory wins, so fixture trees nested inside a test target keep
    // that target's scope.
    for index in components.indices.dropLast(2)
    where components[index] == "Sources" || components[index] == "Tests" {
      return scope(ofModule: components[index + 1])
    }
    return nil
  }

  public func scope(ofModule name: String) -> ModuleScope? {
    let role: ModuleRole
    if name.hasSuffix("UITests") {
      role = .tests(.t3)
    } else if name.hasSuffix("Tests") {
      role = .tests(.t1)
    } else if name.hasSuffix("Live") {
      role = .clientLive
    } else if name.hasSuffix("Core") {
      role = .core
    } else {
      return nil
    }
    return ModuleScope(module: name, role: role)
  }
}
