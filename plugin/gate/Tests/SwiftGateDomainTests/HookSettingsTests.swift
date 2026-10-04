import Foundation
import SwiftGateDomain
import Testing

@Suite("HookSettings")
struct HookSettingsTests {
  /// The plugin's own `hooks/hooks.json`, read live so a new event there must reach the settings.
  static let hooksJSON = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "hooks/hooks.json")
  static let pluginRoot = "/opt/swift-harness/plugin"

  func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func hooks(_ data: Data) throws -> [String: [[String: Any]]] {
    try #require(try object(data)["hooks"] as? [String: [[String: Any]]])
  }

  @Test(
    "the rendered settings name exactly the events of hooks.json — catches an event dropped when hooks.json gains one"
  )
  func sameEvents() throws {
    let source = try Data(contentsOf: Self.hooksJSON)
    let rendered = try #require(HookSettings.render(hooksJSON: source, pluginRoot: Self.pluginRoot))

    let expected = Set(try hooks(source).keys)
    #expect(expected.count == 4)
    #expect(Set(try hooks(rendered).keys) == expected)
  }

  @Test(
    "every rendered command is absolute under the plugin root, with matchers and args kept — catches a hook left on the unset plugin variable"
  )
  func absoluteCommands() throws {
    let source = try Data(contentsOf: Self.hooksJSON)
    let rendered = try #require(HookSettings.render(hooksJSON: source, pluginRoot: Self.pluginRoot))

    #expect(!String(decoding: rendered, as: UTF8.self).contains("CLAUDE_PLUGIN_ROOT"))
    let sourceHooks = try hooks(source)
    for (event, groups) in try hooks(rendered) {
      let original = try #require(sourceHooks[event])
      #expect(groups.count == original.count, "\(event)")
      for (group, sourceGroup) in zip(groups, original) {
        #expect(group["matcher"] as? String == sourceGroup["matcher"] as? String, "\(event)")
        let commands = try #require(group["hooks"] as? [[String: Any]])
        let sourceCommands = try #require(sourceGroup["hooks"] as? [[String: Any]])
        #expect(commands.count == sourceCommands.count, "\(event)")
        for (command, sourceCommand) in zip(commands, sourceCommands) {
          #expect(command["command"] as? String == Self.pluginRoot + "/bin/swiftgate", "\(event)")
          #expect(command["args"] as? [String] == sourceCommand["args"] as? [String], "\(event)")
          #expect(command["timeout"] as? Int == sourceCommand["timeout"] as? Int, "\(event)")
        }
      }
    }
  }

  @Test(
    "a relative plugin root or a file with no hooks renders nothing — catches settings that run a command from the session's cwd"
  )
  func rejectsUnusableInput() throws {
    let source = try Data(contentsOf: Self.hooksJSON)
    #expect(HookSettings.render(hooksJSON: source, pluginRoot: Self.pluginRoot) != nil)
    #expect(HookSettings.render(hooksJSON: source, pluginRoot: "plugin") == nil)
    #expect(HookSettings.render(hooksJSON: Data("{}".utf8), pluginRoot: Self.pluginRoot) == nil)
    #expect(HookSettings.render(hooksJSON: Data("[".utf8), pluginRoot: Self.pluginRoot) == nil)
  }
}
