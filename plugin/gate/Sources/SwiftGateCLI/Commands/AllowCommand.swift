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
    throw .rule(rule)
  }

  func run() async throws {
    try StubCommand.notImplemented("allow", json: json)
  }
}
