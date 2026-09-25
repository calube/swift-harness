import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// SessionStart (spec §8, < 1s): the module map with kinds, the Xcode pin against the selected
/// Xcode, RESUME summaries of active plans, and the orphan-clone sweep.
enum SessionStartHook {
  static let moduleMapCache = "module-map.json"

  static func run(root: URL, dependencies: HookDependencies) async -> String {
    var notes: [String] = []
    var modules: [SessionContext.ModuleEntry] = []
    var xcode: SessionContext.Xcode?

    switch StaticCheckInputs.loadConfig(root: root) {
    case .failure(let failure):
      notes.append(
        "\(ConfigLoader.fileName) cannot be used, so every gate is not GREEN: \(describe(failure.outcome))"
      )
    case .success(nil):
      break
    case .success(let config?):
      switch await moduleMap(root: root, config: config, swiftPM: dependencies.swiftPM) {
      case .success(let entries): modules = entries
      case .failure(let reason): notes.append("Module map unavailable: \(reason.text)")
      }
      do throws(XcodeSelectionError) {
        let selected = try await dependencies.xcode.selected()
        xcode = .selected(
          pinned: config.xcode, version: selected.version,
          developerDirectory: selected.developerDirectory)
      } catch {
        xcode = .unknown(pinned: config.xcode, reason: error.description)
      }
    }
    if let swept = await dependencies.sweep.sweep() { notes.append(swept) }

    let inputs = SessionContext.Inputs(
      projectName: root.lastPathComponent, modules: modules, xcode: xcode,
      plans: plans(root: root), notes: notes)
    return HookOutput.context(.sessionStart, SessionContext.render(inputs))
  }

  private static func describe(_ outcome: StaticCheckOutcome) -> String {
    switch outcome {
    case .checked: "unexpected"
    case .blocked(let reason), .invalid(let reason, _): reason
    }
  }

  static func plans(root: URL) -> SessionContext.Plans {
    let url = root.appending(path: PlanIndex.path)
    guard let data = try? Data(contentsOf: url) else { return .none }
    do {
      return .active(try PlanIndex.decode(data).active)
    } catch {
      return .unreadable("\(error)")
    }
  }

  /// `swift package describe` per package costs up to seconds cold, so the map is cached under
  /// the hook state, keyed by the config and every package manifest it covers.
  static func moduleMap(root: URL, config: Config, swiftPM: any SwiftPM) async
    -> Result<[SessionContext.ModuleEntry], BlockedReason>
  {
    let store = HookStateStore(worktreeRoot: root)
    let key: String
    do throws(ModuleGraphLoadError) {
      key = try cacheKey(root: root, config: config)
    } catch {
      return .failure(BlockedReason(error.description))
    }
    if let data = store.cached(moduleMapCache),
      let cached = try? JSONDecoder().decode(CachedModuleMap.self, from: data), cached.key == key
    {
      return .success(cached.modules.map(\.entry))
    }
    let graph: ModuleGraph
    do throws(ModuleGraphLoadError) {
      graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)
    } catch {
      return .failure(BlockedReason(error.description))
    }
    let entries = graph.modules.compactMap { module -> SessionContext.ModuleEntry? in
      guard let role = roleName(module.role) else { return nil }
      return SessionContext.ModuleEntry(
        package: module.packageName ?? "app", name: module.name, role: role,
        kind: module.kind.rawValue)
    }
    if let data = try? JSONEncoder().encode(
      CachedModuleMap(key: key, modules: entries.map(CachedModuleMap.Entry.init)))
    {
      try? store.cache(data, as: moduleMapCache)
    }
    return .success(entries)
  }

  /// Test targets are left out: the map says where logic lives, and tests follow `<Module>Tests`.
  private static func roleName(_ role: ModuleRole) -> String? {
    switch role {
    case .core: "core"
    case .ui: "ui"
    case .client: "client"
    case .clientLive: "client-live"
    case .app: "app"
    case .tests: nil
    }
  }

  private static func cacheKey(root: URL, config: Config) throws(ModuleGraphLoadError) -> String {
    var hasher = SHA256()
    hasher.update(
      data: (try? Data(contentsOf: root.appending(path: ConfigLoader.fileName))) ?? Data())
    for directory in try PackageDirectories.resolve(globs: config.packages, root: root) {
      hasher.update(data: Data("\0\(directory)\0".utf8))
      hasher.update(
        data: (try? Data(contentsOf: root.appending(path: "\(directory)/Package.swift"))) ?? Data())
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private struct CachedModuleMap: Codable {
    struct Entry: Codable {
      let package: String
      let name: String
      let role: String
      let kind: String

      init(_ entry: SessionContext.ModuleEntry) {
        package = entry.package
        name = entry.name
        role = entry.role
        kind = entry.kind
      }

      var entry: SessionContext.ModuleEntry {
        SessionContext.ModuleEntry(package: package, name: name, role: role, kind: kind)
      }
    }

    let key: String
    let modules: [Entry]
  }
}
