import Foundation

/// The dotted rule ids Swift source spells out, read from its string literals rather than from a
/// hand-kept list, so a rule shipped with no row in the rule id index can't hide.
///
/// Every single-line literal outside a `//` comment counts. A literal is an id when the whole of
/// it is lowercase dotted words (`plan-lint.dag-cycle`), unless its last word is a file extension
/// or ``notRuleIDs`` names it. An interpolated literal is a family when the same shape holds with
/// `*` for each interpolation and it starts with a literal word, so `"\(tier).\(rule)"` is not
/// one; a family built that way is registered by hand. Multi-line literals are prompt and message
/// text, never ids, and are skipped.
public struct RuleIDSourceScan: Sendable, Equatable {
  /// Every string literal that is a whole rule id: a `ruleID:` argument, a `…RuleID` constant, a
  /// rule enum's raw value.
  public var ids: Set<String>
  /// Every id family built by interpolation or from a `…RuleIDPrefix` constant, as a template with
  /// `*` for each interpolated part: `"design-diff.\(problem.rawValue)"` is `design-diff.*`.
  public var families: Set<String>

  public init(ids: Set<String> = [], families: Set<String> = []) {
    self.ids = ids
    self.families = families
  }

  /// Dotted literals that look like rule ids but name something else, each with why.
  public static let notRuleIDs: [String: String] = [
    "api.typesafe.ai": "the host a judge backend sends to, which `[judge] send_to` names",
    "commit.gpgsign": "a git config key",
    "contents.xcworkspacedata": "a file Xcode keeps in every project's workspace",
    "sourcecode.asm": "an Xcode `lastKnownFileType` a file reference carries",
    "sourcecode.c.c": "an Xcode `lastKnownFileType` a file reference carries",
    "sourcecode.c.objc": "an Xcode `lastKnownFileType` a file reference carries",
    "sourcecode.cpp.cpp": "an Xcode `lastKnownFileType` a file reference carries",
    "sourcecode.cpp.objcpp": "an Xcode `lastKnownFileType` a file reference carries",
    "sourcecode.metal": "an Xcode `lastKnownFileType` a file reference carries",
    "harness.profile": "a `.swiftgate.toml` key a config error names",
    "jev-1.13.0": "a pinned judge model id",
    "judge.model": "a `.swiftgate.toml` key a config error names",
    "judge.call": "a harness event kind",
    "judge.decision": "a harness event kind",
    "gate.run": "a harness event kind",
    "gate.step": "a harness event kind",
    "hook.decision": "a harness event kind",
    "test.result": "a harness event kind",
    "cache.lookup": "a harness event kind",
    "agent.usage": "a harness event kind",
    "build.halt": "a harness event kind",
    "build.resume": "a harness event kind",
    "build.return-checked": "a harness event kind",
    "discover.run": "a harness event kind",
    "warmup.run": "a harness event kind",
    "span.start": "a harness event kind",
    "span.end": "a harness event kind",
    "prove.result": "a harness event kind",
    "agent.tools": "a harness event kind",
    "qa.check": "a harness event kind",
    "qa.flow": "a harness event kind",
    "qa.setup": "a harness event kind",
    "simulator.device": "a `.swiftgate.toml` key a config error names",
    "simulator.os": "a `.swiftgate.toml` key a config error names",
    "docs.budgets.design": "a `.swiftgate.toml` key a config error names",
    "docs.budgets.router": "a `.swiftgate.toml` key a config error names",
    "docs.budgets.topic": "a `.swiftgate.toml` key a config error names",
    "step.name": "a `sprint.json` field a decoding error names",
    "step.slice": "a `sprint.json` field a decoding error names",
    "swiftgate.process": "a thread name",
    "swiftgate.measured-process": "a thread name",
    "swiftgate.blocking": "a thread name",
    "swiftgate.stdin": "a thread name",
    "config.syntax": "a self-test answer label for a parse error `swiftgate.config` reports",
    "pytest.raises": "a pytest call the neutral assertion table matches",
    "pytest.skip": "a pytest call the neutral unsafe-shortcut table matches",
    "pytest.warns": "a pytest call the neutral assertion table matches",
    "evidence-check.stale":
      "a self-test answer label for what `evidence-check.stale-claim` reports",
    "meson.build": "a build file discovery reads",
    "com.android": "a Gradle plugin id discovery matches",
    "android.application": "a Gradle plugin alias discovery matches",
    "android.library": "a Gradle plugin alias discovery matches",
    "kotlin.multiplatform": "a Gradle plugin alias discovery matches",
  ]

