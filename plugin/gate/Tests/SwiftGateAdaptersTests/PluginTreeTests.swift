import Foundation
import SwiftGateAdapters
import Testing

/// A plugin-shaped directory in a temp dir: a manifest, the three prompt trees, and the files
/// around them that sessions don't load as prompts.
struct TemporaryPlugin {
  static let files: [String: String] = [
    ".claude-plugin/plugin.json": #"{"name":"swift-harness","version":"0.1.0"}"#,
    "skills/build/SKILL.md": "# Build\n",
    "skills/build/references/loop.md": "Loop to green.\n",
    "agents/build-worker.md": "You are a build worker.\n",
    "workflows/build-task.js": "export default {}\n",
    "docs/standards.md": "# Standards\n",
    "hooks/hooks.json": "{}\n",
    "gate/Sources/Main.swift": "print(1)\n",
    "bin/swiftgate": "#!/bin/sh\n",
  ]

  let root: URL

  init(_ files: [String: String] = Self.files) throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    for (path, content) in files { try write(path, content) }
  }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Plugin tree hash")
struct PluginTreeTests {
  @Test(
    "the hash depends only on content: two plugin trees with the same files in different directories hash the same, and reading twice agrees — catches a hash that churns on the plugin's location or on enumeration order"
  )
  func deterministic() throws {
    let first = try TemporaryPlugin()
    defer { first.remove() }
    let second = try TemporaryPlugin()
    defer { second.remove() }
    let hash = try PluginTree.hash(root: first.root)
    #expect(hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(try PluginTree.hash(root: second.root) == hash)
    #expect(try PluginTree.hash(root: first.root) == hash)
    #expect(try PluginTree.read(root: first.root).version == "0.1.0")
  }

  @Test(
    "editing, adding or renaming a file in skills, agents or workflows, or changing the plugin version, changes the hash — catches a hash that misses prompts a session loaded",
    arguments: [
      "edit skills/build/SKILL.md", "edit skills/build/references/loop.md",
      "edit agents/build-worker.md", "edit workflows/build-task.js", "add agents/fixer.md",
      "rename agents/build-worker.md", "bump version",
    ])
  func promptChangesHash(change: String) throws {
    let plugin = try TemporaryPlugin()
    defer { plugin.remove() }
    let before = try PluginTree.hash(root: plugin.root)
    let path = String(change.split(separator: " ", maxSplits: 1).last ?? "")
    switch change.split(separator: " ").first {
    case "edit": try plugin.write(path, (TemporaryPlugin.files[path] ?? "") + "One more rule.\n")
    case "add": try plugin.write(path, "You fix.\n")
    case "rename":
      try FileManager.default.moveItem(
        at: plugin.root.appending(path: path),
        to: plugin.root.appending(path: "agents/builder.md"))
    default:
      try plugin.write(
        ".claude-plugin/plugin.json", #"{"name":"swift-harness","version":"0.2.0"}"#)
    }
    #expect(try PluginTree.hash(root: plugin.root) != before, "\(change)")
  }

  @Test(
    "editing a file outside the three prompt trees, another manifest field, or a Finder .DS_Store leaves the hash alone — catches a hash that churns on files sessions don't load as prompts",
    arguments: [
      "docs/standards.md", "hooks/hooks.json", "gate/Sources/Main.swift", "bin/swiftgate",
      ".claude-plugin/plugin.json", "agents/.DS_Store",
    ])
  func otherChangesKeepHash(path: String) throws {
    let plugin = try TemporaryPlugin()
    defer { plugin.remove() }
    let before = try PluginTree.hash(root: plugin.root)
    #expect(before.count == 64)
    if path.hasSuffix("plugin.json") {
      try plugin.write(
        path, #"{"name":"swift-harness","version":"0.1.0","description":"new words"}"#)
    } else {
      try plugin.write(path, (TemporaryPlugin.files[path] ?? "") + "changed\n")
    }
    #expect(try PluginTree.hash(root: plugin.root) == before, "\(path)")
  }

  @Test(
    "a plugin root with no manifest, a manifest that isn't JSON, or one with no version fails naming the manifest — catches a hash recorded without the version it claims to cover",
    arguments: ["missing", "not json", "no version"])
  func manifestProblemsFail(problem: String) throws {
    var files = TemporaryPlugin.files
    switch problem {
    case "missing": files[".claude-plugin/plugin.json"] = nil
    case "not json": files[".claude-plugin/plugin.json"] = "{"
    default: files[".claude-plugin/plugin.json"] = #"{"name":"swift-harness"}"#
    }
    let plugin = try TemporaryPlugin(files)
    defer { plugin.remove() }
    let manifest = plugin.root.appending(path: ".claude-plugin/plugin.json").path
    do {
      _ = try PluginTree.hash(root: plugin.root)
      Issue.record("hashing succeeded with a \(problem) manifest")
    } catch {
      guard case .manifest(let path, _) = error else {
        Issue.record("\(error)")
        return
      }
      #expect(path == manifest)
    }
  }
}
