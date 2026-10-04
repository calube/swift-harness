import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

enum AllowCommandError: Error, Equatable, CustomStringConvertible {
  case rule(String)
  case location(String)
  case emptyReason
  case unreadableSource(path: String)
  case lineOutOfRange(path: String, line: Int)
  case config(BrownfieldConfigFileError)

  var description: String {
    switch self {
    case .rule(let rule):
      "\(rule) can't be waived by line; use 1 of "
        + AllowCommand.waivableRules.map(\.rawValue).joined(separator: ", ")
    case .location(let location): "\(location) is not <path>:<line>"
    case .emptyReason: "--reason must say why the finding is acceptable"
    case .unreadableSource(let path): "\(path) doesn't read as text"
    case .lineOutOfRange(let path, let line): "\(path) has no line \(line)"
    case .config(let error): error.description
    }
  }
}

/// `swiftgate allow <rule> <path>:<line> --reason <text>`: waives 1 finding on 1 line of a
/// brownfield clone, keyed by the line's text, in `config.toml`.
struct AllowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "allow",
    abstract: "Waive a brownfield finding on 1 line, with a reason.")

  /// The rules whose findings sit on 1 line and consult `[[allow]]`.
  static let waivableRules: [BrownfieldRuleID] = [.unsafeShortcut, .noAssertion, .lint]

  @Argument(help: "The rule id to waive.")
  var rule: String

  @Argument(help: "<path>:<line>, repository-relative.")
  var location: String

  @Option(help: "Why the finding is acceptable on this line.")
  var reason: String

  @Flag(help: "Print JSON.")
  var json = false

  /// Adds the entry for `location` to the config of the clone holding `worktree` and returns it.
  static func allow(
    worktree: URL, rule: String, location: String, reason: String
  ) throws(AllowCommandError) -> BrownfieldAllow {
    guard let ruleID = BrownfieldRuleID(rawValue: rule), waivableRules.contains(ruleID) else {
      throw .rule(rule)
    }
    guard let colon = location.lastIndex(of: ":"),
      let line = Int(location[location.index(after: colon)...]),
      line >= 1, colon > location.startIndex
    else { throw .location(location) }
    let path = String(location[..<colon])
    let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !why.isEmpty else { throw .emptyReason }
    let file: BrownfieldConfigFile
    do {
      file = try BrownfieldConfigFile.locate(worktree: worktree)
    } catch {
      throw .config(error)
    }
    guard let data = FileManager.default.contents(atPath: worktree.appending(path: path).path),
      let text = String(data: data, encoding: .utf8)
    else { throw .unreadableSource(path: path) }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard line <= lines.count, !(line == lines.count && lines[line - 1].isEmpty) else {
      throw .lineOutOfRange(path: path, line: line)
    }
    let entry = BrownfieldAllow(
      rule: ruleID.rawValue, path: path, lineSHA: AllowMatching.lineSHA(String(lines[line - 1])),
      reason: why)
    do {
      try file.update { config in
        BrownfieldConfig(
          brownfield: config.brownfield, areas: config.areas,
          allow: config.allow.contains(entry) ? config.allow : config.allow + [entry],
          buildPresets: config.buildPresets)
      }
    } catch {
      throw .config(error)
    }
    return entry
  }

  func run() async throws {
    var worktree = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    while !FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path),
      worktree.pathComponents.count > 1
    {
      worktree = worktree.deletingLastPathComponent()
    }
    let outcome: Result<BrownfieldAllow, AllowCommandError>
    do throws(AllowCommandError) {
      outcome = .success(
        try Self.allow(worktree: worktree, rule: rule, location: location, reason: reason))
    } catch {
      outcome = .failure(error)
    }
    switch outcome {
    case .success(let entry):
      try print(
        ["status": "allowed", "rule": entry.rule, "path": entry.path, "line_sha": entry.lineSHA],
        text: "allowed \(entry.rule) on \(location) (line_sha \(entry.lineSHA))")
    case .failure(let error):
      try print(["status": "error", "message": error.description], text: "allow: \(error)")
      switch error {
      case .config(.lock), .config(.unreadable), .config(.write):
        throw ExitCode(Verdict.blocked.exitCode)
      default:
        throw ExitCode(Verdict.red.exitCode)
      }
    }
  }

  private func print(_ fields: [String: String], text: String) throws {
    guard json else { return Console.write(text) }
    let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    Console.write(String(decoding: data, as: UTF8.self))
  }
}