  /// Interpolated templates that look like id families but build something else, each with why.
  public static let notRuleIDFamilies: [String: String] = [
    "budgets.*": "a `.swiftgate.toml` key path",
    "build.presets.*": "a `.swiftgate.toml` key path",
    "docs.budgets.files.*": "a `.swiftgate.toml` key path",
    "docs.budgets.sections.*": "a `.swiftgate.toml` key path",
    "evidence-check.*": "a self-test answer label for what `evidence-check.stale-claim` reports",
  ]

  static let fileExtensions: Set<Substring> = [
    "css", "html", "json", "jsonl", "lock", "log", "md", "mmd", "ndjson", "patch", "svg", "swift",
    "toml", "txt", "xml", "yaml", "yml",
    // Final-pass evidence a flow row keeps: `sheet.png`, `video.mp4`.
    "mp4", "png",
    // A result bundle a test run writes: `test-only.xcresult`.
    "xcresult",
    // Build file extensions discovery reads: `build.gradle.kts`, `mix.exs`, `go.mod`, `build.zig`.
    "gradle", "kts", "exs", "mod", "zig",
    // Node, Python and Ruby files discovery reads: `eslint.config.mjs`, `setup.cfg`, `tox.ini`.
    "cfg", "cjs", "cts", "ini", "js", "jsonc", "lockb", "mjs", "mts", "ts",
  ]

  /// The ids and families one Swift source file spells out.
  public static func scan(source: String) -> RuleIDSourceScan {
    var result = RuleIDSourceScan()
    var inMultiline = false
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      if inMultiline {
        if line.contains("\"\"\"") { inMultiline = false }
        continue
      }
      let literals = Self.literals(in: line)
      if literals.opensMultiline { inMultiline = true }
      let namesPrefix = line.lowercased().contains("ruleidprefix")
      for literal in literals.contents { result.classify(literal, namesPrefix: namesPrefix) }
    }
    return result
  }

  /// The ids and families every `.swift` file under `directory` spells out. A file that can't be
  /// read throws rather than being skipped, so the scan can't pass by reading less.
  public static func scan(directory: URL) throws -> RuleIDSourceScan {
    var result = RuleIDSourceScan()
    let files =
      FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for file in files {
      let found = scan(source: try String(contentsOf: file, encoding: .utf8))
      result.ids.formUnion(found.ids)
      result.families.formUnion(found.families)
    }
    return result
  }

  private mutating func classify(_ literal: String, namesPrefix: Bool) {
    let id = /[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)+/
    let template = /[a-z][a-z0-9*-]*(?:\.[a-z0-9*-]+)+/
    let prefix = /[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)*\./
    if literal.contains("*") {
      if literal.wholeMatch(of: template) != nil, Self.notRuleIDFamilies[literal] == nil {
        families.insert(literal)
      }
    } else if literal.wholeMatch(of: id) != nil {
      let last = literal.split(separator: ".").last ?? ""
      if !Self.fileExtensions.contains(last), Self.notRuleIDs[literal] == nil {
        ids.insert(literal)
      }
    } else if namesPrefix, literal.wholeMatch(of: prefix) != nil {
      families.insert(literal + "*")
    }
  }

  /// The single-line string literals on `line` outside a trailing `//` comment, each
  /// interpolation replaced by `*`, and whether the line opens a multi-line literal.
  private static func literals(in line: Substring) -> (contents: [String], opensMultiline: Bool) {
    let characters = Array(line)
    var contents: [String] = []
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
        break
      }
      guard character == "\"" else {
        index += 1
        continue
      }
      if index + 2 < characters.count, characters[index + 1] == "\"",
        characters[index + 2] == "\""
      {
        return (
          contents,
          !line[line.index(line.startIndex, offsetBy: index + 3)...]
            .contains("\"\"\"")
        )
      }
      let (content, end) = literal(characters, from: index + 1)
      contents.append(content)
      index = end + 1
    }
    return (contents, false)
  }

  /// One literal's content from just after its opening quote, and the index of its closing quote.
  private static func literal(_ characters: [Character], from start: Int) -> (String, Int) {
    var content = ""
    var index = start
    while index < characters.count, characters[index] != "\"" {
      guard characters[index] == "\\", index + 1 < characters.count else {
        content.append(characters[index])
        index += 1
        continue
      }
      guard characters[index + 1] == "(" else {
        content.append(characters[index + 1])
        index += 2
        continue
      }
      content.append("*")
      index = interpolationEnd(characters, from: index + 2)
    }
    return (content, index)
  }

  /// The index just past the `)` that closes an interpolation, stepping over nested parentheses
  /// and nested string literals.
  private static func interpolationEnd(_ characters: [Character], from start: Int) -> Int {
    var depth = 1
    var index = start
    while index < characters.count, depth > 0 {
      switch characters[index] {
      case "(": depth += 1
      case ")": depth -= 1
      case "\"": index = literal(characters, from: index + 1).1
      default: break
      }
      index += 1
    }
    return index
  }
}
