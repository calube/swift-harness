import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A `swiftgate run` session loads the plugin, for its skills, and the clone's rendered
/// settings, for its hooks, so Claude Code registers every event from both. These tests run each
/// registration the way Claude Code starts it: a plugin hook with `${CLAUDE_PLUGIN_ROOT}`
/// expanded and set in its environment, a settings hook with only what its own command sets.
@Suite("brownfield hook registrations")
struct BrownfieldHookRegistrationTests {
  /// This checkout's plugin directory: its `hooks/hooks.json` and `docs/standards.md` are real.
  static let pluginRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().standardizedFileURL.path

  struct Registration {
    let executable: String
    let environment: [String: String]
    let command: HookCommand
  }

  static func hooksJSON() throws -> Data {
    try Data(contentsOf: URL(filePath: pluginRoot).appending(path: "hooks/hooks.json"))
  }

  static func settingsJSON() throws -> Data {
    try #require(HookSettings.render(hooksJSON: try hooksJSON(), pluginRoot: pluginRoot))
  }

  /// `event`'s hooks in a hooks file. `plugin` registrations get the expansion and environment
  /// variable Claude Code gives a plugin's hooks; a `/usr/bin/env` command contributes its
  /// leading `NAME=value` arguments to the environment, as `env` does.
  static func registrations(_ data: Data, event: String, plugin: Bool) throws -> [Registration] {
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let table = try #require(object["hooks"] as? [String: [[String: Any]]])
    let hooks = (table[event] ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    return try hooks.map { hook in
      var environment: [String: String] = [:]
      let expand = { (text: String) in
        plugin ? text.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot) : text
      }
      if plugin { environment["CLAUDE_PLUGIN_ROOT"] = pluginRoot }
      var argv = [expand(try #require(hook["command"] as? String))]
      argv += try #require(hook["args"] as? [String]).map(expand)
      if argv.first == "/usr/bin/env" {
        argv.removeFirst()
        while let first = argv.first, !first.hasPrefix("/"), let equals = first.firstIndex(of: "=")
        {
          environment[String(first[..<equals])] = String(first[first.index(after: equals)...])
          argv.removeFirst()
        }
      }
      let executable = try #require(argv.first)
      #expect(argv.dropFirst().first == "hook")
      let command = try HookCommand.parse(Array(argv.dropFirst(2)))
      return Registration(executable: executable, environment: environment, command: command)
    }
  }

  /// Every registration of `event` in a `swiftgate run` session: the plugin's, then the settings'.
  static func runSession(_ event: String) throws -> [Registration] {
    try registrations(try hooksJSON(), event: event, plugin: true)
      + registrations(try settingsJSON(), event: event, plugin: false)
  }

  func run(
    _ registration: Registration, fixture: String, cwd: URL,
    slice: (@Sendable (URL) async -> (Verdict, String))? = nil
  ) async throws -> HookResult {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.environment = registration.environment.merging(["HOME": cwd.path]) { $1 }
    var dependencies = harness.dependencies
    if let slice { dependencies.brownfieldSlice = slice }
    let input = try harness.payload(fixture, cwd: cwd)
    let ready = dependencies
    return await HookRunner.run(
      registration.command.event, input: input, source: registration.command.source
    ) { _ in ready }
  }

  func context(_ result: HookResult) throws -> String {
    let stdout = try #require(result.stdout)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
    let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
    return try #require(specific["additionalContext"] as? String)
  }

  @Test(
    "with the plugin and the clone's settings both registered, one brownfield stop runs the slice tier once and SessionStart answers once — catches the Stop hook gating twice per stop"
  )
  func stopRunsOnce() async throws {
    let stops = try Self.runSession("Stop")
    #expect(stops.count == 2)
    let ran = RecordedStrings()
    for registration in stops {
      // Each in its own clone: Claude Code starts both at once, before either saves stop state.
      let clone = try BrownfieldProfileCommandTests.Clone()
      defer { try? FileManager.default.removeItem(at: clone.root) }
      _ = try await run(registration, fixture: "stop", cwd: clone.root) { root in
        ran.append(root.lastPathComponent)
        return (.green, "slice: GREEN")
      }
    }
    #expect(ran.all.count == 1)

    let clone = try BrownfieldProfileCommandTests.Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    var answered = 0
    for registration in try Self.runSession("SessionStart") {
      let result = try await run(registration, fixture: "session-start", cwd: clone.root)
      if result.stdout != nil { answered += 1 }
    }
    #expect(answered == 1)
  }

  @Test(
    "an owned project's plugin hooks still answer SessionStart with the owned text, and the settings' answer drops it — catches the brownfield ownership rule silencing the plugin's hooks in an owned repository"
  )
  func ownedPluginHooksStillRun() async throws {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    let starts = try Self.registrations(
      try Self.hooksJSON(), event: "SessionStart", plugin: true)
    #expect(starts.count == 1)
    for registration in starts {
      let result = try await run(
        registration, fixture: "session-start", cwd: harness.repository.root)
      #expect(try context(result).contains("(.swiftgate.toml)"))
    }
    let clone = try BrownfieldProfileCommandTests.Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    let settingsStart = try #require(
      try Self.registrations(try Self.settingsJSON(), event: "SessionStart", plugin: false).first)
    let brownfield = try context(
      try await run(settingsStart, fixture: "session-start", cwd: clone.root))
    #expect(!brownfield.contains(".swiftgate.toml"))
  }

  @Test(
    "a settings hook finds the plugin root: its swiftgate exists, and SessionStart names the reference docs and writes the session record — catches a brownfield hook running without CLAUDE_PLUGIN_ROOT"
  )
  func settingsHooksFindThePluginRoot() async throws {
    let clone = try BrownfieldProfileCommandTests.Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    for event in ["SessionStart", "PreToolUse", "PostToolUse", "Stop"] {
      for registration in try Self.registrations(
        try Self.settingsJSON(), event: event, plugin: false)
      {
        #expect(FileManager.default.isExecutableFile(atPath: registration.executable), "\(event)")
        #expect(registration.environment["CLAUDE_PLUGIN_ROOT"] == Self.pluginRoot, "\(event)")
      }
    }
    let start = try #require(
      try Self.registrations(try Self.settingsJSON(), event: "SessionStart", plugin: false).first)

    let text = try context(try await run(start, fixture: "session-start", cwd: clone.root))

    #expect(text.contains("Plugin reference docs: \(Self.pluginRoot)/docs"))
    #expect(!text.contains("CLAUDE_PLUGIN_ROOT is not set"))
    #expect(!text.contains("Session record not written"))
  }

  @Test(
    "a brownfield SessionStart names the clone's common-dir config and the slice Stop tier — catches the owned .swiftgate.toml and fast-tier text in a brownfield session"
  )
  func brownfieldSessionText() async throws {
    let clone = try BrownfieldProfileCommandTests.Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    let start = try #require(
      try Self.registrations(try Self.settingsJSON(), event: "SessionStart", plugin: false).first)

    let text = try context(try await run(start, fixture: "session-start", cwd: clone.root))

    #expect(text.contains(clone.layout.config.path))
    #expect(text.contains("`swiftgate check --tier slice`"))
    #expect(!text.contains(".swiftgate.toml"))
    #expect(!text.contains("--tier fast"))
  }
}
