import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// SessionStart (spec §8, < 1s): the module map with kinds, the Xcode pin against the selected
/// Xcode, RESUME summaries of active plans, the plugin's reference docs path, the orphan-clone
/// sweep, and the record of which plugin this session loaded.
enum SessionStartHook {
  static let moduleMapCache = "module-map.json"

  static func run(_ payload: HookPayload, root: URL, dependencies: HookDependencies) async
    -> String
  {
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
    notes += recordSession(payload, root: root, environment: dependencies.environment)

    let inputs = SessionContext.Inputs(
      projectName: root.lastPathComponent, sessionID: payload.sessionID, modules: modules,
      xcode: xcode, plans: await plans(git: dependencies.git),
      referenceDocs: referenceDocs(environment: dependencies.environment), notes: notes)
    return HookOutput.context(.sessionStart, SessionContext.render(inputs))
  }

  static let pluginRootVariable = "CLAUDE_PLUGIN_ROOT"

  /// Claude Code sets `CLAUDE_PLUGIN_ROOT` in every plugin hook process. The docs directory is
  /// named only once `standards.md` is on disk there, so the context never points agents at a
  /// path that fails to open.
  static func referenceDocs(environment: [String: String]) -> SessionContext.ReferenceDocs {
    guard let root = environment[pluginRootVariable], !root.isEmpty else {
      return .unavailable(reason: "\(pluginRootVariable) is not set in the hook environment")
    }
    guard root.hasPrefix("/") else {
      return .unavailable(reason: "\(pluginRootVariable) is not an absolute path: \(root)")
    }
    let docs = URL(filePath: root, directoryHint: .isDirectory).appending(
      path: "docs", directoryHint: .isDirectory
    ).standardizedFileURL
    let standards = docs.appending(path: "standards.md").path
    guard FileManager.default.fileExists(atPath: standards) else {
      return .unavailable(reason: "\(standards) does not exist")
    }
    return .found(directory: docs.path)
  }

  /// Records the plugin tree this session loaded, for `doctor` to compare later. Only here:
  /// hashing on a per-tool-call hook would spend its budget on every call.
  /// - Returns: lines for the session context when the record wasn't written or pruned.
  static func recordSession(
    _ payload: HookPayload, root: URL, environment: [String: String], now: Date = Date()
  ) -> [String] {
    let failed = { (reason: String) in
      [
        "Session record not written, so `swiftgate doctor` can't tell whether the plugin "
          + "changed after this session started: \(reason)"
      ]
    }
    guard let pluginRoot = environment[pluginRootVariable], pluginRoot.hasPrefix("/") else {
      return failed("\(pluginRootVariable) is not set to an absolute path in the hook environment")
    }
    let store = SessionRecordStore(worktreeRoot: root)
    do throws(SessionRecordStoreError) {
      // Compaction keeps the running process, and with it the prompts it loaded at start.
      if payload.source == "compact", try store.record(sessionID: payload.sessionID) != nil {
        return []
      }
    } catch {
      return failed(error.description)
    }
    let pluginURL = URL(filePath: pluginRoot, directoryHint: .isDirectory).standardizedFileURL
    let tree: PluginTree
    do throws(PluginTreeError) {
      tree = try PluginTree.read(root: pluginURL)
    } catch {
      return failed(error.description)
    }
    do throws(SessionRecordError) {
      let record = try SessionRecord(
        sessionId: payload.sessionID, recordedAt: now, pluginRoot: pluginURL.path,
        pluginVersion: tree.version, treeHash: tree.hash, transcriptPath: payload.transcriptPath)
      do throws(SessionRecordStoreError) {
        return try store.write(record)
      } catch {
        return failed(error.description)
      }
    } catch {
      return failed(error.description)
    }
  }

  private static func describe(_ outcome: StaticCheckOutcome) -> String {
    switch outcome {
    case .checked: "unexpected"
    case .blocked(let reason), .invalid(let reason, _): reason
    }
  }

  /// Reads `index.json` from the git common dir (spec §4, §6.3 row 1), the one location every
  /// linked worktree of this repository shares — never `root`, which `git worktree add` gives its
  /// own empty `.harness/`. A missing common dir (outside a git repository, or the query itself
  /// failing) or a missing file both collapse to "no bytes", which ``SessionContext/resolvePlans``
  /// renders as no active plans rather than an error.
  static func plans(git: any Git) async -> SessionContext.Plans {
    guard let commonDirectory = try? await git.commonDirectory(),
      let layout = try? PlanStateLayout(commonDirectory: commonDirectory)
    else {
      return SessionContext.resolvePlans(indexData: nil)
    }
    let indexData = try? Data(contentsOf: URL(filePath: layout.indexFile))
    return SessionContext.resolvePlans(indexData: indexData)
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
    let entries = moduleEntries(of: graph)
    if let data = try? JSONEncoder().encode(
      CachedModuleMap(key: key, modules: entries.map(CachedModuleMap.Entry.init)))
    {
      try? store.cache(data, as: moduleMapCache)
    }
    return .success(entries)
  }

  /// The module map's entries for `graph`. Test targets are left out: the map says where logic
  /// lives, and tests follow `<Module>Tests`.
  static func moduleEntries(of graph: ModuleGraph) -> [SessionContext.ModuleEntry] {
    graph.modules.compactMap { module in
      guard let role = roleName(module.role) else { return nil }
      return SessionContext.ModuleEntry(
        package: module.packageName ?? "app", name: module.name, role: role,
        kind: module.kind.rawValue)
    }
  }

  private static func roleName(_ role: ModuleRole) -> String? {
    switch role {
    case .core: "core"
    case .ui: "ui"
    case .client: "client"
    case .clientLive: "client-live"
    case .app: "app"
    case .testSupport: "test-support"
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
