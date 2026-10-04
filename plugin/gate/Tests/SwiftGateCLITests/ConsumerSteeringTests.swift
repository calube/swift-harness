import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A consumer install ships only `plugin/`, so anything under it that resolves into the
/// contributor docs (`docs/{designs,adrs,plans,handoffs}`) is a dead reference at runtime.
/// Only references that resolve as paths count: a relative link or path, or one rooted at
/// `${CLAUDE_PLUGIN_ROOT}`. A bare `docs/designs/` names the consumer's own repository.
enum ContributorDocLeaks {
  static let scannedDirectories = ["skills", "agents", "workflows", "templates", "docs", "hooks"]
  static let contributorAreas = ["designs", "adrs", "plans", "handoffs"]

  struct Finding: Hashable, CustomStringConvertible {
    let file: String
    let reference: String
    var description: String { "\(file): \(reference)" }
  }

  static func scan(pluginRoot: URL) throws -> [Finding] {
    let plugin = pluginRoot.resolvingSymlinksInPath()
    var findings: [Finding] = []
    for directory in scannedDirectories {
      let base = plugin.appending(path: directory, directoryHint: .isDirectory)
      guard
        let files = FileManager.default.enumerator(
          at: base, includingPropertiesForKeys: [.isRegularFileKey])
      else { continue }
      for case let file as URL in files {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          let text = try? String(contentsOf: file, encoding: .utf8)
        else { continue }
        let relative = String(file.resolvingSymlinksInPath().path.dropFirst(plugin.path.count + 1))
        for reference in try leaks(in: text, file: file, pluginRoot: plugin) {
          findings.append(Finding(file: relative, reference: reference))
        }
      }
    }
    return findings
  }

  /// A path at the end of a sentence keeps its full stop out of the reference.
  private static func trimmingSentenceEnd(_ path: Substring) -> String {
    guard path.hasSuffix("."), !path.hasSuffix(".."), !path.hasSuffix("/.") else {
      return String(path)
    }
    return String(path.dropLast())
  }

  static func leaks(in text: String, file: URL, pluginRoot: URL) throws -> [String] {
    let plugin = pluginRoot.resolvingSymlinksInPath()
    let repository = plugin.deletingLastPathComponent()
    // `plugin/docs/<area>` is flagged too: it is where a link written against the repository
    // root lands once its file moved one level down under `plugin/`.
    let forbidden = [repository, plugin].flatMap { base in
      contributorAreas.map { base.appending(path: "docs/\($0)").standardizedFileURL.path }
    }
    let directory = file.resolvingSymlinksInPath().deletingLastPathComponent()
    var resolved: [(reference: String, path: String)] = []

    for match in text.matches(of: try Regex(#"\]\(\s*<?([^)\s>#]+)"#)) {
      guard let target = match.output[1].substring.map(String.init),
        !target.contains(":"), !target.hasPrefix("/"), !target.hasPrefix("$")
      else { continue }
      resolved.append((target, directory.appending(path: target).standardizedFileURL.path))
    }
    for match in text.matches(of: try Regex(#"(?:^|[^\w./$}-])(\.{1,2}/[\w./-]*)"#)) {
      guard let target = match.output[1].substring.map(trimmingSentenceEnd) else { continue }
      resolved.append((target, directory.appending(path: target).standardizedFileURL.path))
    }
    for match in text.matches(of: try Regex(#"\$\{?CLAUDE_PLUGIN_ROOT\}?(/[\w./-]*)"#)) {
      guard let rest = match.output[1].substring.map(trimmingSentenceEnd) else { continue }
      resolved.append(
        ("${CLAUDE_PLUGIN_ROOT}\(rest)", plugin.appending(path: rest).standardizedFileURL.path))
    }

    var seen = Set<String>()
    return resolved.compactMap { entry in
      let leaks = forbidden.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
      guard leaks, seen.insert(entry.reference).inserted else { return nil }
      return entry.reference
    }
  }
}

@Suite("consumer steering")
struct ConsumerSteeringTests {
  static let referenceDocsPrefix = "Plugin reference docs: "

  private func sessionContext(environment: [String: String]) async throws -> String {
    var harness = try HookHarness()
    defer { harness.repository.remove() }
    harness.environment = environment
    let (result, _) = try await harness.run(.sessionStart, "session-start")
    let output = try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
    return try #require(output["additionalContext"])
  }

  @Test(
    "SessionStart names the resolved plugin reference docs directory, and standards.md exists there on disk — catches consumer agents unable to find the rules"
  )
  func sessionStartNamesExistingStandards() async throws {
    // An unnormalized root, as a symlinked or relative install could hand over: the context must
    // still carry one clean absolute path.
    let root = Fixture.checkoutRoot.appending(path: "bin/..").path
    let context = try await sessionContext(environment: ["CLAUDE_PLUGIN_ROOT": root])

    let line = try #require(
      context.split(separator: "\n").first { $0.hasPrefix(Self.referenceDocsPrefix) },
      "no reference docs line in: \(context)")
    let rest = line.dropFirst(Self.referenceDocsPrefix.count)
    let directory = String(rest.prefix { $0 != " " })
    #expect(directory.hasPrefix("/"))
    #expect(!directory.contains("/.."), "unresolved path: \(directory)")
    #expect(
      FileManager.default.fileExists(atPath: "\(directory)/standards.md"),
      "no standards.md under \(directory)")
    #expect(context.contains("standards.md"))
  }

  @Test(
    "SessionStart reports why the reference docs path is missing instead of naming one — catches a silent or wrong path when CLAUDE_PLUGIN_ROOT is unset or has no standards.md",
    arguments: ["unset", "no-standards"])
  func sessionStartNamesMissingReferenceDocs(scenario: String) async throws {
    let empty = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-plugin-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: empty.appending(path: "docs"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    let environment = scenario == "unset" ? [:] : ["CLAUDE_PLUGIN_ROOT": empty.path]

    let context = try await sessionContext(environment: environment)

    #expect(!context.contains(Self.referenceDocsPrefix))
    #expect(context.contains("Plugin reference docs unavailable"))
    if scenario == "unset" {
      #expect(context.contains("CLAUDE_PLUGIN_ROOT is not set"))
    } else {
      #expect(context.contains("\(empty.standardizedFileURL.path)/docs/standards.md"))
    }
  }

  @Test(
    "no consumer-facing file under plugin/ resolves a path into the contributor docs — catches consumer runtime depending on docs that never ship"
  )
  func shippedPluginHasNoContributorDocLeaks() throws {
    let findings = try ContributorDocLeaks.scan(pluginRoot: Fixture.checkoutRoot)
    #expect(findings.isEmpty, "\(findings)")
  }

  @Test(
    "a plugin skill linking ../../docs/adrs or an agent naming ${CLAUDE_PLUGIN_ROOT}/../docs/plans fails — catches consumer runtime depending on contributor docs"
  )
  func plantedContributorLinksFail() throws {
    let plugin = try Self.plantedPlugin([
      "skills/design/SKILL.md":
        "See [the ADR](../../docs/adrs/0002-consumer-plugin-in-plugin-dir.md) and "
        + "../../../docs/handoffs/worker-brief.md.\n",
      "agents/design-reviewer.md": "Read ${CLAUDE_PLUGIN_ROOT}/../docs/plans/current.md first.\n",
    ])
    defer { try? FileManager.default.removeItem(at: plugin.deletingLastPathComponent()) }

    let findings = try ContributorDocLeaks.scan(pluginRoot: plugin)

    #expect(
      Set(findings) == [
        .init(
          file: "skills/design/SKILL.md",
          reference: "../../docs/adrs/0002-consumer-plugin-in-plugin-dir.md"),
        .init(file: "skills/design/SKILL.md", reference: "../../../docs/handoffs/worker-brief.md"),
        .init(
          file: "agents/design-reviewer.md",
          reference: "${CLAUDE_PLUGIN_ROOT}/../docs/plans/current.md"),
      ])
  }

  @Test(
    "a skill naming the consumer's own docs/designs/ passes — catches the leak check over-matching bare contributor-looking strings"
  )
  func bareConsumerDocsPathPasses() throws {
    let plugin = try Self.plantedPlugin([
      "skills/design/SKILL.md":
        "Write the design to `docs/designs/<slug>.md` and link it from [the router](docs/index.md); "
        + "plans go in docs/plans/. Rules: ${CLAUDE_PLUGIN_ROOT}/docs/standards.md.\n"
    ])
    defer { try? FileManager.default.removeItem(at: plugin.deletingLastPathComponent()) }

    #expect(try ContributorDocLeaks.scan(pluginRoot: plugin).isEmpty)
  }

  @Test(
    "the stamped AGENTS.md contains no absolute path and points at the reference docs in session context — catches a machine-specific install path committed into consumer repos"
  )
  func stampedAgentsHasNoAbsolutePath() throws {
    let body = try String(
      contentsOf: Fixture.checkoutRoot.appending(path: "templates/AGENTS.md"), encoding: .utf8)
    let stamped = "\(BootstrapPlanner.blockBegin)\n\(body)\(BootstrapPlanner.blockEnd)\n"
    let absolute = try Regex(#"(?:^|[\s`'"(\[<=])(?:~|[A-Za-z]:\\|/[\w.-]+/)"#)

    #expect("see /Users/me/plugin/docs".contains(absolute), "the detector itself must match")
    #expect("in `~/.local/bin`".contains(absolute), "the detector itself must match")
    let hits = stamped.matches(of: absolute).map { String(stamped[$0.range]) }
    #expect(hits.isEmpty, "absolute paths in the stamped AGENTS.md: \(hits)")
    #expect(stamped.contains("plugin reference docs (path in your session context)"))
  }

  /// A throwaway `<tmp>/<id>/plugin/` holding `files`, so the repository root above it has the
  /// same shape as this checkout without touching it.
  private static func plantedPlugin(_ files: [String: String]) throws -> URL {
    let plugin = TestTemporaryDirectory.root
      .appending(
        path: "swiftgate-steering-\(UUID().uuidString)/plugin", directoryHint: .isDirectory)
    for (path, text) in files {
      let url = plugin.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    return plugin
  }
}
